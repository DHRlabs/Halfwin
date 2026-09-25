import SwiftUI
import Combine

enum AutoTileLayout: String, CaseIterable, Identifiable {
    case columns = "Columns"
    case bigLeftStack = "Big left plus stack"

    var id: String { rawValue }
}

enum AutoTileModifier: String, CaseIterable, Identifiable {
    case controlOption = "Control–Option"
    case controlOptionCommand = "Control–Option–Command"
    case off = "Off"

    var id: String { rawValue }
}

final class AutoTileSettings: ObservableObject {
    static let shared = AutoTileSettings()
    static let defaultFloatApps = [
        "com.apple.systempreferences", "com.apple.calculator", "com.1password.1password",
        "com.apple.ActivityMonitor", "com.dhrlabs.halfwin"
    ]

    private let defaults = UserDefaults.standard
    private let layoutKey = "Halfwin.autoTileLayout"
    private let columnWidthKey = "Halfwin.autoTileColumnWidth"
    private let gapKey = "Halfwin.autoTileGap"
    private let modifierKey = "Halfwin.autoTileModifier"
    private let floatAppsKey = "Halfwin.autoTileFloatApps"

    @Published var layout: AutoTileLayout {
        didSet { defaults.set(layout.rawValue, forKey: layoutKey) }
    }
    @Published var columnWidth: Double {
        didSet {
            let value = min(max(columnWidth.isFinite ? columnWidth : 0.5, 0.35), 1.0)
            if value != columnWidth { columnWidth = value }
            defaults.set(value, forKey: columnWidthKey)
        }
    }
    @Published var gap: Double {
        didSet {
            let value = min(max(gap.isFinite ? gap : 0, 0), 24)
            if value != gap { gap = value }
            defaults.set(value, forKey: gapKey)
        }
    }
    @Published var modifier: AutoTileModifier {
        didSet { defaults.set(modifier.rawValue, forKey: modifierKey) }
    }
    @Published var alwaysFloatAppIDs: [String] {
        didSet {
            let cleaned = Self.clean(alwaysFloatAppIDs)
            if cleaned != alwaysFloatAppIDs { alwaysFloatAppIDs = cleaned }
            defaults.set(cleaned, forKey: floatAppsKey)
        }
    }

    private init() {
        let layout = defaults.string(forKey: layoutKey).flatMap(AutoTileLayout.init(rawValue:)) ?? .columns
        let modifier = defaults.string(forKey: modifierKey).flatMap(AutoTileModifier.init(rawValue:)) ?? .controlOption
        let savedWidth = defaults.object(forKey: columnWidthKey) as? Double ?? 0.5
        let savedGap = defaults.object(forKey: gapKey) as? Double ?? 0
        self.layout = layout
        columnWidth = min(max(savedWidth.isFinite ? savedWidth : 0.5, 0.35), 1.0)
        gap = min(max(savedGap.isFinite ? savedGap : 0, 0), 24)
        self.modifier = modifier
        alwaysFloatAppIDs = Self.clean(defaults.stringArray(forKey: floatAppsKey) ?? Self.defaultFloatApps)
    }

    private static func clean(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
}
