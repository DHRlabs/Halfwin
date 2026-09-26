import AppKit
import ApplicationServices
import Combine

struct NotificationBadgeApp: Identifiable, Equatable {
    let id: String
    let name: String
    var count: Int
}

final class NotificationCountManager: ObservableObject {
    @Published private(set) var apps: [NotificationBadgeApp] = []
    @Published private(set) var total = 0
    @Published private(set) var isEnabled = false
    @Published private(set) var hasAccessibility = Permissions.accessibilityGranted

    private let excludedAppsKey = "Halfwin.notifications.excludedApps"
    private let badgeAttribute = "AXStatusLabel"
    private let dockNotifications = [
        kAXCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXLayoutChangedNotification as String
    ]
    private var excludedApps = Set(UserDefaults.standard.stringArray(forKey: "Halfwin.notifications.excludedApps") ?? [])
    private var screenAsleep = false
    private var timer: Timer?
    private var dockPID: pid_t?
    private var observer: AXObserver?
    private var observedList: AXUIElement?
    private var observerSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?

    var isCounting: Bool { isEnabled && hasAccessibility && !screenAsleep }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        reconcile()
    }

    func refreshPermission() {
        let granted = Permissions.accessibilityGranted
        guard hasAccessibility != granted else { return }
        hasAccessibility = granted
        reconcile()
    }

    func isIncluded(_ appID: String) -> Bool { !excludedApps.contains(appID) }

    func setIncluded(_ included: Bool, for appID: String) {
        if included { excludedApps.remove(appID) } else { excludedApps.insert(appID) }
        UserDefaults.standard.set(Array(excludedApps), forKey: excludedAppsKey)
        updateTotal()
    }

    private func reconcile() {
        guard isEnabled, hasAccessibility else {
            stopMonitoring()
            stopWatchingScreen()
            updateApps([])
            onChange?()
            return
        }
        watchScreen()
        guard !screenAsleep else {
            stopMonitoring()
            onChange?()
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                self?.pollDock()
            }
        }
        attachDockObserver()
        refreshBadges()
        onChange?()
    }

    private func watchScreen() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screenAsleep = true
                self?.stopMonitoring()
                self?.onChange?()
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screenAsleep = false
                self?.reconcile()
            }
        ]
    }

    private func stopWatchingScreen() {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        stopDockObserver()
    }

    private func pollDock() {
        guard isCounting else { return }
        if !Permissions.accessibilityGranted {
            refreshPermission()
            return
        }
        let currentPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated })?.processIdentifier
        if currentPID != dockPID || observer == nil { attachDockObserver() }
        refreshBadges()
    }

    private func attachDockObserver() {
        guard isCounting else { return }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated }) else {
            stopDockObserver()
            dockPID = nil
            return
        }
        guard observer == nil || dockPID != dock.processIdentifier else { return }
        stopDockObserver()
        dockPID = dock.processIdentifier
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let children: [AXUIElement] = attribute(application, kAXChildrenAttribute),
              let list = children.first(where: { role(of: $0) == kAXListRole as String }) else { return }

        var createdObserver: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, notificationDockChanged, &createdObserver) == .success,
              let createdObserver else { return }
        var registered: [String] = []
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in dockNotifications where AXObserverAddNotification(createdObserver, list, name as CFString, context) == .success {
            registered.append(name)
        }
        guard !registered.isEmpty else { return }
        observer = createdObserver
        observedList = list
        observerSource = AXObserverGetRunLoopSource(createdObserver)
        if let observerSource { CFRunLoopAddSource(CFRunLoopGetMain(), observerSource, .commonModes) }
    }

    private func stopDockObserver() {
        if let observer, let observedList {
            for name in dockNotifications { AXObserverRemoveNotification(observer, observedList, name as CFString) }
        }
        if let observerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), observerSource, .commonModes) }
        observer = nil
        observedList = nil
        observerSource = nil
    }

    fileprivate func dockChanged(_ notification: String) {
        guard isCounting else { return }
        if notification == kAXUIElementDestroyedNotification as String {
            stopDockObserver()
            attachDockObserver()
        }
        refreshBadges()
    }

    private func refreshBadges() {
        guard isCounting, let observedList,
              let items: [AXUIElement] = attribute(observedList, kAXChildrenAttribute) else {
            updateApps([])
            return
        }
        var found: [String: NotificationBadgeApp] = [:]
        for item in items {
            let subrole: String? = attribute(item, kAXSubroleAttribute)
            guard subrole == kAXApplicationDockItemSubrole as String,
                  let badge: String = attribute(item, badgeAttribute),
                  !badge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let url = appURL(of: item)
            let bundle = url.flatMap(Bundle.init(url:))
            let title: String? = attribute(item, kAXTitleAttribute)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? title
                ?? url?.deletingPathExtension().lastPathComponent
            guard let name, !name.isEmpty else { continue }
            let id = bundle?.bundleIdentifier ?? url?.standardizedFileURL.path ?? name
            let count = Self.badgeCount(badge)
            if var app = found[id] {
                app.count = Self.add(app.count, count)
                found[id] = app
            } else {
                found[id] = NotificationBadgeApp(id: id, name: name, count: count)
            }
        }
        updateApps(found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private func updateApps(_ newApps: [NotificationBadgeApp]) {
        if apps != newApps { apps = newApps }
        updateTotal()
    }

    private func updateTotal() {
        let newTotal = apps.filter { isIncluded($0.id) }.reduce(0) { Self.add($0, $1.count) }
        guard total != newTotal else { return }
        total = newTotal
        onChange?()
    }

    private static func badgeCount(_ text: String) -> Int {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0.isNumber || $0 == "," }
            .filter { $0 != "," }
        return digits.isEmpty ? 1 : Int(String(digits)) ?? Int.max
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    private func appURL(of item: AXUIElement) -> URL? {
        if let url: URL = attribute(item, kAXURLAttribute) { return url }
        if let value: String = attribute(item, kAXURLAttribute) {
            return URL(string: value) ?? URL(fileURLWithPath: value)
        }
        return nil
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

private let notificationDockChanged: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    Unmanaged<NotificationCountManager>.fromOpaque(refcon).takeUnretainedValue().dockChanged(notification as String)
}
