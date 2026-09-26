import AppKit
import ApplicationServices

final class CopyProgressWindow: NSObject, NSWindowDelegate, @unchecked Sendable {
    private struct Values {
        var completed: Int64
        var total: Int64
        var throughput: Double?
        var remaining: Double?
        var isFinished: Bool
    }

    private struct Summary {
        var completed: Int64 = 0
        var total: Int64 = 0
        var hasByteCounts = false
        var throughput: Double?
        var remaining: Double?
    }

    private var panel: NSPanel?
    private var bytesLabel: NSTextField?
    private var speedLabel: NSTextField?
    private var remainingLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var graph: CopySpeedGraph?
    private var watching = false
    private var destination: URL?
    private var itemCount = 0
    private var expectedURLs = Set<URL>()
    private var subscribers: [Any] = []
    private var progresses: [URL: Progress] = [:]
    private var observations: [URL: [NSKeyValueObservation]] = [:]
    private var values: [URL: Values] = [:]
    private var activeURLs = Set<URL>()
    private var noProgressTimer: Timer?
    private var sampleTimer: Timer?
    private var completionTimer: Timer?
    private var previousSampleTime: TimeInterval?
    private var previousCompletedBytes: Int64?
    private var computedRates: [Double] = []
    private var publishedEstimates: [Double] = []
    private var graphSamples: [Double] = []

    static func finderDestination(in application: NSRunningApplication) -> URL? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = windowValue as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.15)
        var documentValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXDocumentAttribute as CFString,
            &documentValue
        ) == .success, let documentValue else { return nil }

        let document: String
        if let value = documentValue as? String {
            document = value
        } else if let value = documentValue as? URL {
            document = value.absoluteString
        } else if let value = documentValue as? NSURL {
            document = (value as URL).absoluteString
        } else {
            return nil
        }
        if let url = URL(string: document), url.isFileURL { return url.standardizedFileURL }
        guard document.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: document, isDirectory: true).standardizedFileURL
    }

    func watch(destination: URL, itemURLs: [URL]) {
        stopWatching()
        let targets = Set(itemURLs.map(\.standardizedFileURL))
        guard !targets.isEmpty else { return }
        watching = true
        let destination = destination.standardizedFileURL
        self.destination = destination
        itemCount = itemURLs.count
        expectedURLs = targets
        noProgressTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.values.isEmpty else { return }
            self.stopWatching(closeWindow: false)
        }

        for url in targets.union([destination]).sorted(by: { $0.absoluteString < $1.absoluteString }) {
            let subscriber = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
                guard let fileURL = progress.fileURL?.standardizedFileURL else { return nil }
                DispatchQueue.main.async { [weak self] in self?.didPublish(progress, at: fileURL) }
                return { [weak self] in
                    DispatchQueue.main.async { [weak self] in self?.didUnpublish(at: fileURL) }
                }
            }
            subscribers.append(subscriber)
        }
    }

    func stopWatching() {
        stopWatching(closeWindow: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopWatching(closeWindow: false)
    }

    private func stopWatching(closeWindow: Bool) {
        watching = false
        noProgressTimer?.invalidate()
        noProgressTimer = nil
        sampleTimer?.invalidate()
        sampleTimer = nil
        completionTimer?.invalidate()
        completionTimer = nil
        observations.removeAll()
        progresses.removeAll()
        values.removeAll()
        activeURLs.removeAll()
        expectedURLs.removeAll()
        destination = nil
        itemCount = 0
        previousSampleTime = nil
        previousCompletedBytes = nil
        computedRates.removeAll()
        publishedEstimates.removeAll()
        graphSamples.removeAll()
        let subscribers = self.subscribers
        self.subscribers.removeAll()
        for subscriber in subscribers { Progress.removeSubscriber(subscriber) }
        if closeWindow, let panel, panel.isVisible { panel.close() }
    }

    private func didPublish(_ progress: Progress, at url: URL) {
        guard watching, url == destination || expectedURLs.contains(url) else { return }
        completionTimer?.invalidate()
        completionTimer = nil
        noProgressTimer?.invalidate()
        noProgressTimer = nil
        guard !activeURLs.contains(url) else { return }
        activeURLs.insert(url)
        progresses[url] = progress
        values[url] = valuesOf(progress)
        observations[url] = [
            progress.observe(\.completedUnitCount, options: .new) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refresh(progress, at: url) }
            },
            progress.observe(\.totalUnitCount, options: .new) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refresh(progress, at: url) }
            },
            progress.observe(\.fractionCompleted, options: .new) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refresh(progress, at: url) }
            },
            progress.observe(\.userInfo, options: .new) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refresh(progress, at: url) }
            }
        ]
        if panel == nil { makePanel() }
        updateTitle()
        panel?.center()
        panel?.orderFrontRegardless()
        let summary = summary()
        previousSampleTime = ProcessInfo.processInfo.systemUptime
        previousCompletedBytes = summary.completed
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sample()
        }
        refreshWindow()
    }

    private func refresh(_ progress: Progress, at url: URL) {
        guard watching, activeURLs.contains(url) else { return }
        values[url] = valuesOf(progress)
        refreshWindow()
        if !activeURLs.isEmpty,
           activeURLs.allSatisfy({ values[$0]?.isFinished == true }),
           expectedURLs.isSubset(of: values.keys) {
            scheduleCompletion()
        }
    }

    private func didUnpublish(at url: URL) {
        guard watching, activeURLs.remove(url) != nil else { return }
        if let progress = progresses.removeValue(forKey: url) { values[url] = valuesOf(progress) }
        observations.removeValue(forKey: url)
        if activeURLs.isEmpty { scheduleCompletion() }
        refreshWindow()
    }

    private func scheduleCompletion() {
        guard completionTimer == nil else { return }
        completionTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.stopWatching()
        }
    }

    private func valuesOf(_ progress: Progress) -> Values {
        let throughput = progress.throughput.flatMap { value -> Double? in
            let number = Double(value)
            return number.isFinite && number >= 0 ? number : nil
        }
        let remaining = progress.estimatedTimeRemaining.flatMap { value -> Double? in
            let number = Double(value)
            return number.isFinite && number >= 0 ? number : nil
        }
        return Values(
            completed: progress.completedUnitCount,
            total: progress.totalUnitCount,
            throughput: throughput,
            remaining: remaining,
            isFinished: progress.isFinished
        )
    }

    private func summary() -> Summary {
        guard let destination else { return Summary() }
        let itemValues = values.filter { $0.key != destination }
        let selected: [Values]
        if let folderValues = values[destination], folderValues.total > 0 {
            selected = [folderValues]
        } else {
            selected = Array(itemValues.values)
        }
        guard !selected.isEmpty else { return Summary() }
        let hasByteCounts = selected.allSatisfy { $0.total > 0 }
        let completed = saturatedSum(selected.map { max(0, $0.completed) })
        let total = saturatedSum(selected.map { max(0, $0.total) })
        let rates = selected.compactMap(\.throughput)
        let estimates = selected.compactMap(\.remaining)
        return Summary(
            completed: completed,
            total: total,
            hasByteCounts: hasByteCounts,
            throughput: rates.count == selected.count ? rates.reduce(0, +) : nil,
            remaining: estimates.count == selected.count ? estimates.max() : nil
        )
    }

    private func saturatedSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { sum, value in
            let (result, overflow) = sum.addingReportingOverflow(value)
            return overflow ? Int64.max : result
        }
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let current = summary()
        if let previousSampleTime, let previousCompletedBytes, now > previousSampleTime,
           current.completed >= previousCompletedBytes {
            computedRates.append(Double(current.completed - previousCompletedBytes) / (now - previousSampleTime))
            if computedRates.count > 5 { computedRates.removeFirst() }
        }
        self.previousSampleTime = now
        previousCompletedBytes = current.completed
        if let estimate = current.remaining, estimate > 0 {
            publishedEstimates.append(estimate)
            if publishedEstimates.count > 5 { publishedEstimates.removeFirst() }
        } else {
            publishedEstimates.removeAll()
        }
        graphSamples.append(current.throughput ?? computedRates.last ?? 0)
        if graphSamples.count > 60 { graphSamples.removeFirst() }
        refreshWindow()
    }

    private func stableAverage(_ samples: [Double]) -> Double? {
        let recent = Array(samples.suffix(3))
        guard recent.count == 3, recent.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let average = recent.reduce(0, +) / Double(recent.count)
        guard let low = recent.min(), let high = recent.max(), high - low <= max(2, average * 0.5) else { return nil }
        return average
    }

    private func estimatedTimeRemaining(for summary: Summary) -> Double? {
        if let estimate = stableAverage(publishedEstimates) { return estimate }
        guard summary.hasByteCounts, summary.total > summary.completed,
              let rate = stableAverage(computedRates) else { return nil }
        return Double(summary.total - summary.completed) / rate
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 128),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.delegate = self

        let bytes = NSTextField(labelWithString: "")
        bytes.font = .systemFont(ofSize: 12)
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.setAccessibilityLabel("Transfer progress")
        let speed = NSTextField(labelWithString: "")
        speed.font = .systemFont(ofSize: 11)
        speed.textColor = .secondaryLabelColor
        let remaining = NSTextField(labelWithString: "")
        remaining.font = .systemFont(ofSize: 11)
        remaining.textColor = .secondaryLabelColor
        let details = NSStackView(views: [speed, remaining])
        details.orientation = .horizontal
        details.alignment = .centerY
        details.distribution = .fillEqually
        details.spacing = 12
        let graph = CopySpeedGraph(frame: .zero)
        graph.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let content = NSView()
        let stack = NSStackView(views: [bytes, progress, details, graph])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        panel.contentView = content
        self.panel = panel
        bytesLabel = bytes
        speedLabel = speed
        remainingLabel = remaining
        progressBar = progress
        self.graph = graph
    }

    private func updateTitle() {
        guard let destination else { return }
        let noun = itemCount == 1 ? "item" : "items"
        let folder = destination.lastPathComponent.isEmpty ? destination.path : destination.lastPathComponent
        panel?.title = "Moving \(itemCount) \(noun) to \(folder)"
    }

    private func refreshWindow() {
        guard let panel else { return }
        let summary = summary()
        if summary.hasByteCounts {
            let completed = min(summary.completed, summary.total)
            bytesLabel?.stringValue = "\(Self.byteString(completed)) of \(Self.byteString(summary.total))"
            progressBar?.isHidden = false
            progressBar?.maxValue = Double(summary.total)
            progressBar?.doubleValue = Double(completed)
        } else {
            bytesLabel?.stringValue = "Byte progress unavailable"
            progressBar?.isHidden = true
        }
        let speed = summary.throughput ?? computedRates.last
        speedLabel?.stringValue = speed.map { "\(Self.byteString(Int64($0.rounded()))) /s" } ?? "Speed unavailable"
        if let remaining = estimatedTimeRemaining(for: summary) {
            remainingLabel?.stringValue = "\(Self.durationString(remaining)) left"
            remainingLabel?.isHidden = false
        } else {
            remainingLabel?.isHidden = true
        }
        graph?.samples = graphSamples
        panel.displayIfNeeded()
    }

    private static func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private static func durationString(_ seconds: Double) -> String {
        let count = max(0, Int(seconds.rounded(.up)))
        if count >= 3600 { return "\(count / 3600) hr \((count % 3600) / 60) min" }
        if count >= 60 { return "\(count / 60) min \(count % 60) sec" }
        return "\(count) sec"
    }
}

private final class CopySpeedGraph: NSView {
    var samples: [Double] = [] { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityLabel("Recent transfer speed graph")
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard samples.count > 1 else { return }
        let maximum = max(samples.max() ?? 0, 1)
        let inset: CGFloat = 3
        let width = bounds.width - inset * 2
        let height = bounds.height - inset * 2
        let path = NSBezierPath()
        for (index, sample) in samples.enumerated() {
            let x = inset + width * CGFloat(index) / CGFloat(samples.count - 1)
            let y = inset + height * CGFloat(max(0, sample)) / CGFloat(maximum)
            let point = NSPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
