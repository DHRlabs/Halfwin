import AppKit
import ApplicationServices
import CoreGraphics

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
    private var activationObserver: NSObjectProtocol?
    private var swallowedMouseDownEventNumber: Int64?
    private var swallowedCommandArrowKeyCodes = Set<Int64>()
    private var hiddenApplications: [NSRunningApplication]?
    private var applicationToReactivate: NSRunningApplication?
    private var ignoreActivationsUntil: TimeInterval = 0
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
        frameMemory.removeAll()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
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
            let point = event.location.axFlipped
            if showDesktopEnabled, isDesktopCorner(point) {
                swallowMouseDown(event)
                DispatchQueue.main.async { [weak self] in self?.toggleDesktop() }
                return nil
            }
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
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return (false, false)
        }
        var candidates = (greenButton: false, titleBar: false)
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(quartzPoint), quartzPoint.y <= frame.minY + 40 else { continue }
            candidates.greenButton = candidates.greenButton ||
                (greenButtonEnabled && quartzPoint.x <= frame.minX + 80)
            candidates.titleBar = candidates.titleBar || (titleBarDoubleClickEnabled && clickCount == 2)
            if candidates.greenButton && candidates.titleBar { break }
        }
        return candidates
    }

    private func isEnabledGreenButton(_ element: AXUIElement, window: AXWindow) -> Bool {
        let enabled: Bool? = axAttribute(kAXEnabledAttribute, of: element)
        let fullScreen: Bool? = axAttribute("AXFullScreen", of: window.element)
        guard ["AXFullScreenButton", "AXZoomButton"].contains(AXWindow.subrole(of: element) ?? ""),
              enabled != false, fullScreen != true else { return false }
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
        let action: SnapAction
        let rememberFrame: Bool
        switch keyCode {
        case 123: action = .leftHalf; rememberFrame = true
        case 124: action = .rightHalf; rememberFrame = true
        case 126: action = .maximize; rememberFrame = true
        case 125:
            if frameMemory.restore(window, current: frame) { return }
            action = .center
            rememberFrame = false
        default:
            return
        }
        guard let target = targetFrame(action, for: window, current: frame) else { return }
        if rememberFrame {
            frameMemory.set(window, current: frame, to: target.frame)
        } else {
            window.setFrame(target.frame)
        }
        if action == .leftHalf || action == .rightHalf,
           let readBack = window.frame, SnapGeometry.isClose(readBack, target.frame) {
            SnapEvents.didSnap(window: window, action: action, screen: target.screen)
        }
    }

    private func isDesktopCorner(_ point: CGPoint) -> Bool {
        let screens = NSScreen.screens
        return screens.contains { screen in
            let frame = screen.frame
            guard frame.maxX - point.x >= 0, frame.maxX - point.x <= 3,
                  point.y - frame.minY >= 0, point.y - frame.minY <= 3 else { return false }
            return !screens.contains { other in
                other !== screen && (other.frame.contains(CGPoint(x: frame.maxX + 1, y: point.y)) ||
                    other.frame.contains(CGPoint(x: point.x, y: frame.minY - 1)))
            }
        }
    }

    private func toggleDesktop() {
        if let applications = hiddenApplications {
            hiddenApplications = nil
            for application in applications where !application.isTerminated { application.unhide() }
            _ = applicationToReactivate?.activate(options: [])
            applicationToReactivate = nil
            return
        }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated
        }
        hiddenApplications = applications
        applicationToReactivate = NSWorkspace.shared.frontmostApplication
        ignoreActivationsUntil = ProcessInfo.processInfo.systemUptime + 1
        for application in applications { application.hide() }
        ignoreActivationsUntil = ProcessInfo.processInfo.systemUptime + 1
    }

    private func restoreHiddenApplications() {
        guard let applications = hiddenApplications else { return }
        hiddenApplications = nil
        applicationToReactivate = nil
        for application in applications where !application.isTerminated { application.unhide() }
    }

    private func applicationDidActivate(_ notification: Notification) {
        guard hiddenApplications != nil,
              ProcessInfo.processInfo.systemUptime >= ignoreActivationsUntil else { return }
        hiddenApplications = nil
        applicationToReactivate = nil
    }

    private func toggleToVisibleFrame(_ window: AXWindow, current: CGRect) -> Bool {
        frameMemory.pruneUnreadableFrames()
        guard let target = targetFrame(.maximize, for: window, current: current) else { return false }
        frameMemory.toggle(window, current: current, to: target.frame)
        return true
    }

    private func targetFrame(_ action: SnapAction, for window: AXWindow, current: CGRect) -> (frame: CGRect, screen: NSScreen)? {
        let center = CGPoint(x: current.midX, y: current.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return nil }
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
