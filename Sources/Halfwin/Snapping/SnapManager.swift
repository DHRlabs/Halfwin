import AppKit

/// Watches title-bar drags system-wide and snaps the dragged window to a
/// Rectangle-style edge/corner zone on release. Adapted from the shape of
/// Rectangle's `SnappingManager.swift` (MIT) — passive `NSEvent` global
/// monitor, resolve-the-window-once-per-drag, footprint-on-hover,
/// snap-on-release, escape-to-cancel — with the window-server/AX
/// cross-checking and multi-monitor animation machinery stripped out.
final class SnapManager {
    private struct Zone: Equatable {
        let screen: NSScreen
        let position: SnapPosition
        let action: SnapAction
    }

    private let settings: SnapSettings
    private var monitor: Any?
    private lazy var footprint = FootprintWindow()

    private var draggedWindow: AXWindow?
    private var initialFrame: CGRect?
    private var isWindowMoving = false
    private var cancelled = false
    private var currentZone: Zone?

    /// Pre-snap sizes for windows Halfwin has snapped, so a later drag can
    /// restore them (Rectangle's `unsnapRestore`). Keyed by the AX element,
    /// not a window id — this port never needs a CGWindowID.
    private var snappedSizes: [AXWindow: CGSize] = [:]

    init(settings: SnapSettings) {
        self.settings = settings
    }

    /// Starts (or stops) the monitor to match Accessibility permission and
    /// the Settings toggle. Safe to call repeatedly.
    func refreshPermission() {
        if Permissions.accessibilityGranted && settings.dragSnappingEnabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown],
            handler: { [weak self] in self?.handle($0) }
        )
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resetDrag()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard event.keyCode == 53 else { return } // Escape
            cancelled = true
            footprint.hide()
            currentZone = nil
        case .leftMouseDown:
            beginDrag()
        case .leftMouseDragged:
            continueDrag()
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
    }

    private func beginDrag() {
        resetDrag()
        let cursor = NSEvent.mouseLocation
        draggedWindow = AXWindow.windowUnderCursor(at: cursor)
        initialFrame = draggedWindow?.frame
    }

    private func continueDrag() {
        guard !cancelled, let draggedWindow, let initialFrame, let frame = draggedWindow.frame else { return }

        if !isWindowMoving {
            // Only a move: the size Halfwin observed at mouse-down is unchanged
            // while the origin has. A resize, or no movement yet, does nothing.
            guard frame.size == initialFrame.size, frame.origin != initialFrame.origin else { return }
            isWindowMoving = true
            if let preSnapSize = snappedSizes.removeValue(forKey: draggedWindow) {
                restoreSize(preSnapSize, current: frame, window: draggedWindow)
            }
        }

        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }),
              let position = SnapGeometry.position(for: cursor, in: screen.frame) else {
            footprint.hide()
            currentZone = nil
            return
        }

        let action = resolvedAction(for: position, cursor: cursor, screen: screen, previous: currentZone?.action)
        guard action != .none else {
            footprint.hide()
            currentZone = nil
            return
        }

        let zone = Zone(screen: screen, position: position, action: action)
        guard zone != currentZone else { return }
        currentZone = zone

        if let rect = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                         currentWindowFrame: frame, portrait: screen.frame.isPortrait) {
            footprint.show(in: rect)
        } else {
            footprint.hide()
        }
    }

    private func endDrag() {
        defer { resetDrag() }
        footprint.hide()
        guard !cancelled, isWindowMoving, let zone = currentZone,
              let draggedWindow, let frame = draggedWindow.frame else { return }
        guard let target = SnapGeometry.frame(for: zone.action, visibleFrame: zone.screen.visibleFrame,
                                              currentWindowFrame: frame, portrait: zone.screen.frame.isPortrait) else { return }
        snappedSizes[draggedWindow] = frame.size
        draggedWindow.setFrame(target)
    }

    private func resetDrag() {
        draggedWindow = nil
        initialFrame = nil
        isWindowMoving = false
        cancelled = false
        currentZone = nil
    }

    private func resolvedAction(for position: SnapPosition, cursor: CGPoint, screen: NSScreen, previous: SnapAction?) -> SnapAction {
        if screen.frame.isPortrait {
            return SnapGeometry.portraitAction(for: position, cursor: cursor, screenFrame: screen.frame, previous: previous)
        }
        switch settings.action(for: position) {
        case .leftTopBottomHalfCompound:
            return SnapGeometry.resolveHalfCompound(side: .left, cursor: cursor, screenFrame: screen.frame)
        case .rightTopBottomHalfCompound:
            return SnapGeometry.resolveHalfCompound(side: .right, cursor: cursor, screenFrame: screen.frame)
        case .bottomThirdsCompound:
            return SnapGeometry.resolveBottomThirdsCompound(cursor: cursor, screenFrame: screen.frame, previous: previous)
        case let plain:
            return plain
        }
    }

    /// Adapted from Rectangle's `DragRestorePlacement.frame(from:size:cursor:)`
    /// (`SnappingManager.swift`, MIT): restore the saved size while keeping
    /// the cursor's grab point inside the window instead of snapping the
    /// far edge back and yanking the window under the pointer.
    private func restoreSize(_ size: CGSize, current: CGRect, window: AXWindow) {
        let cursor = NSEvent.mouseLocation
        var restored = CGRect(origin: current.origin, size: size)
        let inset = min(32, size.width / 2)
        let neededShift = cursor.x - current.minX - (size.width - inset)
        restored.origin.x += min(max(0, neededShift), max(0, current.width - size.width))
        window.setFrame(restored)
    }
}

private extension CGRect {
    var isPortrait: Bool { height > width }
}
