import AppKit

/// Shows a handle at visible shared snap edges and links divider and native
/// edge resizing. The cached frame and z-order snapshot is refreshed on snap
/// changes, display/Space changes, and once a second while near a seam.
final class SnapDividerManager {
    private enum Axis: Equatable { case vertical, horizontal }
    private enum Side: Equatable { case low, high }

    private struct Pane {
        let window: AXWindow
        let windowID: CGWindowID
        var frame: CGRect
    }

    private struct Divider {
        let axis: Axis
        var coordinate: CGFloat
        var range: ClosedRange<CGFloat>
        var low: [Pane]
        var high: [Pane]
    }

    private struct ResizeSession {
        var divider: Divider
        let owner: AXWindow?
        let ownerSide: Side?
    }

    private var enabled = false
    private var monitor: Any?
    private var validationTimer: Timer?
    private var resizeSession: ResizeSession?
    private var dividerDrag = false
    private var snapshot: SnapAssistSnapshot?
    private var dividers: [Divider] = []
    private var cacheGeneration = -1
    private var lastCacheScan: TimeInterval = 0
    private var lastWriteTime: TimeInterval = 0
    private var potentialSnapWindowDrag = false
    private var movedSnapWindow = false
    private let onFrameChanged: (AXWindow, CGRect) -> Void
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private lazy var panel = SnapDividerPanel(
        mouseDown: { [weak self] in self?.beginDividerDrag() },
        mouseDragged: { [weak self] in self?.dragDivider() },
        mouseUp: { [weak self] in self?.endDividerDrag() }
    )

    init(onFrameChanged: @escaping (AXWindow, CGRect) -> Void) {
        self.onFrameChanged = onFrameChanged
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.invalidateAndRebuild() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.invalidateAndRebuild() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.invalidateAndRebuild() }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.invalidateAndRebuild() }
    }

    deinit {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] in self?.handle($0) }
            rebuildCache()
            updateHover(at: NSEvent.mouseLocation)
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            validationTimer?.invalidate()
            validationTimer = nil
            resizeSession = nil
            dividerDrag = false
            dividers.removeAll()
            snapshot = nil
            cacheGeneration = -1
            potentialSnapWindowDrag = false
            movedSnapWindow = false
            panel.hide()
        }
    }

    private func handle(_ event: NSEvent) {
        guard enabled else { return }
        let point = NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            guard resizeSession == nil else { return }
            refreshCacheIfNeeded(at: point)
            updateHover(at: point)
        case .leftMouseDown:
            if panel.isVisible, panel.frame.contains(point) { return }
            resizeSession = nil
            dividerDrag = false
            refreshCacheIfNeeded(at: point, force: nearCachedSeam(point))
            potentialSnapWindowDrag = snapshot?.panes.contains { $0.frame.contains(point) } == true
            movedSnapWindow = false
            guard let divider = divider(at: point), let owner = paneUnderCursor(point, in: divider) else {
                hideDivider()
                return
            }
            resizeSession = ResizeSession(divider: divider, owner: owner.window,
                                          ownerSide: divider.low.contains { $0.window == owner.window } ? .low : .high)
            hideDivider()
        case .leftMouseDragged:
            if potentialSnapWindowDrag { movedSnapWindow = true }
            continueNativeResize()
        case .leftMouseUp:
            if let session = resizeSession, session.owner != nil {
                continueNativeResize(force: true)
                resizeSession = nil
            }
            if movedSnapWindow {
                rebuildCache()
            }
            potentialSnapWindowDrag = false
            movedSnapWindow = false
            refreshCacheIfNeeded(at: point)
            updateHover(at: point)
        default:
            break
        }
    }

    private func refreshCacheIfNeeded(at point: CGPoint, force: Bool = false) {
        let generationChanged = cacheGeneration != SnapAssistManager.currentSnapFrameGeneration
        let expiredNearSeam = nearCachedSeam(point) &&
            ProcessInfo.processInfo.systemUptime - lastCacheScan >= 1
        if force || generationChanged || expiredNearSeam { rebuildCache() }
    }

    private func invalidateAndRebuild() {
        guard enabled else { return }
        rebuildCache()
        updateHover(at: NSEvent.mouseLocation)
    }

    private func rebuildCache() {
        let snapshot = SnapAssistManager.rememberedSnapSnapshot()
        self.snapshot = snapshot
        cacheGeneration = snapshot.generation
        lastCacheScan = ProcessInfo.processInfo.systemUptime
        dividers = makeDividers(from: snapshot)
    }

    private func updateHover(at point: CGPoint) {
        guard let divider = divider(at: point) else {
            hideDivider()
            return
        }
        panel.show(frame: panelFrame(for: divider), vertical: divider.axis == .vertical)
        if validationTimer == nil {
            validationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.enabled, self.resizeSession == nil else { return }
                let pointer = NSEvent.mouseLocation
                self.refreshCacheIfNeeded(at: pointer)
                self.updateHover(at: pointer)
            }
        }
    }

    private func hideDivider() {
        panel.hide()
        validationTimer?.invalidate()
        validationTimer = nil
    }

    private func nearCachedSeam(_ point: CGPoint) -> Bool {
        dividers.contains { divider in
            switch divider.axis {
            case .vertical:
                return abs(point.x - divider.coordinate) <= 6 && divider.range.contains(point.y)
            case .horizontal:
                return abs(point.y - divider.coordinate) <= 6 && divider.range.contains(point.x)
            }
        }
    }

    private func divider(at point: CGPoint) -> Divider? {
        guard let snapshot else { return nil }
        return dividers
            .filter { divider in
                let along: CGFloat
                let lowPoint: CGPoint
                let highPoint: CGPoint
                switch divider.axis {
                case .vertical:
                    along = point.y
                    lowPoint = CGPoint(x: divider.coordinate - 4, y: along)
                    highPoint = CGPoint(x: divider.coordinate + 4, y: along)
                    guard abs(point.x - divider.coordinate) <= 6, divider.range.contains(along) else { return false }
                case .horizontal:
                    along = point.x
                    lowPoint = CGPoint(x: along, y: divider.coordinate - 4)
                    highPoint = CGPoint(x: along, y: divider.coordinate + 4)
                    guard abs(point.y - divider.coordinate) <= 6, divider.range.contains(along) else { return false }
                }
                return divider.low.contains { $0.windowID == frontmostID(at: lowPoint, in: snapshot) } &&
                    divider.high.contains { $0.windowID == frontmostID(at: highPoint, in: snapshot) }
            }
            .min { distance($0, point) < distance($1, point) }
    }

    private func paneUnderCursor(_ point: CGPoint, in divider: Divider) -> Pane? {
        guard let snapshot else { return nil }
        let side: Side
        let towardLow: CGPoint
        let towardHigh: CGPoint
        switch divider.axis {
        case .vertical:
            side = point.x < divider.coordinate ? .low : .high
            towardLow = CGPoint(x: divider.coordinate - 4, y: point.y)
            towardHigh = CGPoint(x: divider.coordinate + 4, y: point.y)
        case .horizontal:
            side = point.y < divider.coordinate ? .low : .high
            towardLow = CGPoint(x: point.x, y: divider.coordinate - 4)
            towardHigh = CGPoint(x: point.x, y: divider.coordinate + 4)
        }
        let target = side == .low ? towardLow : towardHigh
        let id = frontmostID(at: target, in: snapshot)
        return (side == .low ? divider.low : divider.high).first { $0.windowID == id }
    }

    private func makeDividers(from snapshot: SnapAssistSnapshot) -> [Divider] {
        var groups: [Divider] = []
        for screen in NSScreen.screens {
            let panes = snapshot.panes.filter { $0.screen == screen }
                .map { Pane(window: $0.window, windowID: $0.windowID, frame: $0.frame) }
            guard panes.count > 1 else { continue }
            for first in panes.indices {
                for second in panes.indices where second > first {
                    let a = panes[first]
                    let b = panes[second]
                    let minY = max(a.frame.minY, b.frame.minY)
                    let maxY = min(a.frame.maxY, b.frame.maxY)
                    if maxY - minY > 20 {
                        let overlapY = minY...maxY
                        if abs(a.frame.maxX - b.frame.minX) <= 2 {
                            add(axis: .vertical, coordinate: (a.frame.maxX + b.frame.minX) / 2,
                                range: overlapY, low: a, high: b, to: &groups)
                        } else if abs(b.frame.maxX - a.frame.minX) <= 2 {
                            add(axis: .vertical, coordinate: (b.frame.maxX + a.frame.minX) / 2,
                                range: overlapY, low: b, high: a, to: &groups)
                        }
                    }
                    let minX = max(a.frame.minX, b.frame.minX)
                    let maxX = min(a.frame.maxX, b.frame.maxX)
                    if maxX - minX > 20 {
                        let overlapX = minX...maxX
                        if abs(a.frame.maxY - b.frame.minY) <= 2 {
                            add(axis: .horizontal, coordinate: (a.frame.maxY + b.frame.minY) / 2,
                                range: overlapX, low: a, high: b, to: &groups)
                        } else if abs(b.frame.maxY - a.frame.minY) <= 2 {
                            add(axis: .horizontal, coordinate: (b.frame.maxY + a.frame.minY) / 2,
                                range: overlapX, low: b, high: a, to: &groups)
                        }
                    }
                }
            }
        }
        return groups.flatMap { visibleSegments(of: $0, in: snapshot) }
    }

    private func add(axis: Axis, coordinate: CGFloat, range: ClosedRange<CGFloat>, low: Pane, high: Pane,
                     to groups: inout [Divider]) {
        if let index = groups.firstIndex(where: { $0.axis == axis && abs($0.coordinate - coordinate) <= 2 }) {
            var group = groups[index]
            group.coordinate = (group.coordinate + coordinate) / 2
            group.range = min(group.range.lowerBound, range.lowerBound)...max(group.range.upperBound, range.upperBound)
            if !group.low.contains(where: { $0.window == low.window }) { group.low.append(low) }
            if !group.high.contains(where: { $0.window == high.window }) { group.high.append(high) }
            groups[index] = group
        } else {
            groups.append(Divider(axis: axis, coordinate: coordinate, range: range, low: [low], high: [high]))
        }
    }

    private func visibleSegments(of divider: Divider, in snapshot: SnapAssistSnapshot) -> [Divider] {
        let endpoints: [CGFloat]
        switch divider.axis {
        case .vertical:
            endpoints = snapshot.windows.flatMap { [$0.frame.minY, $0.frame.maxY] } +
                divider.low.flatMap { [$0.frame.minY, $0.frame.maxY] } +
                divider.high.flatMap { [$0.frame.minY, $0.frame.maxY] }
        case .horizontal:
            endpoints = snapshot.windows.flatMap { [$0.frame.minX, $0.frame.maxX] } +
                divider.low.flatMap { [$0.frame.minX, $0.frame.maxX] } +
                divider.high.flatMap { [$0.frame.minX, $0.frame.maxX] }
        }
        let cuts = Set([divider.range.lowerBound, divider.range.upperBound] +
            endpoints.filter { $0 > divider.range.lowerBound && $0 < divider.range.upperBound }).sorted()
        var visible: [ClosedRange<CGFloat>] = []
        for index in 1..<cuts.count {
            let lower = cuts[index - 1]
            let upper = cuts[index]
            guard upper - lower > 1 else { continue }
            let along = (lower + upper) / 2
            let lowPoint: CGPoint
            let highPoint: CGPoint
            switch divider.axis {
            case .vertical:
                lowPoint = CGPoint(x: divider.coordinate - 4, y: along)
                highPoint = CGPoint(x: divider.coordinate + 4, y: along)
            case .horizontal:
                lowPoint = CGPoint(x: along, y: divider.coordinate - 4)
                highPoint = CGPoint(x: along, y: divider.coordinate + 4)
            }
            if divider.low.contains(where: { $0.windowID == frontmostID(at: lowPoint, in: snapshot) }) &&
                divider.high.contains(where: { $0.windowID == frontmostID(at: highPoint, in: snapshot) }) {
                visible.append(lower...upper)
            }
        }
        return merge(visible).map {
            var result = divider
            result.range = $0
            return result
        }
    }

    private func merge(_ ranges: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func frontmostID(at point: CGPoint, in snapshot: SnapAssistSnapshot) -> CGWindowID? {
        snapshot.windows.first { $0.frame.contains(point) }?.id
    }

    private func distance(_ divider: Divider, _ point: CGPoint) -> CGFloat {
        abs((divider.axis == .vertical ? point.x : point.y) - divider.coordinate)
    }

    private func panelFrame(for divider: Divider) -> CGRect {
        switch divider.axis {
        case .vertical:
            return CGRect(x: divider.coordinate - 3, y: divider.range.lowerBound,
                          width: 6, height: divider.range.upperBound - divider.range.lowerBound)
        case .horizontal:
            return CGRect(x: divider.range.lowerBound, y: divider.coordinate - 3,
                          width: divider.range.upperBound - divider.range.lowerBound, height: 6)
        }
    }

    private func beginDividerDrag() {
        rebuildCache()
        guard let divider = divider(at: NSEvent.mouseLocation) else {
            hideDivider()
            return
        }
        resizeSession = ResizeSession(divider: divider, owner: nil, ownerSide: nil)
        dividerDrag = true
        validationTimer?.invalidate()
        validationTimer = nil
        lastWriteTime = 0
    }

    private func dragDivider(force: Bool = false) {
        guard dividerDrag, let session = resizeSession else { return }
        let point = NSEvent.mouseLocation
        let coordinate = session.divider.axis == .vertical ? point.x : point.y
        resize(session: session, to: coordinate, force: force)
    }

    private func endDividerDrag() {
        guard dividerDrag else { return }
        dragDivider(force: true)
        dividerDrag = false
        resizeSession = nil
        refreshCacheIfNeeded(at: NSEvent.mouseLocation, force: true)
        updateHover(at: NSEvent.mouseLocation)
    }

    private func continueNativeResize(force: Bool = false) {
        guard let session = resizeSession, let owner = session.owner,
              let ownerSide = session.ownerSide else { return }
        guard let ownerFrame = owner.frame else {
            resizeSession = nil
            return
        }
        let oldFrame = (ownerSide == .low ? session.divider.low : session.divider.high)
            .first(where: { $0.window == owner })?.frame
        guard let oldFrame else {
            resizeSession = nil
            return
        }
        if SnapGeometry.isClose(oldFrame, ownerFrame, tolerance: 0) { return }
        guard validEdgeResize(from: oldFrame, to: ownerFrame, axis: session.divider.axis, side: ownerSide) else {
            resizeSession = nil
            return
        }
        resize(session: session, to: edge(ownerFrame, axis: session.divider.axis, side: ownerSide), force: force)
    }

    private func validEdgeResize(from old: CGRect, to new: CGRect, axis: Axis, side: Side) -> Bool {
        switch axis {
        case .vertical:
            guard abs(old.minY - new.minY) <= 2, abs(old.height - new.height) <= 2 else { return false }
            return side == .low ? abs(old.minX - new.minX) <= 2 : abs(old.maxX - new.maxX) <= 2
        case .horizontal:
            guard abs(old.minX - new.minX) <= 2, abs(old.width - new.width) <= 2 else { return false }
            return side == .low ? abs(old.minY - new.minY) <= 2 : abs(old.maxY - new.maxY) <= 2
        }
    }

    private func resize(session: ResizeSession, to requested: CGFloat, force: Bool = false) {
        var divider = session.divider
        guard force || abs(requested - divider.coordinate) > 0.1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastWriteTime >= 1.0 / 60 else { return }
        lastWriteTime = now
        let lowFrames = divider.low.compactMap { $0.window.frame }
        let highFrames = divider.high.compactMap { $0.window.frame }
        guard lowFrames.count == divider.low.count, highFrames.count == divider.high.count else {
            resizeSession = nil
            return
        }
        let minimum = zip(divider.low, lowFrames).map { limit($0.1, axis: divider.axis, side: .low) + 1 }.max() ?? requested
        let maximum = zip(divider.high, highFrames).map { limit($0.1, axis: divider.axis, side: .high) - 1 }.min() ?? requested
        guard minimum <= maximum else {
            resizeSession = nil
            return
        }
        var coordinate = min(max(requested, minimum), maximum)
        let increasing = coordinate > divider.coordinate
        let shrinkingSide: Side = increasing ? .high : .low
        let shrinkingPanes = shrinkingSide == .low ? divider.low : divider.high
        let shrinkFrames = shrinkingSide == .low ? lowFrames : highFrames
        let shrinkEdges = zip(shrinkingPanes, shrinkFrames).compactMap { pane, _ in
            write(pane, axis: divider.axis, side: shrinkingSide, coordinate: coordinate)
        }.map { edge($0, axis: divider.axis, side: shrinkingSide) }
        guard shrinkEdges.count == shrinkingPanes.count else {
            resizeSession = nil
            return
        }
        coordinate = increasing ? min(coordinate, shrinkEdges.min() ?? coordinate) : max(coordinate, shrinkEdges.max() ?? coordinate)

        for _ in 0..<2 {
            guard writeGroup(divider.low, side: .low, axis: divider.axis, coordinate: coordinate),
                  writeGroup(divider.high, side: .high, axis: divider.axis, coordinate: coordinate) else {
                resizeSession = nil
                return
            }
            let expandingSide: Side = shrinkingSide == .low ? .high : .low
            let expandingPanes = expandingSide == .low ? divider.low : divider.high
            let expansionEdges = expandingPanes.compactMap { $0.window.frame }.map {
                edge($0, axis: divider.axis, side: expandingSide)
            }
            guard expansionEdges.count == expandingPanes.count else {
                resizeSession = nil
                return
            }
            let accepted = increasing ? min(coordinate, expansionEdges.min() ?? coordinate)
                                      : max(coordinate, expansionEdges.max() ?? coordinate)
            if abs(accepted - coordinate) <= 2 { break }
            coordinate = accepted
        }

        var lowRead: [CGRect] = []
        var highRead: [CGRect] = []
        for pane in divider.low {
            guard let frame = pane.window.frame,
                  abs(edge(frame, axis: divider.axis, side: .low) - coordinate) <= 2 else {
                resizeSession = nil
                return
            }
            lowRead.append(frame)
        }
        for pane in divider.high {
            guard let frame = pane.window.frame,
                  abs(edge(frame, axis: divider.axis, side: .high) - coordinate) <= 2 else {
                resizeSession = nil
                return
            }
            highRead.append(frame)
        }
        for index in divider.low.indices { divider.low[index].frame = lowRead[index] }
        for index in divider.high.indices { divider.high[index].frame = highRead[index] }
        divider.coordinate = coordinate
        for (pane, frame) in zip(divider.low + divider.high, lowRead + highRead) {
            SnapAssistManager.updateRememberedSnapFrame(window: pane.window, frame: frame)
            onFrameChanged(pane.window, frame)
            updateCachedFrame(pane, frame: frame)
        }
        rebuildDividersFromCache()
        resizeSession = ResizeSession(divider: divider, owner: session.owner, ownerSide: session.ownerSide)
        if dividerDrag {
            lastWriteTime = now
            panel.show(frame: panelFrame(for: divider), vertical: divider.axis == .vertical)
        }
    }

    private func writeGroup(_ panes: [Pane], side: Side, axis: Axis, coordinate: CGFloat) -> Bool {
        for pane in panes where write(pane, axis: axis, side: side, coordinate: coordinate) == nil { return false }
        return true
    }

    private func write(_ pane: Pane, axis: Axis, side: Side, coordinate: CGFloat) -> CGRect? {
        guard let current = pane.window.frame else { return nil }
        let target = frame(current, axis: axis, side: side, coordinate: coordinate)
        pane.window.setFrame(target)
        guard var actual = pane.window.frame else { return nil }
        if side == .high &&
            ((axis == .vertical && actual.width > target.width + 2) ||
             (axis == .horizontal && actual.height > target.height + 2)) {
            var anchored = actual
            if axis == .vertical { anchored.origin.x = current.maxX - actual.width }
            else { anchored.origin.y = current.maxY - actual.height }
            pane.window.setFrame(anchored)
            guard let readBack = pane.window.frame else { return nil }
            actual = readBack
        }
        return actual
    }

    private func updateCachedFrame(_ pane: Pane, frame: CGRect) {
        guard var snapshot else { return }
        snapshot.panes = snapshot.panes.map {
            var value = $0
            if value.window == pane.window { value.frame = frame }
            return value
        }
        snapshot.windows = snapshot.windows.map {
            var value = $0
            if value.id == pane.windowID { value.frame = frame }
            return value
        }
        snapshot.generation = SnapAssistManager.currentSnapFrameGeneration
        self.snapshot = snapshot
        cacheGeneration = snapshot.generation
    }

    private func rebuildDividersFromCache() {
        guard let snapshot else { return }
        dividers = makeDividers(from: snapshot)
    }

    private func limit(_ frame: CGRect, axis: Axis, side: Side) -> CGFloat {
        switch (axis, side) {
        case (.vertical, .low): return frame.minX
        case (.vertical, .high): return frame.maxX
        case (.horizontal, .low): return frame.minY
        case (.horizontal, .high): return frame.maxY
        }
    }

    private func edge(_ frame: CGRect, axis: Axis, side: Side) -> CGFloat {
        switch (axis, side) {
        case (.vertical, .low): return frame.maxX
        case (.vertical, .high): return frame.minX
        case (.horizontal, .low): return frame.maxY
        case (.horizontal, .high): return frame.minY
        }
    }

    private func frame(_ frame: CGRect, axis: Axis, side: Side, coordinate: CGFloat) -> CGRect {
        var result = frame
        switch (axis, side) {
        case (.vertical, .low): result.size.width = max(1, coordinate - result.minX)
        case (.vertical, .high):
            result.origin.x = coordinate
            result.size.width = max(1, frame.maxX - coordinate)
        case (.horizontal, .low): result.size.height = max(1, coordinate - result.minY)
        case (.horizontal, .high):
            result.origin.y = coordinate
            result.size.height = max(1, frame.maxY - coordinate)
        }
        return result
    }
}

private final class SnapDividerPanel: NSPanel {
    private let dividerView: SnapDividerView

    init(mouseDown: @escaping () -> Void, mouseDragged: @escaping () -> Void, mouseUp: @escaping () -> Void) {
        dividerView = SnapDividerView(mouseDown: mouseDown, mouseDragged: mouseDragged, mouseUp: mouseUp)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        level = .floating
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = dividerView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(frame: CGRect, vertical: Bool) {
        dividerView.vertical = vertical
        if self.frame != frame { setFrame(frame, display: true) }
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

private final class SnapDividerView: NSView {
    var vertical = true {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private let onMouseDown: () -> Void
    private let onMouseDragged: () -> Void
    private let onMouseUp: () -> Void

    init(mouseDown: @escaping () -> Void, mouseDragged: @escaping () -> Void, mouseUp: @escaping () -> Void) {
        onMouseDown = mouseDown
        onMouseDragged = mouseDragged
        onMouseUp = mouseUp
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseEntered(with event: NSEvent) {
        (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        for offset in [-3.0, 0, 3.0] {
            let dot = vertical
                ? CGRect(x: bounds.midX - 1.5, y: bounds.midY + offset - 0.5, width: 3, height: 1)
                : CGRect(x: bounds.midX + offset - 0.5, y: bounds.midY - 1.5, width: 1, height: 3)
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onMouseDown() }
    override func mouseDragged(with event: NSEvent) { onMouseDragged() }
    override func mouseUp(with event: NSEvent) { onMouseUp() }
}
