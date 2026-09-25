import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private let mouseFeatures = MouseFeatures()
    private let keyboardExtras = KeyboardExtras()
    private let snapSettings = SnapSettings.shared
    private lazy var snapManager = SnapManager(settings: snapSettings, layoutMenu: layoutMenuManager)
    private let snapAssistManager = SnapAssistManager()
    private let snapGroupsManager = SnapGroupsManager()
    private let snapAssistSwitch = FeatureSwitch(key: "snapAssist", title: "Snap Assist", defaultOn: true)
    private let snapGroupsSwitch = FeatureSwitch(key: "snapGroups", title: "Snap Groups", defaultOn: false)
    private let dragToTopLayoutsSwitch = FeatureSwitch(key: "drag-to-top-layouts", title: "Drag to top for layouts", defaultOn: true)
    private let dockPreviewsSwitch = FeatureSwitch(key: "dock-previews", title: "Dock previews", defaultOn: true)
    private let clickDockIconMinimizeSwitch = FeatureSwitch(key: "click-dock-icon-to-minimize", title: "Click Dock icon to minimize", defaultOn: true)
    private let notificationCountSwitch = FeatureSwitch(key: "notification-count", title: "Notification count", defaultOn: true)
    private let notificationCountManager = NotificationCountManager()
    private let layoutMenuSettings = LayoutMenuSettings.shared
    private let dockPreviewSettings = DockPreviewSettings.shared
    private let autoTileSettings = AutoTileSettings.shared
    private lazy var dockPreviewsManager = MainActor.assumeIsolated { DockPreviewManager(settings: dockPreviewSettings) }
    private lazy var layoutMenuManager = LayoutMenuManager(settings: layoutMenuSettings)
    private lazy var autoTileManager = AutoTileManager(settings: autoTileSettings)
    private lazy var windowExtrasManager = WindowExtrasManager()
    private let greenButtonSwitch = FeatureSwitch(key: "green-button-maximizes", title: "Green button maximizes", defaultOn: true)
    private let titleBarSwitch = FeatureSwitch(key: "title-bar-double-click-maximizes", title: "Double-click title bar maximizes", defaultOn: true)
    private let showDesktopSwitch = FeatureSwitch(key: "show-desktop-corner", title: "Show desktop corner", defaultOn: true)
    private let commandArrowSwitch = FeatureSwitch(key: "command-arrow-snapping", title: "Command-arrow snapping", defaultOn: true)
    private let autoTileSwitch = FeatureSwitch(key: "auto-tile", title: "Auto-tile", defaultOn: false)
    private lazy var settingsWindowController = SettingsWindowController(
        settings: snapSettings,
        layoutMenuSettings: layoutMenuSettings,
        dockPreviewSettings: dockPreviewSettings,
        autoTileSettings: autoTileSettings,
        notificationCount: notificationCountManager
    )
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var awakeItem: NSMenuItem!
    private var durationItems: [NSMenuItem] = []
    private var lidItem: NSMenuItem!
    private var lidDurationItems: [NSMenuItem] = []
    private var hasPendingFinderCut = false
    private var loginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var screenRecordingItem: NSMenuItem!
    private var activationRefreshObserver: NSObjectProtocol?
    private var launchSessionObservers: [NSObjectProtocol] = []
    private var sessionInactiveAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        launchSessionObservers = [
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.sessionInactiveAtLaunch = true
            },
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.sessionInactiveAtLaunch = false
            }
        ]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let previewPath = ProcessInfo.processInfo.environment["HALFWIN_RENDER_MENU_PREVIEW"] {
            FeatureSwitch.renderPreview(to: URL(fileURLWithPath: previewPath))
            exit(0)
        }
        #endif

        for observer in launchSessionObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        launchSessionObservers.removeAll()
        MainActor.assumeIsolated { dockPreviewsManager.setSessionActive(!sessionInactiveAtLaunch) }

        activationRefreshObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.snapAssistManager.refreshPermission()
            self?.snapGroupsManager.refreshPermission()
            self?.autoTileManager.refreshPermission()
            self?.notificationCountManager.refreshPermission()
            MainActor.assumeIsolated { self?.dockPreviewsManager.refreshPermission() }
        }
        SnapEvents.handler = { [weak self] window, action, screen in
            self?.snapAssistManager.didSnap(window: window, action: action, screen: screen)
            self?.snapGroupsManager.didSnap(window: window, action: action, screen: screen)
            self?.autoTileManager.didSnap(window: window, action: action, screen: screen)
        }
        autoTileSwitch.onChange = { [weak self] in self?.autoTileManager.setEnabled($0) }
        snapAssistSwitch.onChange = { [weak self] in self?.snapAssistManager.setEnabled($0) }
        snapGroupsSwitch.onChange = { [weak self] in self?.snapGroupsManager.setEnabled($0) }
        dragToTopLayoutsSwitch.onChange = { [weak self] in self?.snapManager.setDragToTopLayoutsEnabled($0) }
        var isInitialDockPreviewsState = true
        dockPreviewsSwitch.onChange = { [weak self] enabled in
            self?.dockPreviewsManager.setEnabled(enabled)
            if isInitialDockPreviewsState {
                isInitialDockPreviewsState = false
                if enabled { MinimizeToIcon.setDockPreviewsEnabled(true) }
                return
            }
            MinimizeToIcon.setDockPreviewsEnabled(enabled)
        }
        clickDockIconMinimizeSwitch.onChange = { [weak self] in
            self?.dockPreviewsManager.setClickToMinimizeEnabled($0)
        }
        notificationCountSwitch.onChange = { [weak self] in self?.notificationCountManager.setEnabled($0) }
        snapAssistSwitch.start()
        snapGroupsSwitch.start()
        dragToTopLayoutsSwitch.start()
        dockPreviewsSwitch.start()
        clickDockIconMinimizeSwitch.start()
        autoTileSwitch.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        keyboardExtras.onCutPendingChange = { [weak self] pending in
            guard let self else { return }
            self.hasPendingFinderCut = pending
            self.updateStatusTitle()
        }
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        notificationCountManager.onChange = { [weak self] in self?.updateStatusTitle() }
        notificationCountManager.refreshPermission()
        notificationCountSwitch.start()
        configureWindowExtras()
        keepAwake.onChange = { [weak self] in self?.updateUI() }
        keepAwake.refresh()
        mouseFeatures.start()
        snapManager.refreshPermission()
        layoutMenuManager.refreshPermission()
        keyboardExtras.start()
        updateUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationRefreshObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationRefreshObserver)
            self.activationRefreshObserver = nil
        }
        mouseFeatures.stop()
        keepAwake.stop()
        windowExtrasManager.stop()
        dockPreviewsManager.stop()
        snapGroupsManager.stop()
        snapAssistManager.setEnabled(false)
        autoTileManager.stop()
        keyboardExtras.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        keepAwake.refresh()
        mouseFeatures.refreshPermission()
        snapManager.refreshPermission()
        layoutMenuManager.refreshPermission()
        snapAssistManager.refreshPermission()
        snapGroupsManager.refreshPermission()
        windowExtrasManager.refreshPermission()
        dockPreviewsManager.refreshPermission()
        autoTileManager.refreshPermission()
        keyboardExtras.refreshPermission()
        notificationCountManager.refreshPermission()
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
        menu.addItem(autoTileSwitch.makeMenuItem())

        menu.addItem(.separator())

        let mouseHeader = NSMenuItem(title: "Mouse", action: nil, keyEquivalent: "")
        mouseHeader.isEnabled = false
        menu.addItem(mouseHeader)
        menu.addItem(mouseFeatures.windowsScrollDirection.makeMenuItem())
        menu.addItem(mouseFeatures.sideButtonsBackForward.makeMenuItem())

        menu.addItem(.separator())

        let snappingHeader = NSMenuItem(title: "Snapping", action: nil, keyEquivalent: "")
        snappingHeader.isEnabled = false
        menu.addItem(snappingHeader)
        menu.addItem(snapAssistSwitch.makeMenuItem())
        menu.addItem(snapGroupsSwitch.makeMenuItem())
        menu.addItem(dragToTopLayoutsSwitch.makeMenuItem())
        keyboardExtras.addMenuItems(to: menu)
        menu.addItem(.separator())
        let dockHeader = NSMenuItem(title: "Dock", action: nil, keyEquivalent: "")
        dockHeader.isEnabled = false
        menu.addItem(dockHeader)
        menu.addItem(dockPreviewsSwitch.makeMenuItem())
        menu.addItem(clickDockIconMinimizeSwitch.makeMenuItem())
        menu.addItem(.separator())
        menu.addItem(notificationCountSwitch.makeMenuItem())

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
        updateStatusTitle()
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

    private func updateStatusTitle() {
        let title = NSMutableAttributedString(string: hasPendingFinderCut ? "✂︎ hfWn" : "hfWn")
        if notificationCountManager.isCounting, notificationCountManager.total > 0 {
            title.append(NSAttributedString(string: " \(notificationCountManager.total) ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.systemRed
            ]))
        }
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = notificationCountManager.isCounting
            ? "\(notificationCountManager.total) Dock badge notifications. Click the date to open Notification Center."
            : nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
