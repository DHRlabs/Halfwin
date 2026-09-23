import AppKit
import ApplicationServices
import CoreGraphics

/// Adds the small system-wide window actions that do not belong to drag snapping.
final class WindowExtrasManager {
    private static let eventMask: CGEventMask = [
        CGEventType.leftMouseDown, .leftMouseUp, .keyDown
    ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

    private var greenButtonEnabled = false
    private var titleBarDoubleClickEnabled = false
    private var showDesktopEnabled = false
    private var commandArrowEnabled = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var swallowNextMouseUp = false
    private var hiddenApplications: [NSRunningApplication]?
    private let frameMemory = WindowFrameMemory()

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.applicationDidActivate(notification)
        }
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
        if !enabled { restoreHiddenApplications() }
        refreshPermission()
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
        guard Permissions.accessibilityGranted else {
            stopTap()
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.refreshPermission()
                }
            }
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        startTap()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopTap()
        restoreHiddenApplications()
        frameMemory.removeAll()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard Permissions.accessibilityGranted else {
            refreshPermission()
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            let point = event.location.axFlipped
            if showDesktopEnabled, isDesktopCorner(point) {
                toggleDesktop()
                swallowNextMouseUp = true
                return nil
            }
            guard greenButtonEnabled || titleBarDoubleClickEnabled,
                  let hit = AXWindow.hitTest(at: point) else { return Unmanaged.passUnretained(event) }
            if greenButtonEnabled, !event.flags.contains(.maskAlternate),
               ["AXFullScreenButton", "AXZoomButton"].contains(AXWindow.subrole(of: hit.element) ?? ""),
               let current = hit.window.frame, toggleToVisibleFrame(hit.window, current: current) {
                swallowNextMouseUp = true
                return nil
            }
            if titleBarDoubleClickEnabled,
               event.getIntegerValueField(.mouseEventClickState) == 2,
               let current = hit.window.frame,
               isTitleBarHit(hit.element, windowFrame: current, at: point),
               toggleToVisibleFrame(hit.window, current: current) {
                swallowNextMouseUp = true
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseUp:
            guard swallowNextMouseUp else { return Unmanaged.passUnretained(event) }
            swallowNextMouseUp = false
            return nil
        case .keyDown:
            guard commandArrowEnabled, isExactCommand(event.flags),
                  let window = AXWindow.focusedWindow(), let frame = window.frame else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let action: SnapAction
            let rememberFrame: Bool
            switch keyCode {
            case 123: action = .leftHalf; rememberFrame = true
            case 124: action = .rightHalf; rememberFrame = true
            case 126: action = .maximize; rememberFrame = true
            case 125:
                if frameMemory.restore(window, current: frame) { return nil }
                action = .center
                rememberFrame = false
            default:
                return Unmanaged.passUnretained(event)
            }
            guard let target = targetFrame(action, for: window, current: frame) else {
                return Unmanaged.passUnretained(event)
            }
            if rememberFrame {
                frameMemory.set(window, current: frame, to: target)
            } else {
                window.setFrame(target)
            }
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
        swallowNextMouseUp = false
    }

    private func isExactCommand(_ flags: CGEventFlags) -> Bool {
        let modifiers: CGEventFlags = [
            .maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskHelp, .maskSecondaryFn
        ]
        return flags.intersection(modifiers) == .maskCommand
    }

    private func isDesktopCorner(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.maxX - point.x >= 0 && screen.frame.maxX - point.x <= 3 &&
                point.y - screen.frame.minY >= 0 && point.y - screen.frame.minY <= 3
        }
    }

    private func toggleDesktop() {
        if let applications = hiddenApplications {
            hiddenApplications = nil
            for application in applications where !application.isTerminated { application.unhide() }
            return
        }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated
        }
        hiddenApplications = applications
        for application in applications { application.hide() }
    }

    private func restoreHiddenApplications() {
        guard let applications = hiddenApplications else { return }
        hiddenApplications = nil
        for application in applications where !application.isTerminated { application.unhide() }
    }

    private func applicationDidActivate(_ notification: Notification) {
        guard hiddenApplications != nil else { return }
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            hiddenApplications = nil
            return
        }
        // Hiding the frontmost app can activate another app in the saved set.
        // Check after the hide batch so only an app the user brought back clears it.
        DispatchQueue.main.async { [weak self, weak application] in
            guard let self, let applications = self.hiddenApplications,
                  let application else { return }
            if !applications.contains(where: { $0.processIdentifier == application.processIdentifier }) || !application.isHidden {
                self.hiddenApplications = nil
            }
        }
    }

    private func isTitleBarHit(_ element: AXUIElement, windowFrame: CGRect, at point: CGPoint) -> Bool {
        guard windowFrame.contains(point), windowFrame.maxY - point.y <= 28,
              let role = AXWindow.role(of: element) else { return false }
        guard !["AXButton", "AXTextField", "AXToolbar"].contains(role) else { return false }
        return role == "AXWindow" || role == "AXTitleBar" || role == "AXTitle" ||
            AXWindow.subrole(of: element) == "AXTitle"
    }

    private func toggleToVisibleFrame(_ window: AXWindow, current: CGRect) -> Bool {
        guard let target = targetFrame(.maximize, for: window, current: current) else { return false }
        frameMemory.toggle(window, current: current, to: target)
        return true
    }

    private func targetFrame(_ action: SnapAction, for window: AXWindow, current: CGRect) -> CGRect? {
        let center = CGPoint(x: current.midX, y: current.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return nil }
        return SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                  currentWindowFrame: current, portrait: screen.frame.height > screen.frame.width)
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

    func restore(_ window: AXWindow, current: CGRect) -> Bool {
        guard let original = originalFrames.removeValue(forKey: window) else { return false }
        if !isClose(current, original) { window.setFrame(original) }
        return true
    }

    func removeAll() { originalFrames.removeAll() }

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
