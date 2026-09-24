import AppKit
import Combine

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
    private let layoutMenu: LayoutMenuManager
    private var monitor: Any?
    private lazy var footprint = FootprintWindow()

    private var draggedWindow: AXWindow?
    private var initialFrame: CGRect?
    private var lockedSize: CGSize?
    private var isWindowMoving = false
    private var cancelled = false
    private var currentZone: Zone?
    private var dragToTopLayoutsEnabled = false
    private var dropScreen: NSScreen?
    private var currentDropZone: LayoutDropZone?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    /// Pre-snap target and size for windows Halfwin has snapped, so a later
    /// drag can restore them (Rectangle's `unsnapRestore`) but only when that
    /// drag starts from the same snapped frame — otherwise the entry is
    /// stale (the window moved another way since) and is dropped. Keyed by
    /// the AX element, not a window id — this port never needs a CGWindowID.
    private var snappedInfo: [AXWindow: (target: CGRect, preSnapSize: CGSize)] = [:]

    init(settings: SnapSettings, layoutMenu: LayoutMenuManager) {
        self.settings = settings
        self.layoutMenu = layoutMenu
        settings.$dragSnappingEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                if !enabled || Permissions.accessibilityGranted {
                    MissionControlDrag.setDragSnappingEnabled(enabled)
                }
                // @Published fires before the stored value changes, so hop
                // to the next run-loop turn before reacting to it.
                DispatchQueue.main.async { self?.refreshPermission() }
            }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPermission() }
    }

    /// Starts (or stops) the monitor to match Accessibility permission and
    /// the Settings toggle. Safe to call repeatedly.
    func refreshPermission() {
        if settings.dragSnappingEnabled && Permissions.accessibilityGranted {
            MissionControlDrag.setDragSnappingEnabled(true)
        }
        if Permissions.accessibilityGranted {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            // Accessibility isn't granted yet: poll lightly so a grant made
            // while the app sits in the background still takes effect
            // without waiting for the menu to reopen.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.refreshPermission()
            }
        }
        if Permissions.accessibilityGranted && settings.dragSnappingEnabled {
            start()
        } else {
            stop()
        }
    }

    func setDragToTopLayoutsEnabled(_ enabled: Bool) {
        dragToTopLayoutsEnabled = enabled
        if !enabled { clearDropBar() }
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
        footprint.hide()
        resetDrag()
    }

    private func handle(_ event: NSEvent) {
        guard settings.dragSnappingEnabled else { return }
        switch event.type {
        case .keyDown:
            guard event.keyCode == 53 else { return } // Escape
            cancelled = true
            footprint.hide()
            currentZone = nil
            clearDropBar()
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
        pruneUnreadableSnapInfo()
        let cursor = NSEvent.mouseLocation
        draggedWindow = AXWindow.windowUnderCursor(at: cursor)
        initialFrame = draggedWindow?.frame
    }

    /// Windows Halfwin can no longer read (closed, or the AX call timed out)
    /// have nothing to restore to; drop them so the table doesn't grow
    /// forever.
    private func pruneUnreadableSnapInfo() {
        for window in snappedInfo.keys where window.frame == nil {
            snappedInfo.removeValue(forKey: window)
        }
    }

    private func continueDrag() {
        guard !cancelled, let draggedWindow, let initialFrame else { return }

        if !isWindowMoving {
            guard let frame = draggedWindow.frame else { return }
            // Only a move: the size Halfwin observed at mouse-down is unchanged
            // while the origin has. A resize, or no movement yet, does nothing.
            guard frame.size == initialFrame.size, frame.origin != initialFrame.origin else { return }
            isWindowMoving = true
            lockedSize = frame.size
            // A move confirmed: this is the one AX frame read this drag needs
            // (besides the drop). Restore only if this drag actually started
            // from the frame Halfwin snapped it to — otherwise the entry is
            // stale and stays dropped from pruneUnreadableSnapInfo/here.
            if let info = snappedInfo.removeValue(forKey: draggedWindow), SnapGeometry.isClose(initialFrame, info.target, tolerance: 1) {
                restoreSize(info.preSnapSize, current: frame, window: draggedWindow)
                lockedSize = info.preSnapSize
            }
        }

        guard let size = lockedSize else { return }
        updateTarget(at: NSEvent.mouseLocation, window: draggedWindow, size: size)
    }

    private func updateTarget(at cursor: CGPoint, window: AXWindow, size: CGSize) {
        if dragToTopLayoutsEnabled, let screen = layoutTriggerScreen(for: cursor) {
            if dropScreen != screen || !layoutMenu.isDropBarVisible {
                dropScreen = screen
                currentDropZone = nil
                footprint.hide()
                layoutMenu.showDropBar(on: screen, for: window, startFrame: initialFrame ?? .zero)
            }
            currentZone = nil
            let zone = layoutMenu.dropZone(at: cursor)
            guard zone != currentDropZone else { return }
            currentDropZone = zone
            layoutMenu.highlight(zone)
            if let zone, let frame = layoutMenu.dropPreviewFrame(
                for: zone, currentWindowFrame: CGRect(origin: .zero, size: size)
            ) {
                footprint.show(in: frame)
            } else {
                footprint.hide()
            }
            return // The drop bar owns the top-center strip, including maximize.
        }

        if dropScreen != nil {
            if layoutMenu.isDropBarNear(cursor) {
                let zone = layoutMenu.dropZone(at: cursor)
                guard zone != currentDropZone else { return }
                currentDropZone = zone
                currentZone = nil
                layoutMenu.highlight(zone)
                if let zone, let frame = layoutMenu.dropPreviewFrame(
                    for: zone, currentWindowFrame: CGRect(origin: .zero, size: size)
                ) {
                    footprint.show(in: frame)
                } else {
                    footprint.hide()
                }
                return
            }
            clearDropBar()
        }

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }),
              let position = SnapGeometry.position(for: cursor, in: screen.frame) else {
            footprint.hide()
            currentZone = nil
            currentDropZone = nil
            return
        }

        let action = resolvedAction(for: position, cursor: cursor, screen: screen, previous: currentZone?.action)
        guard action != .none else {
            footprint.hide()
            currentZone = nil
            currentDropZone = nil
            return
        }

        let zone = Zone(screen: screen, position: position, action: action)
        guard zone != currentZone else { return }
        currentZone = zone

        if let rect = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                         currentWindowFrame: CGRect(origin: .zero, size: size), portrait: screen.frame.isPortrait) {
            footprint.show(in: rect)
        } else {
            footprint.hide()
        }
    }

    private func layoutTriggerScreen(for cursor: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let frame = screen.frame
            let pointAbove = CGPoint(x: cursor.x, y: frame.maxY + 1)
            guard !NSScreen.screens.contains(where: { $0 != screen && $0.frame.contains(pointAbove) }) else { return false }
            return cursor.x >= frame.minX && cursor.x <= frame.maxX &&
                cursor.y >= frame.maxY - 8 && cursor.y <= frame.maxY &&
                abs(cursor.x - frame.midX) <= layoutMenu.hotZoneWidth / 2
        }
    }

    private func endDrag() {
        var snapNotification: (window: AXWindow, action: SnapAction, screen: NSScreen)?
        defer {
            footprint.hide()
            resetDrag()
            if let notification = snapNotification {
                DispatchQueue.main.async {
                    SnapEvents.didSnap(window: notification.window, action: notification.action, screen: notification.screen)
                }
            }
        }
        footprint.hide()
        guard !cancelled, isWindowMoving, let draggedWindow, let size = lockedSize else { return }
        if let currentDropZone {
            let target = layoutMenu.applyDrop(currentDropZone)
            if case .preset(.restore) = currentDropZone {
                snappedInfo.removeValue(forKey: draggedWindow)
            } else if let target {
                snappedInfo[draggedWindow] = (target: target, preSnapSize: size)
            }
            return
        }
        guard let zone = currentZone, let frame = draggedWindow.frame else { return }
        guard let target = SnapGeometry.frame(for: zone.action, visibleFrame: zone.screen.visibleFrame,
                                              currentWindowFrame: frame, portrait: zone.screen.frame.isPortrait) else { return }
        draggedWindow.setFrame(target)
        // Only remember this as a real snap if the window actually landed
        // there — a failed AX write shouldn't let a later drag "restore" to
        // a size it was never snapped from.
        if let readBack = draggedWindow.frame, SnapGeometry.isClose(readBack, target, tolerance: 2) {
            snappedInfo[draggedWindow] = (target: target, preSnapSize: frame.size)
            snapNotification = (draggedWindow, zone.action, zone.screen)
        }
    }

    private func resetDrag() {
        clearDropBar()
        draggedWindow = nil
        initialFrame = nil
        isWindowMoving = false
        cancelled = false
        currentZone = nil
    }

    private func clearDropBar() {
        layoutMenu.hideDropBar()
        dropScreen = nil
        currentDropZone = nil
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
        // Keep the top edge fixed (AppKit coords: origin is bottom-left) so
        // the title bar stays where the window was, instead of the drop
        // dragging the top edge down with the shrinking bottom.
        restored.origin.y = current.maxY - size.height
        let inset = min(32, size.width / 2)
        let neededShift = cursor.x - current.minX - (size.width - inset)
        restored.origin.x += min(max(0, neededShift), max(0, current.width - size.width))
        window.setFrame(restored)
    }

}

private extension CGRect {
    var isPortrait: Bool { height > width }
}
