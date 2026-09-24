import AppKit
import CoreFoundation

enum MissionControlDrag {
    private enum PreviousValue: String {
        case absent
        case enabled
        case disabled
    }

    private static let domain = "com.apple.dock" as CFString
    private static let key = "enterMissionControlByTopWindowDrag" as CFString
    private static let previousValueKey = "Halfwin.missionControlDragPreviousValue"

    static func setDragSnappingEnabled(_ enabled: Bool) {
        if enabled {
            disableMissionControlDrag()
        } else {
            restoreMissionControlDrag()
        }
    }

    private static func disableMissionControlDrag() {
        let current = CFPreferencesCopyAppValue(key, domain)
        if let value = current as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            let previousValue: PreviousValue = value.boolValue ? .enabled : .disabled
            if value.boolValue || UserDefaults.standard.object(forKey: previousValueKey) == nil {
                UserDefaults.standard.set(previousValue.rawValue, forKey: previousValueKey)
            }
            guard value.boolValue else { return }
        } else if current == nil {
            UserDefaults.standard.set(PreviousValue.absent.rawValue, forKey: previousValueKey)
        } else {
            return
        }

        CFPreferencesSetAppValue(key, kCFBooleanFalse, domain)
        CFPreferencesAppSynchronize(domain)
        restartDock()
    }

    private static func restoreMissionControlDrag() {
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
            if let value = current as? NSNumber,
               CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue {
                UserDefaults.standard.removeObject(forKey: previousValueKey)
                return
            }
            CFPreferencesSetAppValue(key, kCFBooleanTrue, domain)
        case .disabled:
            if let value = current as? NSNumber,
               CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue {
                UserDefaults.standard.removeObject(forKey: previousValueKey)
                return
            }
            CFPreferencesSetAppValue(key, kCFBooleanFalse, domain)
        }

        CFPreferencesAppSynchronize(domain)
        UserDefaults.standard.removeObject(forKey: previousValueKey)
        restartDock()
    }

    private static func restartDock() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated })?.terminate()
    }
}
