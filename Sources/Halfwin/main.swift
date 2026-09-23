import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private let snapSettings = SnapSettings.shared
    private lazy var snapManager = SnapManager(settings: snapSettings)
    private let layoutMenuSettings = LayoutMenuSettings.shared
    private lazy var layoutMenuManager = LayoutMenuManager(settings: layoutMenuSettings)
    private lazy var windowExtrasManager = WindowExtrasManager()
    private let greenButtonSwitch = FeatureSwitch(key: "green-button-maximizes", title: "Green button maximizes", defaultOn: true)
    private let titleBarSwitch = FeatureSwitch(key: "title-bar-double-click-maximizes", title: "Double-click title bar maximizes", defaultOn: true)
    private let showDesktopSwitch = FeatureSwitch(key: "show-desktop-corner", title: "Show desktop corner", defaultOn: true)
    private let commandArrowSwitch = FeatureSwitch(key: "command-arrow-snapping", title: "Command-arrow snapping", defaultOn: true)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        configureWindowExtras()
        keepAwake.onChange = { [weak self] in self?.updateUI() }
        keepAwake.refresh()
        snapManager.refreshPermission()
        layoutMenuManager.refreshPermission()
        updateUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwake.stop()
        windowExtrasManager.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        keepAwake.refresh()
        snapManager.refreshPermission()
        layoutMenuManager.refreshPermission()
        windowExtrasManager.refreshPermission()
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
        let windowsHeader = NSMenuItem(title: "Windows", action: nil, keyEquivalent: "")
        windowsHeader.isEnabled = false
        menu.addItem(windowsHeader)
        menu.addItem(greenButtonSwitch.makeMenuItem())
        menu.addItem(titleBarSwitch.makeMenuItem())
        menu.addItem(showDesktopSwitch.makeMenuItem())
        menu.addItem(commandArrowSwitch.makeMenuItem())

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

    private func configureWindowExtras() {
        greenButtonSwitch.onChange = { [weak self] in self?.windowExtrasManager.setGreenButtonEnabled($0) }
        titleBarSwitch.onChange = { [weak self] in self?.windowExtrasManager.setTitleBarDoubleClickEnabled($0) }
        showDesktopSwitch.onChange = { [weak self] in self?.windowExtrasManager.setShowDesktopEnabled($0) }
        commandArrowSwitch.onChange = { [weak self] in self?.windowExtrasManager.setCommandArrowEnabled($0) }
        greenButtonSwitch.start()
        titleBarSwitch.start()
        showDesktopSwitch.start()
        commandArrowSwitch.start()
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
