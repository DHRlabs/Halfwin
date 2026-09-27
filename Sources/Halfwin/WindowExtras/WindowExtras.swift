import AppKit
import ApplicationServices
import CoreGraphics
import os // DIAG remove after live capture

enum ShowDesktopStyle: String, CaseIterable, Identifiable {
    case pushWindowsAside = "push-windows-aside"
    case hideApps = "hide-apps"

    static let defaultsKey = "Halfwin.showDesktopStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushWindowsAside: return "Push windows aside"
        case .hideApps: return "Hide apps"
        }
    }
}

enum ShowDesktopEvents {
    static let windowFrameWillChange = Notification.Name("Halfwin.showDesktopWindowFrameWillChange")

    static func willChangeFrame(of window: AXWindow, to frame: CGRect, pushedAside: Bool) {
        NotificationCenter.default.post(name: windowFrameWillChange, object: nil, userInfo: [
            "window": window, "frame": frame, "pushedAside": pushedAside
        ])
    }

    static func didForget(_ window: AXWindow) {
        NotificationCenter.default.post(name: windowFrameWillChange, object: nil, userInfo: [
            "window": window, "pushedAside": false
        ])
    }
}

/// Adds the small system-wide window actions that do not belong to drag snapping.
final class WindowExtrasManager {
    private static let eventMask: CGEventMask = [
        CGEventType.leftMouseDown, .leftMouseUp, .keyDown, .keyUp
    ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

    private var greenButtonEnabled = false
    private var titleBarDoubleClickEnabled = false
    private var showDesktopEnabled = false
    private var commandArrowEnabled = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var swallowedMouseDownEventNumber: Int64?
    private var swallowedCommandArrowKeyCodes = Set<Int64>()
    private var hiddenApplications: [NSRunningApplication]?
    private var hiddenApplicationsAt: TimeInterval?
    private var pushedWindows: [AXWindow: (frame: CGRect, pushedFrame: CGRect, windowID: CGWindowID, application: NSRunningApplication)] = [:]
    private var applicationToReactivate: NSRunningApplication?
    private var lastReportedDesktopState = false
    private let frameMemory = WindowFrameMemory()
    private let diagLogger = Logger(subsystem: "com.dhrlabs.halfwin", category: "diag") // DIAG remove after live capture
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    var onShowDesktopStateChange: ((Bool) -> Void)?

    var isShowingDesktop: Bool { hiddenApplications?.isEmpty == false || !pushedWindows.isEmpty }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restorePushedWindows() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                guard app.bundleIdentifier != "com.apple.finder" ||
                    AXWindow.focusedWindow(of: app) != nil else { return }
                if self.hiddenApplicationsAt.map({ ProcessInfo.processInfo.systemUptime - $0 >= 1 }) != false,
                   self.hiddenApplications?.contains(where: { $0.processIdentifier == app.processIdentifier }) == true,
                   !app.isHidden {
                    self.hiddenApplications?.removeAll { $0.processIdentifier == app.processIdentifier }
                    if self.hiddenApplications?.isEmpty == true {
                        self.hiddenApplications = nil
                        self.hiddenApplicationsAt = nil
                    }
                    self.applicationToReactivate = app
                    self.clearDesktopRestoreApplicationIfNeeded()
                    self.reportShowDesktopState()
                }
                guard !self.pushedWindows.isEmpty, app.activationPolicy == .regular else { return }
                self.applicationToReactivate = app
                self.restorePushedWindows(for: app)
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func setGreenButtonEnabled(_ enabled: Bool) {
        greenButtonEnabled = enabled
        refreshPermission()
    }

    func setTitleBarDoubleClickEnabled(_ enabled: Bool) {
        titleBarDoubleClickEnabled = enabled
        refreshPermission()
    }

    func setShowDesktopEnabled(_ enabled: Bool) {
        showDesktopEnabled = enabled
        if !enabled {
            restoreHiddenApplications()
            restorePushedWindows()
        }
        refreshPermission()
    }

    func toggleDesktopFromButton() -> Bool? {
        guard showDesktopEnabled, Permissions.accessibilityGranted else { return nil }
        toggleDesktop()
        return isShowingDesktop
    }

    func setCommandArrowEnabled(_ enabled: Bool) {
        commandArrowEnabled = enabled
        refreshPermission()
    }

    /// Keeps polling while a requested feature is waiting for Accessibility access.
    func refreshPermission() {
        let wantsEvents = greenButtonEnabled || titleBarDoubleClickEnabled || showDesktopEnabled || commandArrowEnabled
        guard wantsEvents else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            stopTap()
            return
        }
        if Permissions.accessibilityGranted {
            startTap()
        } else {
            stopTap()
        }
        if eventTap == nil {
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.refreshPermission()
                }
            }
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopTap()
        restoreHiddenApplications()
        restorePushedWindows()
        frameMemory.removeAll()
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedMouseDownEventNumber = nil
            swallowedCommandArrowKeyCodes.removeAll()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard Permissions.accessibilityGranted else {
            refreshPermission()
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            if showDesktopEnabled, !pushedWindows.isEmpty { // DIAG remove after live capture
                let pushedWindow = pushedWindow(at: event.location) // DIAG remove after live capture
                let screen = NSScreen.screens.first { $0.frame.axFlipped.contains(event.location) } // DIAG remove after live capture
                let displayID = screen.map { // DIAG remove after live capture
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                } ?? 0 // DIAG remove after live capture
                let hit = pushedWindow.flatMap { window in // DIAG remove after live capture
                    pushedWindows[window].map { pushed in
                        "windowID=\(pushed.windowID) pid=\(pushed.application.processIdentifier) expectedSliverFrame=\(pushed.pushedFrame)"
                    } // DIAG remove after live capture
                } ?? "none" // DIAG remove after live capture
                logDiagnostic("showDesktop sliverHitTest point=\(event.location) screen=\(displayID) hit=\(hit)") // DIAG remove after live capture
                if let pushedWindow { // DIAG remove after live capture
                    swallowMouseDown(event)
                    DispatchQueue.main.async { [weak self] in self?.restorePushedWindow(pushedWindow) }
                    return nil
                }
            }
            let point = event.location.axFlipped
            let clickCount = event.getIntegerValueField(.mouseEventClickState)
            let candidates = windowClickCandidates(at: event.location, clickCount: clickCount)
            let greenButtonCandidate = candidates.greenButton
            let titleBarCandidate = candidates.titleBar
            guard greenButtonCandidate || titleBarCandidate,
                  let hit = AXWindow.hitTest(at: point) else { return Unmanaged.passUnretained(event) }
            if greenButtonCandidate, !event.flags.contains(.maskAlternate),
               isEnabledGreenButton(hit.element, window: hit.window) {
                swallowMouseDown(event)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let current = hit.window.frame else { return }
                    _ = self.toggleToVisibleFrame(hit.window, current: current)
                }
                return nil
            }
            if titleBarCandidate, isTitleBarHit(hit.element, window: hit.window, at: point) {
                swallowMouseDown(event)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let current = hit.window.frame else { return }
                    _ = self.toggleToVisibleFrame(hit.window, current: current)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseUp:
            guard let swallowed = swallowedMouseDownEventNumber else { return Unmanaged.passUnretained(event) }
            swallowedMouseDownEventNumber = nil
            return swallowed == event.getIntegerValueField(.mouseEventNumber) ? nil : Unmanaged.passUnretained(event)
        case .keyDown:
            guard commandArrowEnabled, isExactCommand(event.flags) else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard [Int64(123), 124, 125, 126].contains(keyCode),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return Unmanaged.passUnretained(event)
            }
            if keyCode == 125,
               let app = NSWorkspace.shared.frontmostApplication,
               app.bundleIdentifier == "com.apple.finder",
               let windows = CGWindowListCopyWindowInfo(.optionAll.union(.excludeDesktopElements), kCGNullWindowID) as? [[String: Any]],
               !windows.contains(where: {
                   ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier &&
                   ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
               }) {
                return Unmanaged.passUnretained(event)
            }
            swallowedCommandArrowKeyCodes.insert(keyCode)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.applyCommandArrow(keyCode) }
            }
            return nil
        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard swallowedCommandArrowKeyCodes.remove(keyCode) != nil else { return Unmanaged.passUnretained(event) }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func startTap() {
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: Self.eventMask, callback: windowExtrasEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        swallowedMouseDownEventNumber = nil
        swallowedCommandArrowKeyCodes.removeAll()
    }

    private func isExactCommand(_ flags: CGEventFlags) -> Bool {
        let commandModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        return flags.intersection(commandModifiers) == .maskCommand
    }

    private func windowClickCandidates(at quartzPoint: CGPoint, clickCount: Int64) -> (greenButton: Bool, titleBar: Bool) {
        guard greenButtonEnabled || (titleBarDoubleClickEnabled && clickCount == 2),
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly.union(.excludeDesktopElements), kCGNullWindowID) as? [[String: Any]] else {
            return (false, false)
        }
        var candidates = (greenButton: false, titleBar: false)
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(quartzPoint) else { continue }
            let inTitleBarBand = quartzPoint.y <= frame.minY + 60
            candidates.greenButton = greenButtonEnabled && inTitleBarBand && quartzPoint.x <= frame.minX + 140
            candidates.titleBar = titleBarDoubleClickEnabled && clickCount == 2 && inTitleBarBand
            break
        }
        return candidates
    }

    private func pushedWindow(at point: CGPoint) -> AXWindow? {
        guard NSScreen.screens.contains(where: { $0.visibleFrame.axFlipped.contains(point) }) else { return nil }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for info in windows {
            guard ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point) else { continue }
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let application = NSRunningApplication(processIdentifier: pid) else { continue }
            if application.bundleIdentifier == "com.dhrlabs.halfwin" ||
                application.bundleIdentifier == "com.dhrlabs.dockside" { return nil }
            guard application.activationPolicy == .regular else { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            guard let match = pushedWindows.first(where: { $0.value.windowID == id }) else { return nil }
            guard SnapGeometry.isClose(frame.axFlipped, match.value.pushedFrame, tolerance: 8) else {
                pushedWindows.removeValue(forKey: match.key)
                ShowDesktopEvents.didForget(match.key)
                clearDesktopRestoreApplicationIfNeeded()
                reportShowDesktopState()
                return nil
            }
            return match.key
        }
        return nil
    }

    private func isEnabledGreenButton(_ element: AXUIElement, window: AXWindow) -> Bool {
        let enabled: Bool? = axAttribute(kAXEnabledAttribute, of: element)
        guard ["AXFullScreenButton", "AXZoomButton"].contains(AXWindow.subrole(of: element) ?? ""),
              enabled != false, !isFullScreen(window) else { return false }
        return true
    }

    private func isTitleBarHit(_ element: AXUIElement, window: AXWindow, at point: CGPoint) -> Bool {
        guard let role = AXWindow.role(of: element), role == kAXWindowRole || role == "AXToolbar" else { return false }
        let buttonBottoms = [kAXCloseButtonAttribute, kAXZoomButtonAttribute].compactMap { name -> CGFloat? in
            guard let button: AXUIElement = axAttribute(name, of: window.element),
                  let frame = AXWindow(element: button).frame else { return nil }
            return frame.minY
        }
        guard let buttonBottom = buttonBottoms.max() else { return false }
        return point.y >= buttonBottom - 4
    }

    private func axAttribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func swallowMouseDown(_ event: CGEvent) {
        swallowedMouseDownEventNumber = event.getIntegerValueField(.mouseEventNumber)
    }

    private func applyCommandArrow(_ keyCode: Int64) {
        guard let window = AXWindow.focusedWindow(), let frame = window.frame else { return }
        frameMemory.pruneUnreadableFrames()
        let registry = SnapWindowRegistry.shared
        registry.validate()
        let lane = registry.snappedLane(for: window)
        let snapped: (action: SnapAction, screen: NSScreen)?
        if let lane, lane.action == .fill {
            snapped = snappedAction(for: frame) ?? snappedFillSide(for: frame, on: lane.screen)
        } else {
            snapped = lane.map { ($0.action, $0.screen) } ?? snappedAction(for: frame)
        }
        let action: SnapAction
        var rememberFrame = true
        var screen: NSScreen?
        var hopFromScreen: NSScreen?
        switch keyCode {
        case 123:
            if let snapped, snapped.action == .leftHalf {
                guard let adjacent = adjacentScreen(from: snapped.screen, direction: -1) else { return }
                action = .rightHalf
                screen = adjacent
                hopFromScreen = snapped.screen
            } else {
                action = .leftHalf
            }
            rememberFrame = true
        case 124:
            if let snapped, snapped.action == .rightHalf {
                guard let adjacent = adjacentScreen(from: snapped.screen, direction: 1) else { return }
                action = .leftHalf
                screen = adjacent
                hopFromScreen = snapped.screen
            } else {
                action = .rightHalf
            }
            rememberFrame = true
        case 126:
            switch snapped?.action {
            case .leftHalf: action = .topLeftQuarter
            case .rightHalf: action = .topRightQuarter
            case .bottomLeftQuarter: action = .leftHalf
            case .bottomRightQuarter: action = .rightHalf
            default: action = .maximize
            }
            screen = snapped?.screen
            rememberFrame = true
        case 125:
            switch snapped?.action {
            case .leftHalf: action = .bottomLeftQuarter
            case .rightHalf: action = .bottomRightQuarter
            case .topLeftQuarter: action = .leftHalf
            case .topRightQuarter: action = .rightHalf
            case .bottomLeftQuarter, .bottomRightQuarter, .maximize:
                if frameMemory.restore(window, current: frame) {
                    registry.unsnap(window)
                    return
                }
                action = .center
                rememberFrame = false
            default:
                if frameMemory.restore(window, current: frame) {
                    registry.unsnap(window)
                    return
                }
                action = .center
                rememberFrame = false
            }
            screen = snapped?.screen
        default:
            return
        }
        guard let target = targetFrame(action, for: window, current: frame, on: screen) else { return }
        if let hopFromScreen { frameMemory.moveRestoreFrame(window, from: hopFromScreen, to: target.screen) }
        var destination = target.frame
        var effectiveAction = action
        let usesFill = SnapSettings.shared.fillAvailableSpace && [123, 124].contains(keyCode)
        if usesFill {
            let position: SnapPosition = action == .leftHalf ? .left : .right
            let visible = target.screen.visibleFrame
            let point = CGPoint(x: position == .left ? visible.minX : visible.maxX, y: frame.midY)
            if case let .fill(filled) = SnapGeometry.fillFrame(
                at: point, position: position, visibleFrame: visible,
                snappedFrames: registry.fillNeighborFrames(on: target.screen, excluding: window),
                pointIsRequired: false
            ) {
                destination = filled
                effectiveAction = .fill
            }
        }
        if rememberFrame && effectiveAction != .fill {
            frameMemory.set(window, current: frame, to: destination)
        } else {
            window.setFrame(destination)
        }
        if let readBack = window.frame,
           (effectiveAction == .fill
            ? !SnapGeometry.isClose(readBack, frame, tolerance: 1)
            : SnapGeometry.matchesSnapEdges(readBack, target: destination, screenFrame: target.screen.visibleFrame) &&
                SnapGeometry.matchesSnapSize(readBack, target: destination)) {
            if effectiveAction == .fill { frameMemory.remember(window, current: frame) }
            SnapEvents.didSnap(window: window, action: effectiveAction, screen: target.screen, frame: readBack)
        }
    }

    private func snappedFillSide(for frame: CGRect, on screen: NSScreen) -> (action: SnapAction, screen: NSScreen)? {
        let visible = screen.visibleFrame
        let tolerance = SnapGeometry.edgeTolerance
        guard abs(frame.minY - visible.minY) <= tolerance,
              abs(frame.maxY - visible.maxY) <= tolerance else { return nil }
        if abs(frame.minX - visible.minX) <= tolerance && abs(frame.maxX - visible.maxX) > tolerance {
            return (.leftHalf, screen)
        }
        if abs(frame.maxX - visible.maxX) <= tolerance && abs(frame.minX - visible.minX) > tolerance {
            return (.rightHalf, screen)
        }
        return nil
    }

    private func snappedAction(for frame: CGRect) -> (action: SnapAction, screen: NSScreen)? {
        let actions: [SnapAction] = [
            .maximize, .leftHalf, .rightHalf, .topLeftQuarter, .topRightQuarter,
            .bottomLeftQuarter, .bottomRightQuarter,
        ]
        for screen in NSScreen.screens {
            for action in actions {
                guard let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                                      currentWindowFrame: frame,
                                                      portrait: screen.frame.height > screen.frame.width) else { continue }
                if SnapGeometry.matchesSnapEdges(frame, target: target, screenFrame: screen.visibleFrame,
                                                 requireInnerEdges: true) {
                    return (action, screen)
                }
            }
        }
        return nil
    }

    private func adjacentScreen(from screen: NSScreen, direction: CGFloat) -> NSScreen? {
        NSScreen.screens.filter { candidate in
            guard candidate !== screen else { return false }
            let edgeDistance = direction < 0 ? abs(candidate.frame.maxX - screen.frame.minX) :
                abs(candidate.frame.minX - screen.frame.maxX)
            let verticalOverlap = min(candidate.frame.maxY, screen.frame.maxY) - max(candidate.frame.minY, screen.frame.minY)
            return edgeDistance <= 1 && verticalOverlap > 0
        }.max { lhs, rhs in
            let lhsOverlap = min(lhs.frame.maxY, screen.frame.maxY) - max(lhs.frame.minY, screen.frame.minY)
            let rhsOverlap = min(rhs.frame.maxY, screen.frame.maxY) - max(rhs.frame.minY, screen.frame.minY)
            return lhsOverlap < rhsOverlap
        }
    }

    private func toggleDesktop() {
        pruneHiddenApplications()
        prunePushedWindows()
        if isShowingDesktop {
            let application = applicationToReactivate
            restoreHiddenApplications()
            restorePushedWindows()
            if let application, !application.isTerminated { _ = application.activate(options: []) }
            return
        }
        let style = ShowDesktopStyle(rawValue: UserDefaults.standard.string(forKey: ShowDesktopStyle.defaultsKey) ?? "")
            ?? .pushWindowsAside
        switch style {
        case .pushWindowsAside:
            pushWindowsAside()
        case .hideApps:
            hideApplications()
        }
    }

    private func hideApplications() {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated
        }
        guard !applications.isEmpty else { return }
        hiddenApplications = applications
        hiddenApplicationsAt = ProcessInfo.processInfo.systemUptime
        applicationToReactivate = NSWorkspace.shared.frontmostApplication
        for application in applications { application.hide() }
        reportShowDesktopState()
    }

    private func pushWindowsAside() {
        let choices = NSScreen.screens.flatMap { SnapWindowInventory.choices(on: $0, excluding: []) }
        logDiagnostic("showDesktop pushAsideStart choices=\(choices.count) screens=\(NSScreen.screens.count)") // DIAG remove after live capture
        let previousApplication = NSWorkspace.shared.frontmostApplication
        var pushed: [AXWindow: (frame: CGRect, pushedFrame: CGRect, windowID: CGWindowID, application: NSRunningApplication)] = [:]
        for choice in choices {
            let window = choice.window
            guard !choice.application.isHidden, !choice.application.isTerminated,
                  !window.isMinimized, !isFullScreen(window), let frame = window.frame,
                  let screen = NSScreen.screens.first(where: {
                      $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
                  }) ?? NSScreen.main else { continue }
            let visibleFrame = screen.visibleFrame
            let left = CGRect(x: visibleFrame.minX + 12 - frame.width, y: frame.minY,
                              width: frame.width, height: frame.height)
            let right = CGRect(x: visibleFrame.maxX - 12, y: frame.minY,
                               width: frame.width, height: frame.height)
            let bottomX = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
            let bottom = CGRect(x: bottomX, y: visibleFrame.minY + 12 - frame.height,
                                width: frame.width, height: frame.height)
            let preferredSide = frame.midX - visibleFrame.minX <= visibleFrame.maxX - frame.midX
                ? [left, right] : [right, left]
            guard let target = (preferredSide + [bottom]).first(where: { candidate in
                !NSScreen.screens.contains { $0 != screen && $0.frame.intersects(candidate) }
            }), !SnapGeometry.isClose(frame, target) else { continue }

            ShowDesktopEvents.willChangeFrame(of: window, to: target, pushedAside: true)
            window.setFrame(target)
            let (movedFrame, moveError) = AXWindow.frameWithError(of: window.element)
            let moved = moveError == .success && movedFrame.map { SnapGeometry.isClose($0, target, tolerance: 4) } == true // DIAG remove after live capture
            logDiagnostic("showDesktop pushWindow windowID=\(choice.id) pid=\(choice.application.processIdentifier) screen=\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? 0) before=\(frame) requested=\(target) after=\(String(describing: movedFrame)) axError=\(String(describing: moveError)) result=\(moved ? "pushed" : "notPushed")") // DIAG remove after live capture
            if moved, let movedFrame { // DIAG remove after live capture
                pushed[window] = (frame, movedFrame, choice.id, choice.application)
            } else if moveError != .invalidUIElement && moveError != .success {
                pushed[window] = (frame, target, choice.id, choice.application)
            } else {
                ShowDesktopEvents.willChangeFrame(of: window, to: frame, pushedAside: false)
                if let movedFrame, !SnapGeometry.isClose(movedFrame, frame) { window.setFrame(frame) }
                continue
            }
        }
        pushedWindows = pushed
        applicationToReactivate = pushed.isEmpty ? nil : previousApplication
        reportShowDesktopState()
    }

    private func restorePushedWindow(_ window: AXWindow) {
        prunePushedWindows()
        guard let pushed = pushedWindows[window], restorePushedWindow(window, to: pushed) else { return }
        window.restoreAndRaise(in: pushed.application)
        clearDesktopRestoreApplicationIfNeeded()
    }

    @discardableResult
    func restorePushedWindows(for application: NSRunningApplication) -> Bool {
        prunePushedWindows()
        let windows = pushedWindows.filter { $0.value.application.processIdentifier == application.processIdentifier }
        guard !windows.isEmpty else { return false }
        let focusedWindow = AXWindow.focusedWindow(of: application)
        for (window, pushed) in windows {
            _ = restorePushedWindow(window, to: pushed)
        }
        focusedWindow?.restoreAndRaise(in: application)
        clearDesktopRestoreApplicationIfNeeded()
        return true
    }

    @discardableResult
    private func restorePushedWindow(_ window: AXWindow, to pushed: (frame: CGRect, pushedFrame: CGRect, windowID: CGWindowID, application: NSRunningApplication)) -> Bool {
        guard !pushed.application.isTerminated else {
            logDiagnostic("showDesktop restore windowID=\(pushed.windowID) pid=\(pushed.application.processIdentifier) result=terminated axError=notQueried") // DIAG remove after live capture
            pushedWindows.removeValue(forKey: window)
            ShowDesktopEvents.didForget(window)
            clearDesktopRestoreApplicationIfNeeded()
            reportShowDesktopState()
            return false
        }
        let (currentFrame, currentError) = AXWindow.frameWithError(of: window.element)
        if currentError == .invalidUIElement {
            logDiagnostic("showDesktop restore windowID=\(pushed.windowID) pid=\(pushed.application.processIdentifier) result=invalidElement before=\(String(describing: currentFrame)) requested=\(pushed.frame) after=nil axError=\(String(describing: currentError))") // DIAG remove after live capture
            pushedWindows.removeValue(forKey: window)
            ShowDesktopEvents.didForget(window)
            clearDesktopRestoreApplicationIfNeeded()
            reportShowDesktopState()
            return false
        }
        if currentError == .success, let currentFrame,
           !SnapGeometry.isClose(currentFrame, pushed.pushedFrame, tolerance: 8) {
            logDiagnostic("showDesktop restore windowID=\(pushed.windowID) pid=\(pushed.application.processIdentifier) result=movedExternally before=\(currentFrame) requested=\(pushed.frame) after=\(currentFrame) axError=\(String(describing: currentError))") // DIAG remove after live capture
            pushedWindows.removeValue(forKey: window)
            ShowDesktopEvents.didForget(window)
            clearDesktopRestoreApplicationIfNeeded()
            reportShowDesktopState()
            return false
        }
        let target = frameOnConnectedScreen(pushed.frame)
        ShowDesktopEvents.willChangeFrame(of: window, to: target, pushedAside: false)
        window.setFrame(target)
        let (restoredFrame, restoreError) = AXWindow.frameWithError(of: window.element)
        let restored = restoreError == .success && restoredFrame.map { SnapGeometry.isClose($0, target, tolerance: 8) } == true // DIAG remove after live capture
        logDiagnostic("showDesktop restore windowID=\(pushed.windowID) pid=\(pushed.application.processIdentifier) before=\(String(describing: currentFrame)) requested=\(target) after=\(String(describing: restoredFrame)) axError=\(String(describing: restoreError)) currentAXError=\(String(describing: currentError)) result=\(restored ? "restored" : "failed")") // DIAG remove after live capture
        guard restored else { // DIAG remove after live capture
            if restoreError == .invalidUIElement {
                pushedWindows.removeValue(forKey: window)
                ShowDesktopEvents.didForget(window)
                clearDesktopRestoreApplicationIfNeeded()
                reportShowDesktopState()
            } else {
                ShowDesktopEvents.willChangeFrame(of: window, to: pushed.pushedFrame, pushedAside: true)
            }
            return false
        }
        pushedWindows.removeValue(forKey: window)
        reportShowDesktopState()
        return true
    }

    private func logDiagnostic(_ message: String) { // DIAG remove after live capture
        diagLogger.notice("HWDIAG \(message, privacy: .public)") // DIAG remove after live capture
    }

    private func restorePushedWindows() {
        prunePushedWindows()
        for (window, pushed) in Array(pushedWindows) {
            _ = restorePushedWindow(window, to: pushed)
        }
        if pushedWindows.isEmpty, hiddenApplications == nil { applicationToReactivate = nil }
        reportShowDesktopState()
    }

    private func prunePushedWindows() {
        let invalid = pushedWindows.keys.filter { window in
            guard let application = pushedWindows[window]?.application else { return true }
            return application.isTerminated || AXWindow.frameWithError(of: window.element).error == .invalidUIElement
        }
        for window in invalid {
            pushedWindows.removeValue(forKey: window)
            ShowDesktopEvents.didForget(window)
        }
        clearDesktopRestoreApplicationIfNeeded()
        reportShowDesktopState()
    }

    private func frameOnConnectedScreen(_ frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screens = NSScreen.screens
        guard !screens.isEmpty,
              !screens.contains(where: { $0.frame.contains(center) }),
              let screen = screens.min(by: {
                  distance(from: center, to: $0.visibleFrame) < distance(from: center, to: $1.visibleFrame)
              }) else { return frame }
        let bounds = screen.visibleFrame
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
        let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
        return dx * dx + dy * dy
    }

    private func clearDesktopRestoreApplicationIfNeeded() {
        if hiddenApplications == nil && pushedWindows.isEmpty { applicationToReactivate = nil }
    }

    private func isFullScreen(_ window: AXWindow) -> Bool {
        let fullScreen: Bool? = axAttribute("AXFullScreen", of: window.element)
        return fullScreen == true
    }

    private func restoreHiddenApplications() {
        guard let applications = hiddenApplications else { return }
        hiddenApplications = nil
        hiddenApplicationsAt = nil
        for application in applications where !application.isTerminated { application.unhide() }
        if pushedWindows.isEmpty { applicationToReactivate = nil }
        reportShowDesktopState()
    }

    private func pruneHiddenApplications() {
        guard let applications = hiddenApplications else { return }
        let remaining = applications.filter { !$0.isTerminated }
        hiddenApplications = remaining.isEmpty ? nil : remaining
        if hiddenApplications == nil { hiddenApplicationsAt = nil }
        clearDesktopRestoreApplicationIfNeeded()
        reportShowDesktopState()
    }

    private func reportShowDesktopState() {
        let state = isShowingDesktop
        guard state != lastReportedDesktopState else { return }
        lastReportedDesktopState = state
        onShowDesktopStateChange?(state)
    }

    private func toggleToVisibleFrame(_ window: AXWindow, current: CGRect) -> Bool {
        frameMemory.pruneUnreadableFrames()
        guard let target = targetFrame(.maximize, for: window, current: current) else { return false }
        SnapWindowRegistry.shared.unsnap(window)
        frameMemory.toggle(window, current: current, to: target.frame)
        return true
    }

    private func targetFrame(_ action: SnapAction, for window: AXWindow, current: CGRect,
                             on requestedScreen: NSScreen? = nil) -> (frame: CGRect, screen: NSScreen)? {
        let center = CGPoint(x: current.midX, y: current.midY)
        guard let screen = requestedScreen ?? NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return nil }
        guard let frame = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                             currentWindowFrame: current, portrait: screen.frame.height > screen.frame.width) else { return nil }
        return (frame, screen)
    }
}

private final class WindowFrameMemory {
    private var originalFrames: [AXWindow: CGRect] = [:]

    func toggle(_ window: AXWindow, current: CGRect, to target: CGRect) {
        if let original = originalFrames[window], isClose(current, target) {
            originalFrames.removeValue(forKey: window)
            window.setFrame(original)
        } else {
            if originalFrames[window] == nil { originalFrames[window] = current }
            window.setFrame(target)
        }
    }

    func set(_ window: AXWindow, current: CGRect, to target: CGRect) {
        if originalFrames[window] == nil { originalFrames[window] = current }
        window.setFrame(target)
    }

    func remember(_ window: AXWindow, current: CGRect) {
        if originalFrames[window] == nil { originalFrames[window] = current }
    }

    func moveRestoreFrame(_ window: AXWindow, from source: NSScreen, to destination: NSScreen) {
        guard let original = originalFrames[window] else { return }
        let sourceBounds = source.visibleFrame
        let bounds = destination.visibleFrame
        let width = min(original.width, bounds.width)
        let height = min(original.height, bounds.height)
        let x = bounds.minX + original.minX - sourceBounds.minX
        let y = bounds.minY + original.minY - sourceBounds.minY
        originalFrames[window] = CGRect(x: min(max(x, bounds.minX), bounds.maxX - width),
                                        y: min(max(y, bounds.minY), bounds.maxY - height),
                                        width: width, height: height)
    }

    func restore(_ window: AXWindow, current: CGRect) -> Bool {
        guard let original = originalFrames.removeValue(forKey: window) else { return false }
        if !isClose(current, original) { window.setFrame(original) }
        return true
    }

    func removeAll() { originalFrames.removeAll() }

    func pruneUnreadableFrames() {
        let unreadable = originalFrames.keys.filter { $0.frame == nil }
        for window in unreadable { originalFrames.removeValue(forKey: window) }
    }

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
            abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}

private func windowExtrasEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<WindowExtrasManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleTap(type: type, event: event)
}
