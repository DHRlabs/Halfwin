import Combine
import Foundation

enum SnapAssistFillMode: String, CaseIterable, Identifiable {
    case mostRecent, letMePick

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mostRecent: return "With my most recent windows"
        case .letMePick: return "Let me pick"
        }
    }
}

final class SnapAssistSettings: ObservableObject {
    static let shared = SnapAssistSettings()

    private let defaults = UserDefaults.standard
    private let fillEmptySpotsKey = "Halfwin.snapAssistFillEmptySpots"

    @Published var fillEmptySpots: SnapAssistFillMode {
        didSet { defaults.set(fillEmptySpots.rawValue, forKey: fillEmptySpotsKey) }
    }

    private init() {
        fillEmptySpots = defaults.string(forKey: fillEmptySpotsKey)
            .flatMap(SnapAssistFillMode.init(rawValue:)) ?? .mostRecent
    }
}
