import AppKit
import Combine
import os // DIAG remove after live capture

/// Watches system-wide window gestures for edge snapping and shared borders,
/// following Rectangle's `SnappingManager.swift` (MIT): passive `NSEvent` global
/// monitor, resolve-the-window-once-per-drag, footprint-on-hover,
/// snap-on-release, escape-to-cancel — with the window-server/AX
/// cross-checking and multi-monitor animation machinery stripped out.
final class SnapManager {
    private struct Zone {
        let screen: NSScreen
        let position: SnapPosition
        let action: SnapAction
        var effectiveAction: SnapAction
        var frame: CGRect
        let cursor: CGPoint
    }

    private struct DragDiagnostic { // DIAG remove after live capture
        let downCursor: CGPoint // DIAG remove after live capture
        let downEventQuartzPoint: CGPoint? // DIAG remove after live capture
        let hitTest: String // DIAG remove after live capture
        let processID: pid_t? // DIAG remove after live capture
        let initialFrame: CGRect? // DIAG remove after live capture
        var downLogged = false // DIAG remove after live capture
        var firstDragLogged = false // DIAG remove after live capture
        var firstDragCursor: CGPoint? // DIAG remove after live capture
        var firstDragEventQuartzPoint: CGPoint? // DIAG remove after live capture
        var topEncounter: String? // DIAG remove after live capture
        var eligibleCenterEverSeen = false // DIAG remove after live capture
        var showDropBarAttempted = false // DIAG remove after live capture
        var dropBarEverVisible = false // DIAG remove after live capture
        var lastFrame: CGRect? // DIAG remove after live capture
    }

    private let settings: SnapSettings
    private let layoutMenu: LayoutMenuManager
    private let diagLogger = Logger(subsystem: "com.dhrlabs.halfwin", category: "diag") // DIAG remove after live capture
    private lazy var divider = SnapDividerManager()
    private var monitor: Any?
    private lazy var footprint = FootprintWindow()

    private var draggedWindow: AXWindow?
    private var initialFrame: CGRect?
    private var lockedSize: CGSize?
    private var isWindowMoving = false
    private var didReceiveDrag = false
    private var cancelled = false
    private var currentZone: Zone?
    private var currentPreviewFrame: CGRect?
    private var dragToTopLayoutsEnabled = false
    private var dropScreen: NSScreen?
    private var currentDropZone: LayoutDropZone?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var dragDiagnostic: DragDiagnostic? // DIAG remove after live capture

    /// Restore size only; the registry owns the current snapped frame.
    private var preSnapSizes: [AXWindow: CGSize] = [:]

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
        settings.$linkedResizeEnabled
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshPermission() } }
            .store(in: &cancellables)
        settings.$glueTouchingWindowsEnabled
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshPermission() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPermission() }
    }

    /// Starts (or stops) the monitor to match Accessibility permission and
    /// the Settings toggle. Safe to call repeatedly.
    func refreshPermission() {
        divider.setEnabled(settings.linkedResizeEnabled && Permissions.accessibilityGranted)
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
        if Permissions.accessibilityGranted && (settings.dragSnappingEnabled || settings.glueTouchingWindowsEnabled) {
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
        guard settings.dragSnappingEnabled || settings.glueTouchingWindowsEnabled else { return }
        switch event.type {
        case .keyDown:
            guard settings.dragSnappingEnabled, event.keyCode == 53 else { return } // Escape
            cancelled = true
            hidePreview()
            currentZone = nil
            clearDropBar()
        case .leftMouseDown:
            beginDrag(event)
        case .leftMouseDragged:
            didReceiveDrag = true
            if var diagnostic = dragDiagnostic { // DIAG remove after live capture
                if !diagnostic.downLogged { // DIAG remove after live capture
                    logDiagnostic("snapDrag down cursorAppKit=\(diagnostic.downCursor) sourceQuartz=\(String(describing: diagnostic.downEventQuartzPoint)) pid=\(String(describing: diagnostic.processID)) frame=\(String(describing: diagnostic.initialFrame)) hitTest={\(diagnostic.hitTest)}") // DIAG remove after live capture
                    diagnostic.downLogged = true // DIAG remove after live capture
                }
                if diagnostic.firstDragCursor == nil { // DIAG remove after live capture
                    diagnostic.firstDragCursor = NSEvent.mouseLocation // DIAG remove after live capture
                    diagnostic.firstDragEventQuartzPoint = event.cgEvent?.location // DIAG remove after live capture
                }
                dragDiagnostic = diagnostic // DIAG remove after live capture
            }
            recordTop8Encounter(at: NSEvent.mouseLocation) // DIAG remove after live capture
            if settings.dragSnappingEnabled { continueDrag() }
            if dragDiagnostic?.firstDragLogged != true { // DIAG remove after live capture
                logFirstDrag(frame: nil, classification: firstDragSkipClassification()) // DIAG remove after live capture
            }
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
    }

    private func beginDrag(_ event: NSEvent) {
        resetDrag()
        pruneUnreadableRestoreSizes()
        let cursor = NSEvent.mouseLocation
        var hitTest = "noTrace" // DIAG remove after live capture
        draggedWindow = AXWindow.windowUnderCursor(at: cursor) { hitTest = $0 } // DIAG remove after live capture
        if let draggedWindow, SnapWindowRegistry.shared.hasRecord(for: draggedWindow) {
            SnapWindowRegistry.shared.validateIfNeeded(interval: 0.1)
        }
        initialFrame = draggedWindow?.frame
        dragDiagnostic = DragDiagnostic(downCursor: cursor, downEventQuartzPoint: event.cgEvent?.location, // DIAG remove after live capture
                                        hitTest: hitTest, processID: draggedWindow?.processIdentifier, // DIAG remove after live capture
                                        initialFrame: initialFrame, lastFrame: initialFrame) // DIAG remove after live capture
    }

    /// Destroyed AX elements cannot be restored; keep transient failures for
    /// a later drag instead of dropping their saved size.
    private func pruneUnreadableRestoreSizes() {
        for window in Array(preSnapSizes.keys) where AXWindow.frameWithError(of: window.element).error == .invalidUIElement {
            preSnapSizes.removeValue(forKey: window)
        }
    }

    private func continueDrag() {
        guard !cancelled, let draggedWindow, let initialFrame else { return }

        if !isWindowMoving {
            guard let frame = draggedWindow.frame else {
                logFirstDrag(frame: nil, classification: "frameUnavailable") // DIAG remove after live capture
                return
            }
            if var diagnostic = dragDiagnostic { // DIAG remove after live capture
                diagnostic.lastFrame = frame // DIAG remove after live capture
                dragDiagnostic = diagnostic // DIAG remove after live capture
            }
            // Only a move: the size Halfwin observed at mouse-down is unchanged
            // while the origin has. A resize, or no movement yet, does nothing.
            guard frame.size == initialFrame.size else {
                logFirstDrag(frame: frame, classification: "sizeChanged") // DIAG remove after live capture
                return
            }
            guard frame.origin != initialFrame.origin else {
                logFirstDrag(frame: frame, classification: "stationary") // DIAG remove after live capture
                return
            }
            isWindowMoving = true
            logFirstDrag(frame: frame, classification: "sameSizeOriginChanged") // DIAG remove after live capture
            lockedSize = frame.size
            // A confirmed move uses the registry's latest frame, including a
            // manual edge resize, as the restore guard.
            let registry = SnapWindowRegistry.shared
            if let size = preSnapSizes.removeValue(forKey: draggedWindow),
               let record = registry.record(for: draggedWindow), record.state == .active,
               SnapGeometry.isClose(initialFrame, record.frame, tolerance: 1) {
                registry.unsnap(draggedWindow)
                restoreSize(size, current: frame, window: draggedWindow)
                lockedSize = size
            } else {
                registry.unsnap(draggedWindow)
            }
        }

        guard let size = lockedSize else { return }
        updateTarget(at: NSEvent.mouseLocation, window: draggedWindow, size: size)
    }

    private func logFirstDrag(frame: CGRect?, classification: String) { // DIAG remove after live capture
        guard var diagnostic = dragDiagnostic, !diagnostic.firstDragLogged else { return } // DIAG remove after live capture
        logDiagnostic("snapDrag firstDrag cursorAppKit=\(String(describing: diagnostic.firstDragCursor)) sourceQuartz=\(String(describing: diagnostic.firstDragEventQuartzPoint)) frame=\(String(describing: frame)) classification=\(classification) recognizedMove=\(isWindowMoving) snapEnabled=\(settings.dragSnappingEnabled) cancelled=\(cancelled) windowPresent=\(draggedWindow != nil) initialFramePresent=\(initialFrame != nil)") // DIAG remove after live capture
        diagnostic.firstDragLogged = true // DIAG remove after live capture
        if let frame { diagnostic.lastFrame = frame } // DIAG remove after live capture
        dragDiagnostic = diagnostic // DIAG remove after live capture
    }

    private func firstDragSkipClassification() -> String { // DIAG remove after live capture
        if cancelled { return "cancelled" } // DIAG remove after live capture
        if draggedWindow == nil { return "missingWindow" } // DIAG remove after live capture
        if initialFrame == nil { return "missingInitialFrame" } // DIAG remove after live capture
        if !settings.dragSnappingEnabled { return "dragSnappingDisabled" } // DIAG remove after live capture
        return "frameReadSkipped" // DIAG remove after live capture
    }

    private func recordTop8Encounter(at cursor: CGPoint) { // DIAG remove after live capture
        guard var diagnostic = dragDiagnostic else { return } // DIAG remove after live capture
        guard let screen = NSScreen.screens.first(where: { // DIAG remove after live capture
            cursor.x >= $0.frame.minX && cursor.x <= $0.frame.maxX && // DIAG remove after live capture
                cursor.y >= $0.frame.maxY - 8 && cursor.y <= $0.frame.maxY // DIAG remove after live capture
        }) else { return } // DIAG remove after live capture
        let pointAbove = CGPoint(x: cursor.x, y: screen.frame.maxY + 1) // DIAG remove after live capture
        let displayAbove = NSScreen.screens.contains { $0 != screen && $0.frame.contains(pointAbove) } // DIAG remove after live capture
        let center = abs(cursor.x - screen.frame.midX) <= layoutMenu.hotZoneWidth / 2 // DIAG remove after live capture
        let flags = "dragTop=\(dragToTopLayoutsEnabled),snap=\(settings.dragSnappingEnabled),glue=\(settings.glueTouchingWindowsEnabled),fill=\(settings.fillAvailableSpace)" // DIAG remove after live capture
        diagnostic.eligibleCenterEverSeen = diagnostic.eligibleCenterEverSeen || (center && !displayAbove) // DIAG remove after live capture
        let summary = "cursorAppKit=\(cursor),display=\(SnapDisplayID(screen).number),screenFrame=\(screen.frame),hotZoneWidth=\(layoutMenu.hotZoneWidth),center=\(center),displayAbove=\(displayAbove),flags={\(flags)},recognizedMove=\(isWindowMoving)" // DIAG remove after live capture
        if diagnostic.topEncounter == nil { // DIAG remove after live capture
            diagnostic.topEncounter = summary // DIAG remove after live capture
            logDiagnostic("snapDrag top8 \(summary)") // DIAG remove after live capture
        }
        dragDiagnostic = diagnostic // DIAG remove after live capture
    }

    private func updateTarget(at cursor: CGPoint, window: AXWindow, size: CGSize) {
        if layoutMenu.isDropBarVisible, var diagnostic = dragDiagnostic { // DIAG remove after live capture
            diagnostic.dropBarEverVisible = true // DIAG remove after live capture
            dragDiagnostic = diagnostic // DIAG remove after live capture
        }
        if dragToTopLayoutsEnabled, let screen = layoutTriggerScreen(for: cursor) {
            if dropScreen != screen || !layoutMenu.isDropBarVisible {
                dropScreen = screen
                currentDropZone = nil
                hidePreview()
                if var diagnostic = dragDiagnostic { // DIAG remove after live capture
                    diagnostic.showDropBarAttempted = true // DIAG remove after live capture
                    dragDiagnostic = diagnostic // DIAG remove after live capture
                }
                layoutMenu.showDropBar(on: screen, for: window, startFrame: initialFrame ?? .zero)
                if layoutMenu.isDropBarVisible, var diagnostic = dragDiagnostic { // DIAG remove after live capture
                    diagnostic.dropBarEverVisible = true // DIAG remove after live capture
                    dragDiagnostic = diagnostic // DIAG remove after live capture
                }
            }
            currentZone = nil
            let zone = layoutMenu.dropZone(at: cursor)
            if zone != currentDropZone {
                currentDropZone = zone
                layoutMenu.highlight(zone)
            }
            if let zone, let base = layoutMenu.dropPreviewFrame(
                for: zone, currentWindowFrame: CGRect(origin: .zero, size: size)
            ) {
                showPreview(base)
            } else {
                hidePreview()
            }
            return // The drop bar owns the top-center strip, including maximize.
        }

        if dropScreen != nil {
            if layoutMenu.isDropBarNear(cursor) {
                let zone = layoutMenu.dropZone(at: cursor)
                currentZone = nil
                if zone != currentDropZone {
                    currentDropZone = zone
                    layoutMenu.highlight(zone)
                }
                if let zone, let base = layoutMenu.dropPreviewFrame(
                    for: zone, currentWindowFrame: CGRect(origin: .zero, size: size)
                ) {
                    showPreview(base)
                } else {
                    hidePreview()
                }
                return
            }
            clearDropBar()
        }

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }),
              let position = SnapGeometry.position(for: cursor, in: screen.frame) else {
            hidePreview()
            currentZone = nil
            currentDropZone = nil
            return
        }

        let action = resolvedAction(for: position, cursor: cursor, screen: screen, previous: currentZone?.action)
        guard action != .none else {
            hidePreview()
            currentZone = nil
            currentDropZone = nil
            return
        }

        if let rect = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                         currentWindowFrame: CGRect(origin: .zero, size: size), portrait: screen.frame.isPortrait) {
            let registry = SnapWindowRegistry.shared
            if settings.fillAvailableSpace {
                registry.validateIfNeeded(interval: 0.1)
            }
            let neighbors = settings.fillAvailableSpace
                ? registry.fillNeighborFrames(on: screen, excluding: window)
                : []
            let resolved = resolvedFrame(for: action, position: position, cursor: cursor, base: rect,
                                         screen: screen, snappedFrames: neighbors, previous: currentPreviewFrame)
            let zone = Zone(screen: screen, position: position, action: action,
                            effectiveAction: resolved.action, frame: resolved.frame, cursor: cursor)
            currentZone = zone
            showPreview(resolved.frame)
        } else {
            currentZone = nil
            hidePreview()
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
        var snapNotification: (window: AXWindow, action: SnapAction, screen: NSScreen, frame: CGRect)?
        var endingFrame: CGRect? // DIAG remove after live capture
        defer {
            if didReceiveDrag, let diagnostic = dragDiagnostic { // DIAG remove after live capture
                logDiagnostic("snapDrag end frame=\(String(describing: endingFrame ?? diagnostic.lastFrame)) recognizedMove=\(isWindowMoving) topSeen=\(diagnostic.topEncounter != nil) eligibleCenterEverSeen=\(diagnostic.eligibleCenterEverSeen) showDropBarAttempted=\(diagnostic.showDropBarAttempted) dropBarEverVisible=\(diagnostic.dropBarEverVisible)") // DIAG remove after live capture
            }
            footprint.hide()
            resetDrag()
            if let notification = snapNotification {
                DispatchQueue.main.async {
                    SnapEvents.didSnap(window: notification.window, action: notification.action,
                                       screen: notification.screen, frame: notification.frame)
                }
            }
        }
        footprint.hide()
        guard !cancelled, didReceiveDrag, let draggedWindow,
              let initialFrame, let frame = draggedWindow.frame else { return }
        endingFrame = frame // DIAG remove after live capture
        if var diagnostic = dragDiagnostic { // DIAG remove after live capture
            diagnostic.lastFrame = frame // DIAG remove after live capture
            dragDiagnostic = diagnostic // DIAG remove after live capture
        }
        if settings.dragSnappingEnabled, isWindowMoving, let size = lockedSize {
            if let currentDropZone {
                let target = layoutMenu.applyDrop(currentDropZone)
                if case .preset(.restore) = currentDropZone {
                    preSnapSizes.removeValue(forKey: draggedWindow)
                    SnapWindowRegistry.shared.unsnap(draggedWindow)
                } else if target != nil {
                    preSnapSizes[draggedWindow] = size
                }
                return
            }
            if var zone = currentZone {
                if settings.fillAvailableSpace {
                    SnapWindowRegistry.shared.validate()
                    guard let fixed = SnapGeometry.frame(for: zone.action, visibleFrame: zone.screen.visibleFrame,
                                                         currentWindowFrame: CGRect(origin: .zero, size: size),
                                                         portrait: zone.screen.frame.isPortrait) else { return }
                    let neighbors = SnapWindowRegistry.shared.fillNeighborFrames(on: zone.screen, excluding: draggedWindow)
                    let resolved = resolvedFrame(for: zone.action, position: zone.position, cursor: zone.cursor,
                                                 base: fixed, screen: zone.screen, snappedFrames: neighbors,
                                                 previous: zone.frame)
                    zone.effectiveAction = resolved.action
                    zone.frame = resolved.frame
                }
                draggedWindow.setFrame(zone.frame)
                // Only remember this as a real snap if the window actually landed
                // there — a failed AX write shouldn't let a later drag "restore" to
                // a size it was never snapped from.
                if let readBack = draggedWindow.frame,
                   (zone.effectiveAction == .fill
                    ? !SnapGeometry.isClose(readBack, frame, tolerance: 1)
                    : SnapGeometry.matchesSnapEdges(readBack, target: zone.frame, screenFrame: zone.screen.visibleFrame) &&
                        SnapGeometry.matchesSnapSize(readBack, target: zone.frame)) {
                    preSnapSizes[draggedWindow] = frame.size
                    snapNotification = (draggedWindow, zone.effectiveAction, zone.screen, readBack)
                }
                return
            }
        }

        guard settings.glueTouchingWindowsEnabled,
              !SnapGeometry.isClose(initialFrame, frame, tolerance: 1),
              currentZone == nil, currentDropZone == nil else { return }
        glue(draggedWindow, to: frame)
    }

    private func glue(_ window: AXWindow, to frame: CGRect) {
        guard window.isStandardWindow, !window.isMinimized, !window.isFullScreen,
              let pid = window.processIdentifier,
              let application = NSRunningApplication(processIdentifier: pid),
              application.activationPolicy == .regular, !application.isHidden,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { return }

        let registry = SnapWindowRegistry.shared
        registry.validate()
        let choices = SnapWindowInventory.choices(on: screen, excluding: [])
        guard let handledID = choices.first(where: { $0.window == window })?.id,
              let visibleWindows = SnapWindowInventory.onScreenWindows() else { return }
        let matches = choices.compactMap {
            choice -> (window: AXWindow, neighborFrame: CGRect, target: CGRect, distance: CGFloat)? in
            guard choice.id != handledID, !choice.window.isMinimized, !choice.window.isFullScreen,
                  let neighborFrame = choice.window.frame,
                  let aligned = SnapGlueGeometry.alignedFrame(frame, with: neighborFrame,
                                                              in: screen.visibleFrame,
                                                              tolerance: SnapGeometry.edgeTolerance) else { return nil }
            guard let visibleIndex = visibleWindows.firstIndex(where: { $0.id == choice.id }) else { return nil }
            let coveringFrames = visibleWindows[..<visibleIndex]
                .filter { $0.id != handledID }
                .map(\.frame)
            let edge: CGRect
            if abs(aligned.minX - neighborFrame.maxX) <= SnapGeometry.edgeTolerance {
                guard neighborFrame.width >= 2 else { return nil }
                edge = CGRect(x: neighborFrame.maxX - 2, y: neighborFrame.minY, width: 2, height: neighborFrame.height)
            } else if abs(aligned.maxX - neighborFrame.minX) <= SnapGeometry.edgeTolerance {
                guard neighborFrame.width >= 2 else { return nil }
                edge = CGRect(x: neighborFrame.minX, y: neighborFrame.minY, width: 2, height: neighborFrame.height)
            } else if abs(aligned.minY - neighborFrame.maxY) <= SnapGeometry.edgeTolerance {
                guard neighborFrame.height >= 2 else { return nil }
                edge = CGRect(x: neighborFrame.minX, y: neighborFrame.maxY - 2, width: neighborFrame.width, height: 2)
            } else if abs(aligned.maxY - neighborFrame.minY) <= SnapGeometry.edgeTolerance {
                guard neighborFrame.height >= 2 else { return nil }
                edge = CGRect(x: neighborFrame.minX, y: neighborFrame.minY, width: neighborFrame.width, height: 2)
            } else {
                return nil
            }
            guard !SnapWindowInventory.isCovered(edge, by: coveringFrames) else { return nil }
            let distance = abs(aligned.minX - frame.minX) + abs(aligned.minY - frame.minY) +
                abs(aligned.width - frame.width) + abs(aligned.height - frame.height)
            return (choice.window, neighborFrame, aligned, distance)
        }
        guard let match = matches.min(by: { $0.distance < $1.distance }) else { return }
        guard let neighborBefore = match.window.frame,
              SnapGeometry.isClose(neighborBefore, match.neighborFrame, tolerance: 1) else { return }
        window.setFrame(match.target)
        guard let readBack = window.frame,
              SnapGeometry.isClose(readBack, match.target, tolerance: 1),
              let neighborFrame = match.window.frame,
              SnapGeometry.isClose(neighborFrame, neighborBefore, tolerance: 1),
              let aligned = SnapGlueGeometry.alignedFrame(readBack, with: neighborFrame,
                                                          in: screen.visibleFrame, tolerance: 1),
              SnapGeometry.isClose(aligned, readBack, tolerance: 1) else { return }
        SnapEvents.didSnap(window: window, action: .fill, screen: screen, origin: .glue, frame: readBack)
        SnapEvents.didSnap(window: match.window, action: .fill, screen: screen, origin: .glue, frame: neighborFrame)
    }

    private func resetDrag() {
        clearDropBar()
        draggedWindow = nil
        initialFrame = nil
        isWindowMoving = false
        didReceiveDrag = false
        cancelled = false
        currentZone = nil
        currentPreviewFrame = nil
        dragDiagnostic = nil // DIAG remove after live capture
    }

    private func clearDropBar() {
        layoutMenu.hideDropBar()
        dropScreen = nil
        currentDropZone = nil
    }

    private func logDiagnostic(_ message: String) { // DIAG remove after live capture
        diagLogger.notice("HWDIAG \(message, privacy: .public)") // DIAG remove after live capture
    }

    private func resolvedAction(for position: SnapPosition, cursor: CGPoint, screen: NSScreen, previous: SnapAction?) -> SnapAction {
        if screen.frame.isPortrait {
            return SnapGeometry.portraitAction(for: position, cursor: cursor, screenFrame: screen.frame, previous: previous)
        }
        switch settings.action(for: position) {
        case .leftTopBottomHalfCompound:
            return settings.sideEdgesSnapToTopBottomHalf
                ? SnapGeometry.resolveHalfCompound(side: .left, cursor: cursor, screenFrame: screen.frame) : .leftHalf
        case .rightTopBottomHalfCompound:
            return settings.sideEdgesSnapToTopBottomHalf
                ? SnapGeometry.resolveHalfCompound(side: .right, cursor: cursor, screenFrame: screen.frame) : .rightHalf
        case .bottomThirdsCompound:
            return SnapGeometry.resolveBottomThirdsCompound(cursor: cursor, screenFrame: screen.frame, previous: previous)
        case let plain:
            return plain
        }
    }

    private func resolvedFrame(for action: SnapAction, position: SnapPosition, cursor: CGPoint, base: CGRect,
                               screen: NSScreen, snappedFrames: [CGRect], previous: CGRect?) -> (action: SnapAction, frame: CGRect) {
        guard settings.fillAvailableSpace else { return (action, base) }
        switch SnapGeometry.fillFrame(at: cursor, position: position, action: action, fixedFrame: base,
                                      visibleFrame: screen.visibleFrame, snappedFrames: snappedFrames,
                                      previousFrame: previous) {
        case .fixed:
            return (action, base)
        case let .fill(frame):
            return (.fill, frame)
        }
    }

    private func showPreview(_ frame: CGRect) {
        guard frame != currentPreviewFrame else { return }
        currentPreviewFrame = frame
        footprint.show(in: frame)
    }

    private func hidePreview() {
        currentPreviewFrame = nil
        footprint.hide()
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
