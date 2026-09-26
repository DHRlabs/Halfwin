import AppKit

final class SnapGroupsManager {
    private enum Side: Hashable { case left, right }

    private var enabled = false
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var members: [SnapDisplayID: [Side: AXWindow]] = [:]
    private var ignoredActivations: [pid_t: TimeInterval] = [:]

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refreshPermission()
    }

    func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen) {
        guard enabled, Permissions.accessibilityGranted,
              let side = side(for: action),
              let lane = SnapWindowRegistry.shared.snappedLane(for: window),
              lane.display == SnapDisplayID(screen) else { return }
        pruneGroups()
        members[lane.display, default: [:]][side] = window
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        removeActivationObservers()
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
            DispatchQueue.main.async { self?.activatedApplication(notification) }
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
        SnapWindowRegistry.shared.validate()
        let now = ProcessInfo.processInfo.systemUptime
        ignoredActivations = ignoredActivations.filter { $0.value > now }
        guard ignoredActivations[app.processIdentifier] == nil,
              app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        pruneGroups()
        guard let focused = AXWindow.focusedWindow(of: app),
              let group = members.first(where: { $0.value.values.contains(focused) }),
              group.value.count == 2 else { return }
        let ignoreUntil = now + 0.3
        for window in group.value.values where window != focused {
            guard SnapWindowRegistry.shared.snappedLane(for: window) != nil else { continue }
            if let processIdentifier = window.processIdentifier { ignoredActivations[processIdentifier] = ignoreUntil }
            window.raise()
        }
        if let processIdentifier = focused.processIdentifier { ignoredActivations[processIdentifier] = ignoreUntil }
        focused.raise()
    }

    private func terminatedApplication(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for display in Array(members.keys) where members[display]?.values.contains(where: {
            $0.processIdentifier == app.processIdentifier
        }) == true {
            members.removeValue(forKey: display)
        }
    }

    private func pruneGroups() {
        let registry = SnapWindowRegistry.shared
        for display in Array(members.keys) {
            guard display.screen != nil, let pair = members[display] else {
                members.removeValue(forKey: display)
                continue
            }
            let valid = pair.filter { side, window in
                guard let lane = registry.snappedLane(for: window), lane.display == display else { return false }
                return self.side(for: lane.action) == side
            }
            if valid.isEmpty { members.removeValue(forKey: display) }
            else { members[display] = valid }
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
