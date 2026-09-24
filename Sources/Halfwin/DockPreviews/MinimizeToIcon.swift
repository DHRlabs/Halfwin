import AppKit
import CoreFoundation
import Darwin

enum MinimizeToIcon {
    private enum PreviousValue: String {
        case absent
        case enabled
        case disabled
    }

    private static let domain = "com.apple.dock" as CFString
    private static let key = "minimize-to-application" as CFString
    private static let previousValueKey = "Halfwin.minimizeToIconPreviousValue"

    static func setDockPreviewsEnabled(_ enabled: Bool) {
        guard !CFPreferencesAppValueIsForced(key, domain) else { return }
        if enabled {
            enableMinimizeToIcon()
        } else {
            restorePreviousValue()
        }
    }

    private static func enableMinimizeToIcon() {
        let current = CFPreferencesCopyAppValue(key, domain)
        if let current {
            guard let value = booleanValue(current), !value else { return }
            savePreviousValueIfNeeded(.disabled)
        } else {
            savePreviousValueIfNeeded(.absent)
        }

        CFPreferencesSetAppValue(key, kCFBooleanTrue, domain)
        guard CFPreferencesAppSynchronize(domain),
              booleanValue(CFPreferencesCopyAppValue(key, domain)) == true else { return }
        restartDock()
    }

    private static func restorePreviousValue() {
        guard let rawValue = UserDefaults.standard.string(forKey: previousValueKey),
              let previousValue = PreviousValue(rawValue: rawValue) else { return }

        let current = CFPreferencesCopyAppValue(key, domain)
        switch previousValue {
        case .absent:
            guard current != nil else {
                UserDefaults.standard.removeObject(forKey: previousValueKey)
                return
            }
            CFPreferencesSetAppValue(key, nil, domain)
        case .enabled:
            if booleanValue(current) == true {
                UserDefaults.standard.removeObject(forKey: previousValueKey)
                return
            }
            CFPreferencesSetAppValue(key, kCFBooleanTrue, domain)
        case .disabled:
            if booleanValue(current) == false {
                UserDefaults.standard.removeObject(forKey: previousValueKey)
                return
            }
            CFPreferencesSetAppValue(key, kCFBooleanFalse, domain)
        }

        guard CFPreferencesAppSynchronize(domain) else { return }
        switch previousValue {
        case .absent:
            guard CFPreferencesCopyAppValue(key, domain) == nil else { return }
        case .enabled:
            guard booleanValue(CFPreferencesCopyAppValue(key, domain)) == true else { return }
        case .disabled:
            guard booleanValue(CFPreferencesCopyAppValue(key, domain)) == false else { return }
        }
        UserDefaults.standard.removeObject(forKey: previousValueKey)
        restartDock()
    }

    private static func savePreviousValueIfNeeded(_ value: PreviousValue) {
        guard UserDefaults.standard.object(forKey: previousValueKey) == nil else { return }
        UserDefaults.standard.set(value.rawValue, forKey: previousValueKey)
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

    private static func restartDock() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated }) else { return }
        kill(dock.processIdentifier, SIGTERM)
    }
}
