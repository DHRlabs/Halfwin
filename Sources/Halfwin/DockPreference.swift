import AppKit
import CoreFoundation
import Darwin

enum DockPreference {
    enum RestartPolicy: Hashable {
        case dock
        case finder
        case none

        var bundleIdentifier: String? {
            switch self {
            case .dock: "com.apple.dock"
            case .finder: "com.apple.finder"
            case .none: nil
            }
        }
    }

    private struct SavedValue {
        let hadPreviousValue: Bool
        let previousValue: Data?
        var writtenValue: Data?
    }

    private struct RestartState {
        var requested = false
        var scheduled = false
        var lastRestartAt: TimeInterval?
    }

    private static let defaults = UserDefaults.standard
    private static let globalDomain = UserDefaults.globalDomain as CFString
    private static var restartStates: [RestartPolicy: RestartState] = [:]

    static func setFeature(
        _ enabled: Bool,
        domain: String,
        key: String,
        value: Any,
        restartPolicy: RestartPolicy,
        savedPreviousKey: String
    ) {
        let cfKey = key as CFString
        let cfDomain = domain as CFString
        guard !isForced(cfKey, in: cfDomain),
              let targetData = propertyListData(value) else { return }

        if enabled {
            var saved: SavedValue
            if let existing = loadSavedValue(for: savedPreviousKey) {
                saved = existing
            } else {
                guard let captured = savePreviousValue(copyValue(cfKey, from: cfDomain), for: savedPreviousKey) else { return }
                saved = captured
            }
            saved.writtenValue = targetData
            store(saved, for: savedPreviousKey)
            guard !valuesEqual(copyValue(cfKey, from: cfDomain), value) else { return }

            setValue(value as CFPropertyList, for: cfKey, in: cfDomain)
            guard synchronize(cfDomain), valuesEqual(copyValue(cfKey, from: cfDomain), value) else { return }
            requestRestart(restartPolicy)
        } else {
            restoreValue(
                targetData: targetData,
                key: cfKey,
                domain: cfDomain,
                restartPolicy: restartPolicy,
                savedPreviousKey: savedPreviousKey
            )
        }
    }

    private static func savePreviousValue(_ value: Any?, for key: String) -> SavedValue? {
        let previousValue = propertyListData(value)
        guard value == nil || previousValue != nil else { return nil }
        let saved = SavedValue(
            hadPreviousValue: value != nil,
            previousValue: previousValue,
            writtenValue: nil
        )
        store(saved, for: key)
        return saved
    }

    private static func loadSavedValue(for key: String) -> SavedValue? {
        if let stored = defaults.dictionary(forKey: key) {
            guard let hadPreviousValue = stored["hadPreviousValue"] as? Bool else { return nil }
            let previousValue = stored["previousValue"] as? Data
            guard !hadPreviousValue || previousValue != nil else { return nil }
            return SavedValue(
                hadPreviousValue: hadPreviousValue,
                previousValue: previousValue,
                writtenValue: stored["writtenValue"] as? Data
            )
        }

        guard let legacy = defaults.string(forKey: key) else { return nil }
        let saved: SavedValue
        switch legacy {
        case "absent": saved = SavedValue(hadPreviousValue: false, previousValue: nil, writtenValue: nil)
        case "enabled": saved = SavedValue(hadPreviousValue: true, previousValue: propertyListData(true), writtenValue: nil)
        case "disabled": saved = SavedValue(hadPreviousValue: true, previousValue: propertyListData(false), writtenValue: nil)
        default: return nil
        }
        store(saved, for: key)
        return saved
    }

    private static func store(_ saved: SavedValue, for key: String) {
        var value: [String: Any] = ["hadPreviousValue": saved.hadPreviousValue]
        if let previousValue = saved.previousValue { value["previousValue"] = previousValue }
        if let writtenValue = saved.writtenValue { value["writtenValue"] = writtenValue }
        defaults.set(value, forKey: key)
    }

    private static func restoreValue(
        targetData: Data,
        key: CFString,
        domain: CFString,
        restartPolicy: RestartPolicy,
        savedPreviousKey: String
    ) {
        guard var saved = loadSavedValue(for: savedPreviousKey) else { return }
        let current = copyValue(key, from: domain)
        if saved.writtenValue == nil, valuesEqual(current, data: targetData) {
            saved.writtenValue = targetData
            store(saved, for: savedPreviousKey)
        }
        guard let writtenValue = saved.writtenValue,
              valuesEqual(current, data: writtenValue) else {
            defaults.removeObject(forKey: savedPreviousKey)
            return
        }

        guard !valuesEqual(current, data: saved.previousValue, present: saved.hadPreviousValue) else {
            defaults.removeObject(forKey: savedPreviousKey)
            return
        }
        let previous: Any?
        if saved.hadPreviousValue {
            guard let previousValue = saved.previousValue.flatMap(propertyListValue) else { return }
            previous = previousValue
        } else {
            previous = nil
        }
        setValue(previous as CFPropertyList?, for: key, in: domain)
        guard synchronize(domain),
              valuesEqual(
                copyValue(key, from: domain),
                data: saved.previousValue,
                present: saved.hadPreviousValue
              ) else { return }
        defaults.removeObject(forKey: savedPreviousKey)
        requestRestart(restartPolicy)
    }

    private static func propertyListData(_ value: Any?) -> Data? {
        guard let value,
              PropertyListSerialization.propertyList(value, isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func propertyListValue(_ data: Data) -> Any? {
        try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)
    }

    private static func isForced(_ key: CFString, in domain: CFString) -> Bool {
        if domain == globalDomain {
            return defaults.objectIsForced(forKey: key as String, inDomain: UserDefaults.globalDomain)
        }
        return CFPreferencesAppValueIsForced(key, domain)
    }

    private static func copyValue(_ key: CFString, from domain: CFString) -> Any? {
        if domain == globalDomain {
            return CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        return CFPreferencesCopyAppValue(key, domain)
    }

    private static func setValue(_ value: CFPropertyList?, for key: CFString, in domain: CFString) {
        if domain == globalDomain {
            CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        } else {
            CFPreferencesSetAppValue(key, value, domain)
        }
    }

    private static func synchronize(_ domain: CFString) -> Bool {
        if domain == globalDomain {
            return CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        return CFPreferencesAppSynchronize(domain)
    }

    private static func valuesEqual(_ current: Any?, data: Data?, present: Bool = true) -> Bool {
        guard present else { return current == nil }
        guard let data, let expected = propertyListValue(data) else { return false }
        return valuesEqual(current, expected)
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs, CFGetTypeID(lhs as CFTypeRef) == CFGetTypeID(rhs as CFTypeRef) else { return false }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber,
           CFGetTypeID(left) == CFNumberGetTypeID() {
            return String(cString: left.objCType) == String(cString: right.objCType) && left == right
        }
        return CFEqual(lhs as CFTypeRef, rhs as CFTypeRef)
    }

    private static func requestRestart(_ policy: RestartPolicy) {
        guard policy.bundleIdentifier != nil else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { requestRestart(policy) }
            return
        }
        var state = restartStates[policy, default: RestartState()]
        state.requested = true
        guard !state.scheduled else {
            restartStates[policy] = state
            return
        }
        state.scheduled = true
        restartStates[policy] = state
        DispatchQueue.main.async { restartIfNeeded(policy) }
    }

    private static func restartIfNeeded(_ policy: RestartPolicy) {
        guard var state = restartStates[policy], let bundleIdentifier = policy.bundleIdentifier else { return }
        guard state.requested else {
            state.scheduled = false
            restartStates[policy] = state
            return
        }
        if let lastRestartAt = state.lastRestartAt {
            let wait = 3 - (ProcessInfo.processInfo.systemUptime - lastRestartAt)
            if wait > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { restartIfNeeded(policy) }
                return
            }
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { restartIfNeeded(policy) }
            return
        }
        state.requested = false
        state.scheduled = false
        state.lastRestartAt = ProcessInfo.processInfo.systemUptime
        restartStates[policy] = state
        kill(app.processIdentifier, SIGTERM)
    }
}

enum MissionControlDrag {
    static func setDragSnappingEnabled(_ enabled: Bool) {
        DockPreference.setFeature(
            enabled,
            domain: "com.apple.dock",
            key: "enterMissionControlByTopWindowDrag",
            value: false,
            restartPolicy: .dock,
            savedPreviousKey: "Halfwin.missionControlDragPreviousValue"
        )
        for key in ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"] {
            DockPreference.setFeature(
                enabled,
                domain: "com.apple.WindowManager",
                key: key,
                value: false,
                restartPolicy: .none,
                savedPreviousKey: "Halfwin.edgeTiling.\(key).PreviousValue"
            )
        }
    }
}

enum MinimizeToIcon {
    static func setDockPreviewsEnabled(_ enabled: Bool) {
        DockPreference.setFeature(
            enabled,
            domain: "com.apple.dock",
            key: "minimize-to-application",
            value: true,
            restartPolicy: .dock,
            savedPreviousKey: "Halfwin.minimizeToIconPreviousValue"
        )
    }
}
