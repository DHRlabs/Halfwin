import AppKit

/// Shows a handle at visible shared snap edges and links divider and native
/// edge resizing. Snap frames and visibility live in SnapWindowRegistry.
final class SnapDividerManager {
    private typealias Axis = SnapSeamAxis
    private typealias Side = SnapSeamSide
    private typealias Pane = SnapPane
    private typealias Divider = SnapSeam

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
    private var lastWriteTime: TimeInterval = 0
    private var draggedSnapWindow: AXWindow?
    private var movedSnapWindow = false
    private var registryObserver: NSObjectProtocol?
    private lazy var panel = SnapDividerPanel(
        mouseDown: { [weak self] in self?.beginDividerDrag() },
        mouseDragged: { [weak self] in self?.dragDivider() },
        mouseUp: { [weak self] in self?.endDividerDrag() }
    )

    init() {
        registryObserver = NotificationCenter.default.addObserver(
            forName: SnapWindowRegistry.didValidate, object: SnapWindowRegistry.shared, queue: .main
        ) { [weak self] _ in self?.invalidateAndRebuild() }
    }

    deinit {
        if let registryObserver { NotificationCenter.default.removeObserver(registryObserver) }
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            SnapWindowRegistry.shared.registerHelperWindow(panel.windowNumber)
            monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] in self?.handle($0) }
            SnapWindowRegistry.shared.validate()
            updateHover(at: NSEvent.mouseLocation)
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            validationTimer?.invalidate()
            validationTimer = nil
            resizeSession = nil
            dividerDrag = false
            draggedSnapWindow = nil
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
            updateHover(at: point)
        case .leftMouseDown:
            refreshCacheIfNeeded(at: point, interval: 0.1)
            if panel.isVisible, panel.frame.contains(point) {
                if divider(at: point) != nil { return }
                hideDivider()
            }
            resizeSession = nil
            dividerDrag = false
            refreshCacheIfNeeded(at: point, force: nearCachedSeam(point))
            draggedSnapWindow = SnapWindowRegistry.shared.snappedWindow(at: point)
            movedSnapWindow = false
            guard let divider = divider(at: point), let owner = paneUnderCursor(point, in: divider) else {
                hideDivider()
                return
            }
            resizeSession = ResizeSession(divider: divider, owner: owner.window,
                                          ownerSide: divider.low.contains { $0.window == owner.window } ? .low : .high)
            hideDivider()
        case .leftMouseDragged:
            if draggedSnapWindow != nil { movedSnapWindow = true }
            continueNativeResize()
        case .leftMouseUp:
            if let session = resizeSession, session.owner != nil {
                continueNativeResize(force: true)
                resizeSession = nil
            }
            if movedSnapWindow { SnapWindowRegistry.shared.validate() }
            draggedSnapWindow = nil
            movedSnapWindow = false
            refreshCacheIfNeeded(at: point)
            updateHover(at: point)
        default:
            break
        }
    }

    private func refreshCacheIfNeeded(at point: CGPoint, force: Bool = false, interval: TimeInterval = 1) {
        if force {
            SnapWindowRegistry.shared.validate()
        } else if nearCachedSeam(point) {
            SnapWindowRegistry.shared.validateIfNeeded(interval: interval)
        }
    }

    private func invalidateAndRebuild() {
        guard enabled else { return }
        updateHover(at: NSEvent.mouseLocation)
    }

    private func updateHover(at point: CGPoint) {
        refreshCacheIfNeeded(at: point, interval: 0.1)
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

    private func allSeams() -> [Divider] {
        NSScreen.screens.flatMap { SnapWindowRegistry.shared.seams(on: SnapDisplayID($0)) }
    }

    private func nearCachedSeam(_ point: CGPoint) -> Bool {
        allSeams().contains { seam in
            switch seam.axis {
            case .vertical: return abs(point.x - seam.coordinate) <= 6 && seam.range.contains(point.y)
            case .horizontal: return abs(point.y - seam.coordinate) <= 6 && seam.range.contains(point.x)
            }
        }
    }

    private func divider(at point: CGPoint) -> Divider? {
        let registry = SnapWindowRegistry.shared
        return allSeams().filter { seam in
            let along: CGFloat
            let lowPoint: CGPoint
            let highPoint: CGPoint
            switch seam.axis {
            case .vertical:
                along = point.y
                lowPoint = CGPoint(x: seam.coordinate - 4, y: along)
                highPoint = CGPoint(x: seam.coordinate + 4, y: along)
                guard abs(point.x - seam.coordinate) <= 6, seam.range.contains(along) else { return false }
            case .horizontal:
                along = point.x
                lowPoint = CGPoint(x: along, y: seam.coordinate - 4)
                highPoint = CGPoint(x: along, y: seam.coordinate + 4)
                guard abs(point.y - seam.coordinate) <= 6, seam.range.contains(along) else { return false }
            }
            return seam.low.contains { $0.windowID == registry.frontmostWindowID(at: lowPoint) } &&
                seam.high.contains { $0.windowID == registry.frontmostWindowID(at: highPoint) }
        }.min { distance($0, point) < distance($1, point) }
    }

    private func paneUnderCursor(_ point: CGPoint, in seam: Divider) -> Pane? {
        let side: Side
        let towardLow: CGPoint
        let towardHigh: CGPoint
        switch seam.axis {
        case .vertical:
            side = point.x < seam.coordinate ? .low : .high
            towardLow = CGPoint(x: seam.coordinate - 4, y: point.y)
            towardHigh = CGPoint(x: seam.coordinate + 4, y: point.y)
        case .horizontal:
            side = point.y < seam.coordinate ? .low : .high
            towardLow = CGPoint(x: point.x, y: seam.coordinate - 4)
            towardHigh = CGPoint(x: point.x, y: seam.coordinate + 4)
        }
        let target = side == .low ? towardLow : towardHigh
        let id = SnapWindowRegistry.shared.frontmostWindowID(at: target)
        return (side == .low ? seam.low : seam.high).first { $0.windowID == id }
    }

    private func distance(_ seam: Divider, _ point: CGPoint) -> CGFloat {
        abs((seam.axis == .vertical ? point.x : point.y) - seam.coordinate)
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
        SnapWindowRegistry.shared.validateIfNeeded(interval: 0.1)
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
        SnapWindowRegistry.shared.validate()
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
            return
        }
        resize(session: session, to: edge(ownerFrame, axis: session.divider.axis, side: ownerSide), force: force)
    }

    private func validEdgeResize(from old: CGRect, to new: CGRect, axis: Axis, side: Side) -> Bool {
        switch axis {
        case .vertical:
            guard abs(old.width - new.width) > 0.1,
                  abs(old.minY - new.minY) <= 2, abs(old.height - new.height) <= 2 else { return false }
            return side == .low ? abs(old.minX - new.minX) <= 1 : abs(old.maxX - new.maxX) <= 1
        case .horizontal:
            guard abs(old.height - new.height) > 0.1,
                  abs(old.minX - new.minX) <= 2, abs(old.width - new.width) <= 2 else { return false }
            return side == .low ? abs(old.minY - new.minY) <= 1 : abs(old.maxY - new.maxY) <= 1
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
        let nativeOwner = dividerDrag ? nil : session.owner
        let shrinkEdges = zip(shrinkingPanes, shrinkFrames).compactMap { pane, current in
            let actual = pane.window == nativeOwner
                ? pane.window.frame ?? current
                : write(pane, axis: divider.axis, side: shrinkingSide, coordinate: coordinate)
            return actual.map { edge($0, axis: divider.axis, side: shrinkingSide) }
        }
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
                restore(divider)
                return
            }
            lowRead.append(frame)
        }
        for pane in divider.high {
            guard let frame = pane.window.frame,
                  abs(edge(frame, axis: divider.axis, side: .high) - coordinate) <= 2 else {
                restore(divider)
                return
            }
            highRead.append(frame)
        }
        for index in divider.low.indices { divider.low[index].frame = lowRead[index] }
        for index in divider.high.indices { divider.high[index].frame = highRead[index] }
        divider.coordinate = coordinate
        for (pane, frame) in zip(divider.low + divider.high, lowRead + highRead) {
            SnapWindowRegistry.shared.recordFrameWrite(window: pane.window, frame: frame)
        }
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
        if abs(edge(current, axis: axis, side: side) - coordinate) <= 0.1 { return current }
        let target = frame(current, axis: axis, side: side, coordinate: coordinate)
        pane.window.setFrame(target)
        guard var actual = pane.window.frame else { return nil }
        if (axis == .vertical && side == .high && actual.width > target.width + 2) ||
            (axis == .horizontal && side == .low && actual.height > target.height + 2) {
            var anchored = actual
            if axis == .vertical { anchored.origin.x = current.maxX - actual.width }
            else { anchored.origin.y = current.minY }
            pane.window.setFrame(anchored)
            guard let readBack = pane.window.frame else { return nil }
            actual = readBack
        }
        return actual
    }

    private func restore(_ divider: Divider) {
        for pane in divider.low {
            if let frame = write(pane, axis: divider.axis, side: .low, coordinate: divider.coordinate) {
                SnapWindowRegistry.shared.recordFrameWrite(window: pane.window, frame: frame)
            }
        }
        for pane in divider.high {
            if let frame = write(pane, axis: divider.axis, side: .high, coordinate: divider.coordinate) {
                SnapWindowRegistry.shared.recordFrameWrite(window: pane.window, frame: frame)
            }
        }
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
        let changed = self.frame != frame
        if changed { setFrame(frame, display: true) }
        if !isVisible || changed { orderFrontRegardless() }
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
