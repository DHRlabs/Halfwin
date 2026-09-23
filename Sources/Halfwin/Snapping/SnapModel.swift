import Foundation

/// The eight edge/corner zones a drag can land in. Matches Rectangle's
/// `Directional` (minus its unused `.c` case).
enum SnapPosition: String, CaseIterable, Codable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    var displayName: String {
        switch self {
        case .topLeft: return "Top-Left Corner"
        case .top: return "Top Edge"
        case .topRight: return "Top-Right Corner"
        case .left: return "Left Edge"
        case .right: return "Right Edge"
        case .bottomLeft: return "Bottom-Left Corner"
        case .bottom: return "Bottom Edge"
        case .bottomRight: return "Bottom-Right Corner"
        }
    }
}

/// What a zone does when a window is dropped in it. The three `*Compound`
/// cases are not single frames; `SnapGeometry` resolves them to one of the
/// plain actions based on where the cursor is inside the zone. Adapted from
/// the shape of Rectangle's `WindowAction` / `CompoundSnapArea` (MIT).
enum SnapAction: String, CaseIterable, Codable {
    case none
    case maximize
    case leftHalf, rightHalf, topHalf, bottomHalf
    case center
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case firstThird, centerThird, lastThird
    case firstTwoThirds, lastTwoThirds
    case leftTopBottomHalfCompound
    case rightTopBottomHalfCompound
    case bottomThirdsCompound

    var displayName: String {
        switch self {
        case .none: return "None"
        case .maximize: return "Maximize"
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .center: return "Center"
        case .topLeftQuarter: return "Top-Left Quarter"
        case .topRightQuarter: return "Top-Right Quarter"
        case .bottomLeftQuarter: return "Bottom-Left Quarter"
        case .bottomRightQuarter: return "Bottom-Right Quarter"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .leftTopBottomHalfCompound: return "Left Half (Top/Bottom Half Near Corners)"
        case .rightTopBottomHalfCompound: return "Right Half (Top/Bottom Half Near Corners)"
        case .bottomThirdsCompound: return "Thirds (Drag to Center for Two Thirds)"
        }
    }
}

typealias SnapMap = [SnapPosition: SnapAction]

/// Persists the drag-snapping zone map (Codable, UserDefaults-backed) and the
/// on/off switch. Lance's own Rectangle map ships as the default; Settings
/// lets anyone replace it.
final class SnapSettings: ObservableObject {
    static let shared = SnapSettings()

    private let defaults = UserDefaults.standard
    private let mapKey = "Halfwin.snapMap"
    private let enabledKey = "Halfwin.dragSnappingEnabled"

    /// Lance's landscape Rectangle map: top-left/top-right corners are the
    /// outer thirds, top edge maximizes, left/right edges are halves that
    /// become top/bottom half near their own corners, bottom corners are
    /// quarters, and the bottom edge is the thirds compound.
    static let lanceDefault: SnapMap = [
        .topLeft: .firstThird,
        .top: .maximize,
        .topRight: .lastThird,
        .left: .leftTopBottomHalfCompound,
        .right: .rightTopBottomHalfCompound,
        .bottomLeft: .bottomLeftQuarter,
        .bottom: .bottomThirdsCompound,
        .bottomRight: .bottomRightQuarter,
    ]

    @Published var map: SnapMap {
        didSet {
            guard let data = try? JSONEncoder().encode(map) else { return }
            defaults.set(data, forKey: mapKey)
        }
    }

    @Published var dragSnappingEnabled: Bool {
        didSet { defaults.set(dragSnappingEnabled, forKey: enabledKey) }
    }

    private init() {
        if let data = defaults.data(forKey: mapKey), let saved = try? JSONDecoder().decode(SnapMap.self, from: data) {
            map = saved
        } else {
            map = Self.lanceDefault
        }
        dragSnappingEnabled = defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    func action(for position: SnapPosition) -> SnapAction { map[position] ?? .none }

    func restoreLanceDefaults() { map = Self.lanceDefault }
}
