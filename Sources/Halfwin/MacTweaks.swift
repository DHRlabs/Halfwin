import AppKit
import ApplicationServices
import SwiftUI

enum MacTweakGroup: String, CaseIterable, Identifiable {
    case dock = "Dock"
    case animations = "Faster animations"
    case finder = "Finder"
    case desktop = "Desktop"

    var id: String { rawValue }
}

enum MacTweakID: String, CaseIterable {
    case dockMagnification
    case dockIndicators
    case minimizeEffect
    case launchAnimation
    case instantAutoHide
    case slowMotionMinimize
    case windowAnimations
    case fasterSheets
    case instantQuickLook
    case finderAnimations
    case listView
    case fileExtensions
    case pathBar
    case statusBar
    case foldersFirst
    case wallpaperClick
}

struct MacTweakPreference {
    let domain: String
    let key: String
    let value: Any
    let restartPolicy: DockPreference.RestartPolicy
}

struct MacTweak: Identifiable {
    let id: MacTweakID
    let title: String
    let group: MacTweakGroup
    let preferences: [MacTweakPreference]

    static let all: [MacTweak] = [
        .init(id: .dockMagnification, title: "Dock magnification off", group: .dock,
              preferences: [.init(domain: "com.apple.dock", key: "magnification", value: false, restartPolicy: .dock)]),
        .init(id: .dockIndicators, title: "Show open-app indicators", group: .dock,
              preferences: [.init(domain: "com.apple.dock", key: "show-process-indicators", value: true, restartPolicy: .dock)]),
        .init(id: .minimizeEffect, title: "Minimize effect: Scale", group: .dock,
              preferences: [.init(domain: "com.apple.dock", key: "mineffect", value: "scale", restartPolicy: .dock)]),
        .init(id: .launchAnimation, title: "No launch bounce", group: .dock,
              preferences: [.init(domain: "com.apple.dock", key: "launchanim", value: false, restartPolicy: .dock)]),
        .init(id: .instantAutoHide, title: "Instant Dock auto-hide", group: .dock, preferences: [
            .init(domain: "com.apple.dock", key: "autohide-delay", value: 0.0, restartPolicy: .dock),
            .init(domain: "com.apple.dock", key: "autohide-time-modifier", value: 0.0, restartPolicy: .dock)
        ]),
        .init(id: .slowMotionMinimize, title: "No slow-motion minimize", group: .dock,
              preferences: [.init(domain: "com.apple.dock", key: "slow-motion-allowed", value: false, restartPolicy: .dock)]),
        .init(id: .windowAnimations, title: "App window open and close animations off", group: .animations,
              preferences: [.init(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", value: false, restartPolicy: .none)]),
        .init(id: .fasterSheets, title: "Faster sheets and resizes", group: .animations,
              preferences: [.init(domain: "NSGlobalDomain", key: "NSWindowResizeTime", value: 0.001, restartPolicy: .none)]),
        .init(id: .instantQuickLook, title: "Instant Quick Look", group: .animations,
              preferences: [.init(domain: "NSGlobalDomain", key: "QLPanelAnimationDuration", value: 0.0, restartPolicy: .none)]),
        .init(id: .finderAnimations, title: "Finder animations off", group: .animations, preferences: [
            .init(domain: "com.apple.finder", key: "DisableAllAnimations", value: true, restartPolicy: .finder),
            .init(domain: "com.apple.finder", key: "AnimateWindowZoom", value: false, restartPolicy: .finder),
            .init(domain: "com.apple.finder", key: "AnimateInfoPanes", value: false, restartPolicy: .finder)
        ]),
        .init(id: .listView, title: "List view everywhere", group: .finder,
              preferences: [.init(domain: "com.apple.finder", key: "FXPreferredViewStyle", value: "Nlsv", restartPolicy: .finder)]),
        .init(id: .fileExtensions, title: "Show all file extensions", group: .finder,
              preferences: [.init(domain: "NSGlobalDomain", key: "AppleShowAllExtensions", value: true, restartPolicy: .finder)]),
        .init(id: .pathBar, title: "Path bar", group: .finder,
              preferences: [.init(domain: "com.apple.finder", key: "ShowPathbar", value: true, restartPolicy: .finder)]),
        .init(id: .statusBar, title: "Status bar", group: .finder,
              preferences: [.init(domain: "com.apple.finder", key: "ShowStatusBar", value: true, restartPolicy: .finder)]),
        .init(id: .foldersFirst, title: "Folders first", group: .finder,
              preferences: [.init(domain: "com.apple.finder", key: "_FXSortFoldersFirst", value: true, restartPolicy: .finder)]),
        .init(id: .wallpaperClick, title: "Wallpaper click does nothing", group: .desktop,
              preferences: [.init(domain: "com.apple.WindowManager", key: "EnableStandardClickToShowDesktop", value: false, restartPolicy: .none)])
    ]
}

final class MacTweaks: ObservableObject {
    static let shared = MacTweaks()

    @Published private var states: [MacTweakID: Bool]
    @Published private var changedOutsideHalfwin = Set<MacTweakID>()
    @Published private(set) var finderAutomationDenied = false

    private let defaults = UserDefaults.standard
    private lazy var finderListViewMonitor = FinderListViewMonitor { [weak self] denied in
        self?.finderAutomationDenied = denied
    }

    private init() {
        let defaults = UserDefaults.standard
        states = Dictionary(uniqueKeysWithValues: MacTweak.all.map { tweak in
            let key = Self.toggleKey(tweak.id)
            return (tweak.id, defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key))
        })
    }

    func isEnabled(_ id: MacTweakID) -> Bool { states[id] ?? true }
    func wasChangedOutsideHalfwin(_ id: MacTweakID) -> Bool { changedOutsideHalfwin.contains(id) }

    func setEnabled(_ enabled: Bool, for id: MacTweakID) {
        guard states[id] != enabled else { return }
        states[id] = enabled
        changedOutsideHalfwin.remove(id)
        defaults.set(enabled, forKey: Self.toggleKey(id))
        apply(id, enabled: enabled)
        if id == .listView { finderListViewMonitor.setEnabled(enabled) }
    }

    func start() {
        var changedOutside = Set<MacTweakID>()
        for tweak in MacTweak.all where isEnabled(tweak.id) {
            if apply(tweak.id, enabled: true, skipIfExternallyChanged: true) {
                changedOutside.insert(tweak.id)
            }
        }
        changedOutsideHalfwin = changedOutside
        finderListViewMonitor.setEnabled(isEnabled(.listView))
    }

    func openReduceMotionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Seeing_Display") {
            NSWorkspace.shared.open(url)
        }
    }

    func retryFinderAutomation() {
        finderListViewMonitor.retryAutomation()
    }

    @discardableResult
    private func apply(_ id: MacTweakID, enabled: Bool, skipIfExternallyChanged: Bool = false) -> Bool {
        guard let tweak = MacTweak.all.first(where: { $0.id == id }) else { return false }
        var changedOutside = false
        for preference in tweak.preferences {
            let skipped = DockPreference.setFeature(
                enabled,
                domain: preference.domain,
                key: preference.key,
                value: preference.value,
                restartPolicy: preference.restartPolicy,
                savedPreviousKey: "Halfwin.macTweaks.\(id.rawValue).\(preference.key).PreviousValue",
                skipIfExternallyChanged: skipIfExternallyChanged
            )
            changedOutside = changedOutside || skipped
        }
        return changedOutside
    }

    private static func toggleKey(_ id: MacTweakID) -> String { "Halfwin.macTweaks.\(id.rawValue).enabled" }
}

private final class FinderListViewMonitor {
    private let onAutomationDenied: (Bool) -> Void
    private var enabled = false
    private var automationDenied = false
    private var activationObserver: NSObjectProtocol?
    private var accessibilityObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedWindows: [AXUIElement] = []
    private var observerSource: CFRunLoopSource?
    private var observedProcessID: pid_t?
    private var updateScheduled = false
    private var pendingWindowName: String?
    private var lastWindowName: String?

    init(onAutomationDenied: @escaping (Bool) -> Void) {
        self.onAutomationDenied = onAutomationDenied
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            automationDenied = false
            onAutomationDenied(false)
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.finder" else { return }
                self?.finderActivated()
            }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
                observeFinder()
            }
        } else {
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
            removeAccessibilityObserver()
        }
    }

    func retryAutomation() {
        guard enabled, automationDenied else { return }
        automationDenied = false
        onAutomationDenied(false)
        if let lastWindowName { scheduleListViewCheck(for: lastWindowName) }
    }

    func accessibilityChanged(_ element: AXUIElement, notification: String) {
        guard enabled, !automationDenied else { return }
        if notification == kAXWindowCreatedNotification as String {
            for window in observeWindows() {
                if let name = standardFinderWindowName(window) { scheduleListViewCheck(for: name) }
            }
        } else if notification == kAXTitleChangedNotification as String {
            observeWindows()
            if let name = standardFinderWindowName(element) { scheduleListViewCheck(for: name) }
        }
    }

    private func finderActivated() {
        let shouldRetry = automationDenied
        if shouldRetry {
            automationDenied = false
            onAutomationDenied(false)
        }
        observeFinder()
        if shouldRetry, let lastWindowName { scheduleListViewCheck(for: lastWindowName) }
    }

    private func observeFinder() {
        guard enabled,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
                .first(where: { !$0.isTerminated }) else { return }
        if observedProcessID != app.processIdentifier {
            removeAccessibilityObserver()
            observedProcessID = app.processIdentifier
        }
        if accessibilityObserver == nil {
            var created: AXObserver?
            if AXObserverCreate(app.processIdentifier, finderAXCallback, &created) == .success,
               let created {
                let application = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(application, 0.1)
                let source = AXObserverGetRunLoopSource(created)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                _ = AXObserverAddNotification(
                    created, application, kAXWindowCreatedNotification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                accessibilityObserver = created
                observedApplication = application
                observerSource = source
            }
        }
        observeWindows()
    }

    @discardableResult
    private func observeWindows() -> [AXUIElement] {
        guard let accessibilityObserver, let observedApplication else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(observedApplication, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        let newWindows = windows.filter { window in !observedWindows.contains(where: { CFEqual($0, window) }) }
        for window in observedWindows where !windows.contains(where: { CFEqual($0, window) }) {
            AXObserverRemoveNotification(accessibilityObserver, window, kAXTitleChangedNotification as CFString)
        }
        for window in newWindows {
            _ = AXObserverAddNotification(
                accessibilityObserver, window, kAXTitleChangedNotification as CFString,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        observedWindows = windows
        return newWindows
    }

    private func standardFinderWindowName(_ window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, 0.1)
        func stringAttribute(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        guard stringAttribute(kAXRoleAttribute as String) == kAXWindowRole as String,
              stringAttribute(kAXSubroleAttribute as String) == kAXStandardWindowSubrole as String else { return nil }
        return stringAttribute(kAXTitleAttribute as String)
    }

    private func scheduleListViewCheck(for windowName: String) {
        guard enabled, !automationDenied else { return }
        lastWindowName = windowName
        guard !updateScheduled else {
            pendingWindowName = windowName
            return
        }
        updateScheduled = true
        finderScriptQueue.async { [weak self] in
            guard let self else { return }
            let denied = self.setFinderWindowToListView(named: windowName)
            DispatchQueue.main.async {
                self.updateScheduled = false
                if denied, self.enabled, !self.automationDenied {
                    self.automationDenied = true
                    self.onAutomationDenied(true)
                }
                let pendingWindowName = self.pendingWindowName
                self.pendingWindowName = nil
                if self.enabled, !self.automationDenied, let pendingWindowName {
                    self.scheduleListViewCheck(for: pendingWindowName)
                }
            }
        }
    }

    private let finderScriptQueue = DispatchQueue(label: "Halfwin.finder-list-view", qos: .utility)
    private var finderScript: NSAppleScript?
    private var finderScriptWindowName: String?
    private var finderScriptCompiled = false

    private func setFinderWindowToListView(named windowName: String) -> Bool {
        if !finderScriptCompiled || finderScriptWindowName != windowName {
            finderScriptCompiled = false
            // ponytail: same-title windows can collide; use a stable AX-to-Finder window ID if one becomes available.
            let escapedWindowName = windowName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            with timeout of 2 seconds
                tell application id "com.apple.finder"
                    try
                        set finderWindow to first window whose name is "\(escapedWindowName)"
                        if current view of finderWindow is not list view then set current view of finderWindow to list view
                    end try
                end tell
            end timeout
            """
            let script = NSAppleScript(source: source)
            var compileError: NSDictionary?
            guard script?.compileAndReturnError(&compileError) == true else { return false }
            finderScript = script
            finderScriptWindowName = windowName
            finderScriptCompiled = true
        }
        guard let finderScript else { return false }
        var error: NSDictionary?
        _ = finderScript.executeAndReturnError(&error)
        return (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743
    }

    private func removeAccessibilityObserver() {
        if let accessibilityObserver, let observedApplication {
            AXObserverRemoveNotification(accessibilityObserver, observedApplication, kAXWindowCreatedNotification as CFString)
            for window in observedWindows {
                AXObserverRemoveNotification(accessibilityObserver, window, kAXTitleChangedNotification as CFString)
            }
        }
        if let observerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), observerSource, .commonModes) }
        accessibilityObserver = nil
        observedApplication = nil
        observedWindows.removeAll()
        observerSource = nil
        observedProcessID = nil
    }
}

private let finderAXCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let monitor = Unmanaged<FinderListViewMonitor>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async { monitor.accessibilityChanged(element, notification: notification as String) }
}
