import AppKit

final class SnapGroupsManager {
    private enum Side: Hashable { case left, right }
    private struct Member {
        let window: AXWindow
        let frame: CGRect
    }
    private struct Display: Hashable {
        let number: UInt32
        let frame: CGRect

        init(_ screen: NSScreen) {
            number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            frame = screen.frame
        }

        var screen: NSScreen? {
            NSScreen.screens.first { Display($0) == self }
        }
    }

    private var enabled = false
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var members: [Display: [Side: Member]] = [:]
    private var ignoredActivations: [pid_t: TimeInterval] = [:]

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refreshPermission()
    }

    func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen) {
        guard enabled, Permissions.accessibilityGranted,
              let side = side(for: action), let current = window.frame,
              let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                              currentWindowFrame: current,
                                              portrait: screen.frame.height > screen.frame.width),
              SnapGeometry.isClose(current, target, tolerance: 8) else { return }
        let display = Display(screen)
        var pair = members[display] ?? [:]
        if pair.values.contains(where: { member in
            guard let frame = member.window.frame else { return true }
            return !SnapGeometry.isClose(frame, member.frame)
        }) { pair = [:] }
        pair[side] = Member(window: window, frame: current)
        members[display] = pair
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        members.removeAll()
        ignoredActivations.removeAll()
    }

    deinit { stop() }

    func refreshPermission() {
        guard enabled else {
            stop()
            return
        }
        guard Permissions.accessibilityGranted else {
            removeActivationObservers()
            members.removeAll()
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.refreshPermission()
                }
            }
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activatedApplication(notification)
            }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in self?.terminatedApplication(notification) }
    }

    private func removeActivationObservers() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    private func activatedApplication(_ notification: Notification) {
        guard enabled, Permissions.accessibilityGranted,
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let now = ProcessInfo.processInfo.systemUptime
        ignoredActivations = ignoredActivations.filter { $0.value > now }
        guard ignoredActivations[app.processIdentifier] == nil,
              app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        pruneGroups()
        guard let focused = AXWindow.focusedWindow(of: app),
              let group = members.first(where: { $0.value.values.contains { $0.window == focused } }),
              group.value.count == 2 else { return }
        let ignoreUntil = now + 0.3
        for member in group.value.values where member.window != focused {
            guard let screen = group.key.screen,
                  SnapWindowInventory.isOnCurrentSpace(member.window, on: screen) else { continue }
            if let processIdentifier = member.window.processIdentifier {
                ignoredActivations[processIdentifier] = ignoreUntil
            }
            member.window.raise()
        }
        if let processIdentifier = focused.processIdentifier {
            ignoredActivations[processIdentifier] = ignoreUntil
        }
        focused.raise()
    }

    private func terminatedApplication(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for display in Array(members.keys) where members[display]?.values.contains(where: { $0.window.processIdentifier == app.processIdentifier }) == true {
            members.removeValue(forKey: display)
        }
    }

    private func pruneGroups() {
        for display in Array(members.keys) {
            guard let pair = members[display], display.screen != nil else {
                members.removeValue(forKey: display)
                continue
            }
            guard pair.values.allSatisfy({ member in
                guard let frame = member.window.frame else { return false }
                return SnapGeometry.isClose(frame, member.frame)
            }) else {
                members.removeValue(forKey: display)
                continue
            }
        }
    }

    private func side(for action: SnapAction) -> Side? {
        switch action {
        case .leftHalf: return .left
        case .rightHalf: return .right
        default: return nil
        }
    }
}
