import AppKit

/// Shows a draggable handle at a shared snapped edge and links native edge
/// resizes to the other pane. AX readback supplies the app's effective minimum.
final class SnapDividerManager {
    private enum Axis { case vertical, horizontal }
    private enum Side { case low, high }

    private struct Pane {
        let window: AXWindow
        var frame: CGRect
    }

    private struct Divider {
        let axis: Axis
        var coordinate: CGFloat
        let range: ClosedRange<CGFloat>
        var low: Pane
        var high: Pane
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
    private var hoveredDivider: Divider?
    private var lastPointer = CGPoint.zero
    private var lastWriteTime: TimeInterval = 0
    private var cursorIsResize = false
    private let onFrameChanged: (AXWindow, CGRect) -> Void
    private lazy var panel = SnapDividerPanel(
        mouseDown: { [weak self] in self?.beginDividerDrag() },
        mouseDragged: { [weak self] in self?.dragDivider() },
        mouseUp: { [weak self] in self?.endDividerDrag() }
    )

    init(onFrameChanged: @escaping (AXWindow, CGRect) -> Void) {
        self.onFrameChanged = onFrameChanged
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] in self?.handle($0) }
            updateHover(at: NSEvent.mouseLocation)
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            validationTimer?.invalidate()
            validationTimer = nil
            resizeSession = nil
            dividerDrag = false
            hoveredDivider = nil
            panel.hide()
            resetCursor()
        }
    }

    private func handle(_ event: NSEvent) {
        guard enabled else { return }
        let point = NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            lastPointer = point
            if resizeSession == nil { updateHover(at: point) }
        case .leftMouseDown:
            lastPointer = point
            if panel.isVisible, panel.frame.contains(point) { return }
            resizeSession = nil
            dividerDrag = false
            guard let divider = divider(at: point),
                  let window = AXWindow.windowUnderCursor(at: point),
                  divider.low.window == window || divider.high.window == window else {
                hideDivider()
                return
            }
            resizeSession = ResizeSession(divider: divider, owner: window,
                                          ownerSide: divider.low.window == window ? .low : .high)
            hideDivider()
        case .leftMouseDragged:
            lastPointer = point
            continueNativeResize()
        case .leftMouseUp:
            lastPointer = point
            if resizeSession != nil {
                continueNativeResize(force: true)
                resizeSession = nil
            }
            updateHover(at: point)
        default:
            break
        }
    }

    private func updateHover(at point: CGPoint) {
        guard let divider = divider(at: point) else {
            hideDivider()
            return
        }
        hoveredDivider = divider
        setResizeCursor(for: divider.axis)
        panel.show(frame: panelFrame(for: divider), vertical: divider.axis == .vertical)
        if validationTimer == nil {
            validationTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                guard let self, self.enabled, self.resizeSession == nil else { return }
                self.updateHover(at: self.lastPointer)
            }
        }
    }

    private func hideDivider() {
        hoveredDivider = nil
        panel.hide()
        validationTimer?.invalidate()
        validationTimer = nil
        resetCursor()
    }

    private func divider(at point: CGPoint) -> Divider? {
        var best: (distance: CGFloat, divider: Divider)?
        for screen in NSScreen.screens {
            let panes = SnapAssistManager.rememberedSnapFrames(on: screen).map { Pane(window: $0.key, frame: $0.value) }
            guard panes.count > 1 else { continue }
            for first in panes.indices {
                for second in panes.indices where second > first {
                    for candidate in dividers(between: panes[first], and: panes[second]) {
                        let distance: CGFloat
                        let along: CGFloat
                        switch candidate.axis {
                        case .vertical:
                            distance = abs(point.x - candidate.coordinate)
                            along = point.y
                        case .horizontal:
                            distance = abs(point.y - candidate.coordinate)
                            along = point.x
                        }
                        guard distance <= 6, candidate.range.contains(along) else { continue }
                        if best == nil || distance < best!.distance { best = (distance, candidate) }
                    }
                }
            }
        }
        return best?.divider
    }

    private func dividers(between a: Pane, and b: Pane) -> [Divider] {
        var result: [Divider] = []
        let overlapY = max(a.frame.minY, b.frame.minY)...min(a.frame.maxY, b.frame.maxY)
        if overlapY.upperBound - overlapY.lowerBound > 20 {
            if abs(a.frame.maxX - b.frame.minX) <= 2 {
                result.append(Divider(axis: .vertical, coordinate: (a.frame.maxX + b.frame.minX) / 2,
                                      range: overlapY, low: a, high: b))
            } else if abs(b.frame.maxX - a.frame.minX) <= 2 {
                result.append(Divider(axis: .vertical, coordinate: (b.frame.maxX + a.frame.minX) / 2,
                                      range: overlapY, low: b, high: a))
            }
        }
        let overlapX = max(a.frame.minX, b.frame.minX)...min(a.frame.maxX, b.frame.maxX)
        if overlapX.upperBound - overlapX.lowerBound > 20 {
            if abs(a.frame.maxY - b.frame.minY) <= 2 {
                result.append(Divider(axis: .horizontal, coordinate: (a.frame.maxY + b.frame.minY) / 2,
                                      range: overlapX, low: a, high: b))
            } else if abs(b.frame.maxY - a.frame.minY) <= 2 {
                result.append(Divider(axis: .horizontal, coordinate: (b.frame.maxY + a.frame.minY) / 2,
                                      range: overlapX, low: b, high: a))
            }
        }
        return result
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
        guard let pointDivider = divider(at: NSEvent.mouseLocation) ?? hoveredDivider else { return }
        resizeSession = ResizeSession(divider: pointDivider, owner: nil, ownerSide: nil)
        dividerDrag = true
        validationTimer?.invalidate()
        validationTimer = nil
        lastWriteTime = 0
    }

    private func dragDivider() {
        guard dividerDrag, let session = resizeSession else { return }
        let point = NSEvent.mouseLocation
        let coordinate = session.divider.axis == .vertical ? point.x : point.y
        resize(session: session, to: coordinate)
    }

    private func endDividerDrag() {
        guard dividerDrag else { return }
        dragDivider()
        dividerDrag = false
        resizeSession = nil
        updateHover(at: NSEvent.mouseLocation)
    }

    private func continueNativeResize(force: Bool = false) {
        guard let session = resizeSession, let owner = session.owner,
              let ownerSide = session.ownerSide,
              let ownerFrame = owner.frame else { return }
        let oldFrame = ownerSide == .low ? session.divider.low.frame : session.divider.high.frame
        guard validEdgeResize(from: oldFrame, to: ownerFrame, axis: session.divider.axis, side: ownerSide) else {
            resizeSession = nil
            return
        }
        let coordinate = edge(ownerFrame, axis: session.divider.axis, side: ownerSide)
        guard force || coordinate != session.divider.coordinate else { return }
        resizeSession = session
        resize(session: session, to: coordinate, force: force)
    }

    private func validEdgeResize(from old: CGRect, to new: CGRect, axis: Axis, side: Side) -> Bool {
        guard old.size != new.size || old.origin != new.origin else { return false }
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
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastWriteTime >= 1.0 / 60 else { return }
        lastWriteTime = now

        var divider = session.divider
        let previousLow = divider.low.frame
        let previousHigh = divider.high.frame
        let lowNow = divider.low.window.frame ?? previousLow
        let highNow = divider.high.window.frame ?? previousHigh
        let oldCoordinate = divider.coordinate
        let coordinate = min(max(requested, lowerLimit(lowNow, axis: divider.axis) + 1),
                             upperLimit(highNow, axis: divider.axis) - 1)
        let increasing = coordinate > oldCoordinate
        let shrinkingSide: Side = increasing ? .high : .low
        let expandingSide: Side = shrinkingSide == .low ? .high : .low
        let shrinkingPane = shrinkingSide == .low ? divider.low : divider.high
        let expandingPane = expandingSide == .low ? divider.low : divider.high

        shrinkingPane.window.setFrame(frame(shrinkingSide == .low ? lowNow : highNow,
                                            axis: divider.axis, side: shrinkingSide, coordinate: coordinate))
        guard let shrinkingRead = shrinkingPane.window.frame else {
            restore(previousLow, to: divider.low.window)
            restore(previousHigh, to: divider.high.window)
            return
        }
        let actualCoordinate = edge(shrinkingRead, axis: divider.axis, side: shrinkingSide)
        let boundedCoordinate = increasing ? min(coordinate, actualCoordinate) : max(coordinate, actualCoordinate)
        expandingPane.window.setFrame(frame(expandingSide == .low ? lowNow : highNow,
                                            axis: divider.axis, side: expandingSide, coordinate: boundedCoordinate))
        guard let expandingRead = expandingPane.window.frame else {
            restore(previousLow, to: divider.low.window)
            restore(previousHigh, to: divider.high.window)
            return
        }
        let expansionCoordinate = edge(expandingRead, axis: divider.axis, side: expandingSide)
        var acceptedCoordinate = boundedCoordinate
        if abs(expansionCoordinate - boundedCoordinate) > 2 {
            let retry = frame(shrinkingRead, axis: divider.axis, side: shrinkingSide, coordinate: expansionCoordinate)
            shrinkingPane.window.setFrame(retry)
            guard let retryRead = shrinkingPane.window.frame,
                  abs(edge(retryRead, axis: divider.axis, side: shrinkingSide) - expansionCoordinate) <= 2 else {
                restore(previousLow, to: divider.low.window)
                restore(previousHigh, to: divider.high.window)
                return
            }
            acceptedCoordinate = expansionCoordinate
        }

        guard let lowRead = divider.low.window.frame, let highRead = divider.high.window.frame,
              abs(edge(lowRead, axis: divider.axis, side: .low) - acceptedCoordinate) <= 2,
              abs(edge(highRead, axis: divider.axis, side: .high) - acceptedCoordinate) <= 2 else {
            restore(previousLow, to: divider.low.window)
            restore(previousHigh, to: divider.high.window)
            return
        }
        divider.coordinate = acceptedCoordinate
        divider.low.frame = lowRead
        divider.high.frame = highRead
        SnapAssistManager.updateRememberedSnapFrame(window: divider.low.window, frame: lowRead)
        SnapAssistManager.updateRememberedSnapFrame(window: divider.high.window, frame: highRead)
        onFrameChanged(divider.low.window, lowRead)
        onFrameChanged(divider.high.window, highRead)
        resizeSession = ResizeSession(divider: divider, owner: session.owner, ownerSide: session.ownerSide)
    }

    private func lowerLimit(_ frame: CGRect, axis: Axis) -> CGFloat {
        axis == .vertical ? frame.minX : frame.minY
    }

    private func upperLimit(_ frame: CGRect, axis: Axis) -> CGFloat {
        axis == .vertical ? frame.maxX : frame.maxY
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

    private func restore(_ frame: CGRect, to window: AXWindow) {
        window.setFrame(frame)
        if let readBack = window.frame {
            SnapAssistManager.updateRememberedSnapFrame(window: window, frame: readBack)
            onFrameChanged(window, readBack)
        }
    }

    private func setResizeCursor(for axis: Axis) {
        cursorIsResize = true
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    private func resetCursor() {
        guard cursorIsResize else { return }
        cursorIsResize = false
        NSCursor.arrow.set()
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
    var vertical = true { didSet { needsDisplay = true } }
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
