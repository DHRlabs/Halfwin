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
    case commandCenterLeft, commandCenter, commandCenterRight
    case firstTwoThirds, lastTwoThirds
    case lastThirdTop, lastThirdBottom
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
        case .commandCenterLeft: return "Command Center Left"
        case .commandCenter: return "Command Center"
        case .commandCenterRight: return "Command Center Right"
        case .firstTwoThirds: return "First Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .lastThirdTop: return "Last Third Top Half"
        case .lastThirdBottom: return "Last Third Bottom Half"
        case .leftTopBottomHalfCompound: return "Left Half (Top/Bottom Half Near Corners)"
        case .rightTopBottomHalfCompound: return "Right Half (Top/Bottom Half Near Corners)"
        case .bottomThirdsCompound: return "Thirds (Drag to Center for Two Thirds)"
        }
    }
}

typealias SnapMap = [SnapPosition: SnapAction]

struct SnapLayoutZone {
    let action: SnapAction
    let rect: CGRect
}

/// Shared ordered zones for menu tiles, snap memory, and Snap Assist.
enum SnapMultiWindowLayout: CaseIterable, Equatable {
    case halves, leftStack, thirds, commandCenter

    var title: String {
        switch self {
        case .halves: return "Halves"
        case .thirds: return "Thirds"
        case .leftStack: return "Left + Stack"
        case .commandCenter: return "Command Center"
        }
    }

    var zones: [SnapLayoutZone] {
        switch self {
        case .halves:
            return [
                SnapLayoutZone(action: .leftHalf, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
                SnapLayoutZone(action: .rightHalf, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
            ]
        case .thirds:
            return [
                SnapLayoutZone(action: .firstThird, rect: CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)),
                SnapLayoutZone(action: .centerThird, rect: CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)),
                SnapLayoutZone(action: .lastThird, rect: CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)),
            ]
        case .leftStack:
            return [
                SnapLayoutZone(action: .firstTwoThirds, rect: CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)),
                SnapLayoutZone(action: .lastThirdTop, rect: CGRect(x: 2.0 / 3, y: 0.5, width: 1.0 / 3, height: 0.5)),
                SnapLayoutZone(action: .lastThirdBottom, rect: CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 0.5)),
            ]
        case .commandCenter:
            let side = SnapGeometry.commandCenterSideFraction
            return [
                SnapLayoutZone(action: .commandCenterLeft, rect: CGRect(x: 0, y: 0, width: side, height: 1)),
                SnapLayoutZone(action: .commandCenter, rect: CGRect(x: side, y: 0, width: 1 - 2 * side, height: 1)),
                SnapLayoutZone(action: .commandCenterRight, rect: CGRect(x: 1 - side, y: 0, width: side, height: 1)),
            ]
        }
    }

    static func containing(_ action: SnapAction) -> Self? {
        allCases.first { $0.zones.contains { $0.action == action } }
    }
}

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
