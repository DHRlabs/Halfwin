import AppKit
import CoreFoundation
import Darwin

enum DockPreference {
    private enum PreviousValue: String {
        case absent
        case enabled
        case disabled
    }

    private static let domain = "com.apple.dock" as CFString
    private static var restartRequested = false
    private static var restartScheduled = false
    private static var lastRestartAt: TimeInterval?

    static func setFeature(
        _ enabled: Bool,
        key: String,
        enabledValue: Bool,
        savedPreviousKey: String
    ) {
        let key = key as CFString
        guard !CFPreferencesAppValueIsForced(key, domain) else { return }
        if enabled {
            setEnabledValue(enabledValue, for: key, savedPreviousKey: savedPreviousKey)
        } else {
            restoreValue(for: key, savedPreviousKey: savedPreviousKey)
        }
    }

    private static func setEnabledValue(_ target: Bool, for key: CFString, savedPreviousKey: String) {
        let current = CFPreferencesCopyAppValue(key, domain)
        let previousValue: PreviousValue
        if let current {
            guard let value = booleanValue(current) else { return }
            previousValue = value ? .enabled : .disabled
        } else {
            previousValue = .absent
        }
        savePreviousValueIfNeeded(previousValue, for: savedPreviousKey)
        guard booleanValue(current) != target else { return }

        CFPreferencesSetAppValue(key, target ? kCFBooleanTrue : kCFBooleanFalse, domain)
        guard CFPreferencesAppSynchronize(domain),
              booleanValue(CFPreferencesCopyAppValue(key, domain)) == target else { return }
        requestDockRestart()
    }

    private static func restoreValue(for key: CFString, savedPreviousKey: String) {
        guard let rawValue = UserDefaults.standard.string(forKey: savedPreviousKey),
              let previousValue = PreviousValue(rawValue: rawValue) else { return }

        let current = CFPreferencesCopyAppValue(key, domain)
        if isRestored(current, to: previousValue) {
            UserDefaults.standard.removeObject(forKey: savedPreviousKey)
            return
        }

        switch previousValue {
        case .absent:
            CFPreferencesSetAppValue(key, nil, domain)
        case .enabled:
            CFPreferencesSetAppValue(key, kCFBooleanTrue, domain)
        case .disabled:
            CFPreferencesSetAppValue(key, kCFBooleanFalse, domain)
        }
        guard CFPreferencesAppSynchronize(domain),
              isRestored(CFPreferencesCopyAppValue(key, domain), to: previousValue) else { return }
        UserDefaults.standard.removeObject(forKey: savedPreviousKey)
        requestDockRestart()
    }

    private static func isRestored(_ current: Any?, to previousValue: PreviousValue) -> Bool {
        switch previousValue {
        case .absent: return current == nil
        case .enabled: return booleanValue(current) == true
        case .disabled: return booleanValue(current) == false
        }
    }

    private static func savePreviousValueIfNeeded(_ value: PreviousValue, for key: String) {
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(value.rawValue, forKey: key)
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
        switch value.doubleValue {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    private static func requestDockRestart() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { requestDockRestart() }
            return
        }
        restartRequested = true
        guard !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.async { restartDockIfNeeded() }
    }

    private static func restartDockIfNeeded() {
        guard restartRequested else {
            restartScheduled = false
            return
        }
        if let lastRestartAt {
            let wait = 3 - (ProcessInfo.processInfo.systemUptime - lastRestartAt)
            if wait > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    restartDockIfNeeded()
                }
                return
            }
        }

        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                restartDockIfNeeded()
            }
            return
        }
        restartRequested = false
        restartScheduled = false
        lastRestartAt = ProcessInfo.processInfo.systemUptime
        kill(dock.processIdentifier, SIGTERM)
    }
}

enum MissionControlDrag {
    static func setDragSnappingEnabled(_ enabled: Bool) {
        DockPreference.setFeature(
            enabled,
            key: "enterMissionControlByTopWindowDrag",
            enabledValue: false,
            savedPreviousKey: "Halfwin.missionControlDragPreviousValue"
        )
    }
}

enum MinimizeToIcon {
    static func setDockPreviewsEnabled(_ enabled: Bool) {
        DockPreference.setFeature(
            enabled,
            key: "minimize-to-application",
            enabledValue: true,
            savedPreviousKey: "Halfwin.minimizeToIconPreviousValue"
        )
    }
}
