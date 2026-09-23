import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private let snapSettings = SnapSettings.shared
    private lazy var snapManager = SnapManager(settings: snapSettings)
    private let snapAssistManager = SnapAssistManager()
    private let snapGroupsManager = SnapGroupsManager()
    private let snapAssistSwitch = FeatureSwitch(key: "snapAssist", title: "Snap Assist", defaultOn: true)
    private let snapGroupsSwitch = FeatureSwitch(key: "snapGroups", title: "Snap Groups", defaultOn: true)
    private let layoutMenuSettings = LayoutMenuSettings.shared
    private lazy var layoutMenuManager = LayoutMenuManager(settings: layoutMenuSettings)
    private lazy var settingsWindowController = SettingsWindowController(settings: snapSettings, layoutMenuSettings: layoutMenuSettings)
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var awakeItem: NSMenuItem!
    private var durationItems: [NSMenuItem] = []
    private var lidItem: NSMenuItem!
    private var lidDurationItems: [NSMenuItem] = []
    private var loginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var screenRecordingItem: NSMenuItem!
    private var activationRefreshObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activationRefreshObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.snapAssistManager.refreshPermission()
            self?.snapGroupsManager.refreshPermission()
        }
        SnapEvents.handler = { [weak self] window, action, screen in
            self?.snapAssistManager.didSnap(window: window, action: action, screen: screen)
            self?.snapGroupsManager.didSnap(window: window, action: action, screen: screen)
        }
        snapAssistSwitch.onChange = { [weak self] in self?.snapAssistManager.setEnabled($0) }
        snapGroupsSwitch.onChange = { [weak self] in self?.snapGroupsManager.setEnabled($0) }
        snapAssistSwitch.start()
        snapGroupsSwitch.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        keepAwake.onChange = { [weak self] in self?.updateUI() }
        keepAwake.refresh()
        snapManager.refreshPermission()
        layoutMenuManager.refreshPermission()
        updateUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationRefreshObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationRefreshObserver)
            self.activationRefreshObserver = nil
        }
        keepAwake.stop()
        snapGroupsManager.stop()
        snapAssistManager.setEnabled(false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        keepAwake.refresh()
        snapManager.refreshPermission()
        layoutMenuManager.refreshPermission()
        snapAssistManager.refreshPermission()
        snapGroupsManager.refreshPermission()
    }

    private func buildMenu() {
        statusLine = NSMenuItem(title: "Off — Mac can sleep", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        awakeItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleAwake), keyEquivalent: "")
        awakeItem.target = self
        menu.addItem(awakeItem)

        let durationParent = NSMenuItem(title: "Keep Awake For…", action: nil, keyEquivalent: "")
        durationParent.submenu = makeDurations(#selector(startTimed(_:)), store: &durationItems)
        menu.addItem(durationParent)

        lidItem = NSMenuItem(title: "Keep Awake With Lid Closed", action: #selector(toggleLid), keyEquivalent: "")
        lidItem.target = self
        menu.addItem(lidItem)

        let lidDurationParent = NSMenuItem(title: "Keep Awake With Lid Closed For…", action: nil, keyEquivalent: "")
        lidDurationParent.submenu = makeDurations(#selector(startLidTimed(_:)), store: &lidDurationItems)
        menu.addItem(lidDurationParent)

        menu.addItem(.separator())

        let snappingHeader = NSMenuItem(title: "Snapping", action: nil, keyEquivalent: "")
        snappingHeader.isEnabled = false
        menu.addItem(snappingHeader)
        menu.addItem(snapAssistSwitch.makeMenuItem())
        menu.addItem(snapGroupsSwitch.makeMenuItem())
        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let permissionsMenu = NSMenu()
        accessibilityItem = NSMenuItem(title: "Accessibility: Not Granted", action: #selector(requestAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        permissionsMenu.addItem(accessibilityItem)
        screenRecordingItem = NSMenuItem(title: "Screen Recording: Not Granted", action: #selector(requestScreenRecording), keyEquivalent: "")
        screenRecordingItem.target = self
        permissionsMenu.addItem(screenRecordingItem)
        permissionsItem.submenu = permissionsMenu
        menu.addItem(permissionsItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Halfwin", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makeDurations(_ action: Selector, store: inout [NSMenuItem]) -> NSMenu {
        let submenu = NSMenu()
        for (label, seconds) in KeepAwake.durations {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            item.tag = seconds
            submenu.addItem(item)
            store.append(item)
        }
        return submenu
    }

    @objc private func toggleAwake() { keepAwake.toggle() }
    @objc private func startTimed(_ sender: NSMenuItem) { keepAwake.startTimed(sender.tag) }
    @objc private func toggleLid() { keepAwake.toggleLid() }
    @objc private func startLidTimed(_ sender: NSMenuItem) { keepAwake.startLidTimed(sender.tag) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Halfwin: launch-at-login change failed: \(error)")
        }
        updateUI()
    }

    @objc private func requestAccessibility() {
        Permissions.requestAccessibility()
        updateUI()
    }

    @objc private func requestScreenRecording() {
        Permissions.requestScreenRecording()
        updateUI()
    }

    @objc private func openSettings() { settingsWindowController.show() }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func updateUI() {
        statusLine.title = keepAwake.statusTitle
        if let image = NSImage(
            systemSymbolName: keepAwake.isAwake ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
            accessibilityDescription: "Halfwin"
        ) {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.title = "hfWn"
        statusItem.button?.imagePosition = .imageLeft

        awakeItem.state = keepAwake.isPlainAwake ? .on : .off
        awakeItem.title = keepAwake.isPlainAwake ? "Stop Keeping Awake" : "Keep Awake"
        for item in durationItems {
            item.state = keepAwake.activeDuration == item.tag ? .on : .off
        }
        lidItem.state = keepAwake.isLidAwakeIndefinitely ? .on : .off
        for item in lidDurationItems {
            item.state = keepAwake.activeLidDuration == item.tag ? .on : .off
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessibilityItem.title = "Accessibility: \(Permissions.accessibilityGranted ? "Granted" : "Not Granted")"
        accessibilityItem.isEnabled = !Permissions.accessibilityGranted
        screenRecordingItem.title = "Screen Recording: \(Permissions.screenRecordingGranted ? "Granted" : "Not Granted")"
        screenRecordingItem.isEnabled = !Permissions.screenRecordingGranted
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
