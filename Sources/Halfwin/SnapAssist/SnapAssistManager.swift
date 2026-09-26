import AppKit
import ApplicationServices
import SwiftUI

final class SnapAssistManager {
    private static let keyboardEventMask: CGEventMask = [CGEventType.keyDown, .keyUp].reduce(CGEventMask(0)) {
        $0 | (CGEventMask(1) << $1.rawValue)
    }

    private var enabled = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var keyboardEventTap: CFMachPort?
    private var keyboardRunLoopSource: CFRunLoopSource?
    private var swallowedKeyboardKeyCodes = Set<Int64>()
    private var activeScreen: NSScreen?
    private var activeWindow: AXWindow?
    private var activeLayout: SnapMultiWindowLayout?
    private var activeAction: SnapAction?
    private var pickedWindows = Set<AXWindow>()
    private var suppressNextAssist = false
    private var lastSnappedProcessIdentifier: pid_t?
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var thumbnailTask: Task<Void, Never>?

    private var panel: SnapAssistPanel?
    private let settings: SnapAssistSettings
    private let thumbnailProvider: @MainActor ([CGWindowID]) async -> [CGWindowID: CGImage]

    init(settings: SnapAssistSettings,
         thumbnailProvider: @escaping @MainActor ([CGWindowID]) async -> [CGWindowID: CGImage]) {
        self.settings = settings
        self.thumbnailProvider = thumbnailProvider
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier == self.lastSnappedProcessIdentifier else {
                self.hidePanel()
                return
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hidePanel() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hidePanel() }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refreshPermission()
    }

    func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen, origin: SnapOrigin = .other) {
        let frame = SnapWindowRegistry.shared.record(for: window)?.frame
        let fixed = frame.flatMap {
            SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                               currentWindowFrame: $0, portrait: screen.frame.height > screen.frame.width)
        }
        guard !suppressNextAssist else { return }
        if origin != .layoutMenu, SnapGeometry.isHalf(action), let frame, let fixed,
           !SnapGeometry.isClose(frame, fixed) {
            hidePanel()
            return
        }
        guard let layout = SnapMultiWindowLayout.containing(action) else {
            hidePanel()
            return
        }
        activeScreen = screen
        activeWindow = window
        activeLayout = layout
        pickedWindows = [window]
        lastSnappedProcessIdentifier = window.processIdentifier
        if origin == .layoutMenu {
            switch settings.fillEmptySpots {
            case .mostRecent: fillEmptyZones(in: layout, excluding: window, placing: action, on: screen)
            case .letMePick: break
            case .leaveEmpty:
                hidePanel()
                return
            }
        }
        guard enabled, Permissions.accessibilityGranted else {
            hidePanel()
            return
        }
        showNextZone()
    }

    func refreshPermission() {
        guard enabled else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            stop()
            return
        }
        guard Permissions.accessibilityGranted else {
            stop()
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.refreshPermission()
                }
            }
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        start()
    }

    private func start() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] in
                self?.handle($0)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
    }

    private func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        hidePanel()
    }

    private func startKeyboardTap() {
        if let keyboardEventTap {
            if !CGEvent.tapIsEnabled(tap: keyboardEventTap) { CGEvent.tapEnable(tap: keyboardEventTap, enable: true) }
            return
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: Self.keyboardEventMask, callback: snapAssistKeyboardEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        keyboardEventTap = tap
        keyboardRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopKeyboardTap() {
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: false)
            CFMachPortInvalidate(keyboardEventTap)
        }
        if let keyboardRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardRunLoopSource, .commonModes) }
        keyboardEventTap = nil
        keyboardRunLoopSource = nil
        swallowedKeyboardKeyCodes.removeAll()
    }

    fileprivate func handleKeyboard(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedKeyboardKeyCodes.removeAll()
            if let keyboardEventTap { CGEvent.tapEnable(tap: keyboardEventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard Permissions.accessibilityGranted else {
            refreshPermission()
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            return swallowedKeyboardKeyCodes.remove(keyCode) == nil ? Unmanaged.passUnretained(event) : nil
        }
        guard type == .keyDown, panel?.isVisible == true else { return Unmanaged.passUnretained(event) }
        guard event.flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand]).isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.hidePanel() }
            return Unmanaged.passUnretained(event)
        }
        switch keyCode {
        case 123, 124, 125, 126:
            panel?.moveSelection(keyCode)
        case 36, 76:
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.panel?.pickSelection() }
            }
        case 53:
            DispatchQueue.main.async { [weak self] in self?.hidePanel() }
        default:
            DispatchQueue.main.async { [weak self] in self?.hidePanel() }
            return Unmanaged.passUnretained(event)
        }
        swallowedKeyboardKeyCodes.insert(keyCode)
        return nil
    }

    private func handle(_ event: NSEvent) {
        guard Permissions.accessibilityGranted else {
            refreshPermission()
            return
        }
        guard let panel, panel.isVisible else { return }
        if event.type == .leftMouseDown, !panel.frame.contains(NSEvent.mouseLocation) {
            hidePanel()
        }
    }

    private func hidePanel() {
        stopKeyboardTap()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        panel?.hide()
        activeScreen = nil
        activeWindow = nil
        activeLayout = nil
        activeAction = nil
        pickedWindows.removeAll()
        lastSnappedProcessIdentifier = nil
    }

    private func pick(_ choice: SnapWindowChoice) {
        guard let screen = activeScreen, let action = activeAction else {
            hidePanel()
            return
        }
        guard Permissions.accessibilityGranted else {
            hidePanel()
            return
        }
        guard let currentFrame = choice.window.frame,
              let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                               currentWindowFrame: currentFrame,
                                               portrait: screen.frame.height > screen.frame.width) else {
            hidePanel()
            return
        }
        activeAction = nil
        panel?.hide()
        lastSnappedProcessIdentifier = choice.application.processIdentifier
        choice.window.setFrame(target)
        choice.window.raise()
        let mainError = AXUIElementSetAttributeValue(choice.window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let appElement = AXUIElementCreateApplication(choice.application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        let frontmostError = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if mainError != .success || frontmostError != .success {
            choice.application.activate(options: [])
        }
        guard let readBack = choice.window.frame, SnapGeometry.isClose(readBack, target) else {
            hidePanel()
            return
        }
        pickedWindows.insert(choice.window)
        activeWindow = choice.window
        suppressNextAssist = true
        SnapEvents.didSnap(window: choice.window, action: action, screen: screen, frame: readBack)
        suppressNextAssist = false
        showNextZone()
    }

    private func fillEmptyZones(in layout: SnapMultiWindowLayout, excluding window: AXWindow,
                                placing action: SnapAction, on screen: NSScreen) {
        guard Permissions.accessibilityGranted else { return }
        let registry = SnapWindowRegistry.shared
        var occupants = registry.zoneOccupants(for: layout, on: screen)
        var excluded = Set(occupants.values)
        excluded.insert(window)
        var choices = SnapWindowInventory.choices(on: screen, excluding: excluded).makeIterator()
        var filled: [(AXWindow, SnapAction, CGRect)] = []
        for zone in layout.zones where zone.action != action && occupants[zone.action] == nil {
            while let choice = choices.next() {
                guard let current = choice.window.frame,
                      let target = SnapGeometry.frame(for: zone.action, visibleFrame: screen.visibleFrame,
                                                      currentWindowFrame: current,
                                                      portrait: screen.frame.height > screen.frame.width) else { continue }
                choice.window.setFrame(target)
                guard let readBack = choice.window.frame, SnapGeometry.isClose(readBack, target) else {
                    choice.window.setFrame(current)
                    continue
                }
                LayoutMenuManager.rememberMove(window: choice.window, target: readBack, currentFrame: current)
                occupants[zone.action] = choice.window
                filled.append((choice.window, zone.action, readBack))
                break
            }
        }
        for (window, action, frame) in filled {
            suppressNextAssist = true
            SnapEvents.didSnap(window: window, action: action, screen: screen, frame: frame)
            suppressNextAssist = false
        }
    }

    private func showNextZone() {
        guard enabled, Permissions.accessibilityGranted,
              let screen = activeScreen, let layout = activeLayout else {
            hidePanel()
            return
        }
        let occupants = SnapWindowRegistry.shared.zoneOccupants(for: layout, on: screen)
        let filledActions = Set(occupants.keys)
        guard let zone = layout.zones.first(where: { !filledActions.contains($0.action) }),
              let frame = SnapGeometry.frame(for: zone.action, visibleFrame: screen.visibleFrame,
                                               currentWindowFrame: activeWindow?.frame ?? .zero,
                                               portrait: screen.frame.height > screen.frame.width) else {
            hidePanel()
            return
        }
        let excluded = Set(occupants.values).union(pickedWindows)
        let choices = SnapWindowInventory.choices(on: screen, excluding: excluded)
        guard !choices.isEmpty else {
            hidePanel()
            return
        }
        activeAction = zone.action
        let panel = self.panel ?? SnapAssistPanel { [weak self] choice in self?.pick(choice) }
        self.panel = panel
        panel.show(frame: frame, choices: choices)
        startKeyboardTap()
        thumbnailTask?.cancel()
        let thumbnailProvider = self.thumbnailProvider
        thumbnailTask = Task { @MainActor [weak self] in
            let images = await thumbnailProvider(choices.map(\.id))
            guard !Task.isCancelled, let self, self.activeAction == zone.action else { return }
            self.panel?.setImages(images)
        }
    }

}

struct SnapWindowChoice: Identifiable {
    let id: CGWindowID
    let window: AXWindow
    let application: NSRunningApplication
    let title: String
}

enum SnapWindowInventory {
    struct VisibleWindow {
        let id: CGWindowID
        let pid: pid_t
        let title: String?
        var frame: CGRect
    }

    private struct AXWindowSnapshot {
        let window: AXWindow
        let frame: CGRect
        let title: String?
    }

    static func choices(on screen: NSScreen, excluding excluded: Set<AXWindow>,
                        limit: Int = .max) -> [SnapWindowChoice] {
        guard limit > 0 else { return [] }
        let applications = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isHidden }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let currentWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var axWindows: [pid_t: [AXWindowSnapshot]] = [:]
        var used = Set<AXWindow>()
        var result: [SnapWindowChoice] = []
        for info in currentWindows {
            if result.count == limit { break }
            guard let candidate = visibleWindow(info),
                  screen.frame.contains(CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)),
                  let application = applications[candidate.pid] else { continue }
            let windows = axWindows[candidate.pid] ?? AXWindow.standardWindows(of: application).compactMap { window in
                guard let frame = window.frame else { return nil }
                return AXWindowSnapshot(window: window, frame: frame, title: window.title)
            }
            axWindows[candidate.pid] = windows
            let available = windows.filter { !excluded.contains($0.window) && !used.contains($0.window) }
            let match = available.first {
                candidate.title != nil && $0.title == candidate.title &&
                    SnapGeometry.isClose($0.frame, candidate.frame, tolerance: 8)
            } ?? available.first { SnapGeometry.isClose($0.frame, candidate.frame, tolerance: 8) }
            guard let match else { continue }
            used.insert(match.window)
            let title = match.title ?? application.localizedName ?? "Untitled Window"
            result.append(SnapWindowChoice(id: candidate.id, window: match.window, application: application, title: title))
        }
        return result
    }

    static func isOnCurrentSpace(_ window: AXWindow, on screen: NSScreen) -> Bool {
        isOnCurrentSpaceIfReadable(window, on: screen) ?? false
    }

    static func isOnCurrentSpaceIfReadable(_ window: AXWindow, on screen: NSScreen) -> Bool? {
        guard let pid = window.processIdentifier, let frame = window.frame else { return false }
        let title = window.title
        guard let visible = visibleWindows(on: screen) else { return nil }
        return visible.contains {
            $0.pid == pid && SnapGeometry.isClose($0.frame, frame, tolerance: 8) &&
                (title == nil || $0.title == nil || title == $0.title)
        }
    }

    private static func visibleWindows(on screen: NSScreen) -> [VisibleWindow]? {
        onScreenWindows()?.filter {
            screen.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
    }

    static func onScreenWindows() -> [VisibleWindow]? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return windows
            .compactMap(visibleWindow)
    }

    static func isCovered(_ frame: CGRect, by bounds: [CGRect]) -> Bool {
        // ponytail: O(n²) rectangle sweep; use a region tree if window counts make scans slow.
        let covers = bounds.compactMap { $0.intersection(frame) }.filter { !$0.isNull && !$0.isEmpty }
        let yEdges = Set([frame.minY, frame.maxY] + covers.flatMap { [$0.minY, $0.maxY] }).sorted()
        for index in 1..<yEdges.count {
            let lower = yEdges[index - 1]
            let upper = yEdges[index]
            guard upper > lower else { continue }
            let middle = (lower + upper) / 2
            var edge = frame.minX
            for rect in covers.filter({ $0.minY <= middle && $0.maxY > middle }).sorted(by: { $0.minX < $1.minX }) {
                guard rect.minX <= edge + 1 else { return false }
                edge = max(edge, rect.maxX)
                if edge >= frame.maxX - 1 { break }
            }
            if edge < frame.maxX - 1 { return false }
        }
        return yEdges.count > 1
    }

    private static func visibleWindow(_ info: [String: Any]) -> VisibleWindow? {
        guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        let rawTitle = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VisibleWindow(id: id, pid: pid, title: rawTitle?.isEmpty == false ? rawTitle : nil,
                             frame: cgFrame.axFlipped)
    }
}

private final class SnapAssistPanel: NSPanel {
    private let onPick: (SnapWindowChoice) -> Void
    private var choices: [SnapWindowChoice] = []
    private var images: [CGWindowID: CGImage] = [:]
    private var selectedIndex = 0
    private var assistView: AcceptingFirstMouseHostingView<SnapAssistView>?

    init(onPick: @escaping (SnapWindowChoice) -> Void) {
        self.onPick = onPick
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        isFloatingPanel = true
        level = .floating
        animationBehavior = .none
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }

    func show(frame: CGRect, choices: [SnapWindowChoice]) {
        self.choices = choices
        selectedIndex = 0
        images = [:]
        let assistView = AcceptingFirstMouseHostingView(
            rootView: SnapAssistView(choices: choices, images: images, selectedIndex: selectedIndex, onPick: onPick)
        )
        self.assistView = assistView
        contentView = assistView
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func setImages(_ images: [CGWindowID: CGImage]) {
        self.images = images
        updateView()
    }

    func moveSelection(_ keyCode: Int64) {
        guard !choices.isEmpty else { return }
        let columns = min(choices.count, max(1, Int(ceil(sqrt(Double(choices.count) * Double(max(frame.width - 20, 1) / max(frame.height - 20, 1)))))))
        let column = selectedIndex % columns
        let next: Int
        switch keyCode {
        case 123: next = column > 0 ? selectedIndex - 1 : selectedIndex
        case 124: next = column < columns - 1 && selectedIndex + 1 < choices.count ? selectedIndex + 1 : selectedIndex
        case 126: next = selectedIndex >= columns ? selectedIndex - columns : selectedIndex
        default: next = selectedIndex + columns < choices.count ? selectedIndex + columns : selectedIndex
        }
        selectedIndex = next
        updateView()
    }

    func pickSelection() {
        guard choices.indices.contains(selectedIndex) else { return }
        onPick(choices[selectedIndex])
    }

    private func updateView() {
        assistView?.rootView = SnapAssistView(
            choices: choices, images: images, selectedIndex: selectedIndex, onPick: onPick
        )
    }

    func hide() { orderOut(nil) }
}

private final class AcceptingFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SnapAssistView: View {
    let choices: [SnapWindowChoice]
    let images: [CGWindowID: CGImage]
    let selectedIndex: Int
    let onPick: (SnapWindowChoice) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let count = max(choices.count, 1)
            let width = max(size.width - 20, 1)
            let height = max(size.height - 20, 1)
            let columns = min(count, max(1, Int(ceil(sqrt(Double(count) * Double(width / height))))))
            let rows = (count + columns - 1) / columns
            let availableCellHeight = (height - CGFloat(rows - 1) * 8) / CGFloat(rows)
            let cellHeight = max(70, availableCellHeight)
            let imageHeight = max(24, cellHeight - 58)
            let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    Button { onPick(choice) } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let image = images[choice.id] {
                                    Image(nsImage: NSImage(cgImage: image, size: .zero))
                                        .resizable().scaledToFit()
                                } else {
                                    appIcon(for: choice)
                                        .frame(width: min(72, imageHeight * 0.55), height: min(72, imageHeight * 0.55))
                                }
                            }
                            .frame(maxWidth: .infinity).frame(height: imageHeight)
                            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                            HStack(spacing: 6) {
                                appIcon(for: choice).frame(width: 20, height: 20)
                                Text(choice.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 32)
                        }
                        .padding(7).frame(maxWidth: .infinity).frame(height: cellHeight)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                            index == selectedIndex ? Color.accentColor : Color.white.opacity(0.12),
                            lineWidth: index == selectedIndex ? 2 : 1
                        ))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title)
                    .id(index)
                }
            }
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.16)
                Group {
                    if availableCellHeight < 70 {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) { grid }
                                .scrollIndicators(.hidden)
                                .onChange(of: selectedIndex) { _, index in
                                    proxy.scrollTo(index, anchor: .center)
                                }
                        }
                    } else {
                        grid
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func appIcon(for choice: SnapWindowChoice) -> some View {
        if let icon = choice.application.icon {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: "app.fill").resizable().scaledToFit()
        }
    }
}

private func snapAssistKeyboardEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<SnapAssistManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleKeyboard(type: type, event: event)
}
