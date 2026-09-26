import Foundation
import CoreGraphics

/// Zone detection and target-frame math. All in AppKit screen coordinates
/// (origin bottom-left), the same space as `NSScreen.frame`/`.visibleFrame`
/// and `NSEvent.mouseLocation`. Adapted from Rectangle's
/// `SnappingManager.directionalLocationOfCursor` and its `WindowCalculation`
/// classes (MIT), collapsed into plain frame math since this port only needs
/// the handful of layouts below.
enum SnapGeometry {
    private static let commandCenterSideFractionKey = "Halfwin.commandCenterSideFraction"
    static let defaultCommandCenterSideFraction: CGFloat = 0.25

    static var commandCenterSideFraction: CGFloat {
        get {
            let saved = UserDefaults.standard.object(forKey: commandCenterSideFractionKey) as? Double
                ?? Double(defaultCommandCenterSideFraction)
            let value = saved.isFinite ? CGFloat(saved) : defaultCommandCenterSideFraction
            return min(max(value, 0.15), 0.35)
        }
        set {
            let value = newValue.isFinite ? newValue : defaultCommandCenterSideFraction
            UserDefaults.standard.set(Double(min(max(value, 0.15), 0.35)), forKey: commandCenterSideFractionKey)
        }
    }

    /// Rectangle's per-edge margin and corner size, per the goal: 5pt edges,
    /// 20pt corners, checked against the display's full frame (so the menu
    /// bar strip still counts as the top edge).
    static let edgeMargin: CGFloat = 5
    static let cornerSize: CGFloat = 20
    static let edgeTolerance: CGFloat = 20

    /// Halves-compound threshold: within this distance of a top/bottom
    /// corner, the left/right edge acts like the top/bottom half instead.
    static let compoundCornerDistance: CGFloat = 145

    static func position(for cursor: CGPoint, in screenFrame: CGRect) -> SnapPosition? {
        guard cursor.x >= screenFrame.minX, cursor.x <= screenFrame.maxX,
              cursor.y >= screenFrame.minY, cursor.y <= screenFrame.maxY else { return nil }

        let left = screenFrame.minX + edgeMargin + cornerSize
        let right = screenFrame.maxX - edgeMargin - cornerSize
        let top = screenFrame.maxY - edgeMargin - cornerSize
        let bottom = screenFrame.minY + edgeMargin + cornerSize

        if cursor.x < left {
            if cursor.y >= top { return .topLeft }
            if cursor.y <= bottom { return .bottomLeft }
            if cursor.x < screenFrame.minX + edgeMargin { return .left }
        }
        if cursor.x > right {
            if cursor.y >= top { return .topRight }
            if cursor.y <= bottom { return .bottomRight }
            if cursor.x > screenFrame.maxX - edgeMargin { return .right }
        }
        if cursor.y > screenFrame.maxY - edgeMargin { return .top }
        if cursor.y < screenFrame.minY + edgeMargin { return .bottom }
        return nil
    }

    enum Side { case left, right }

    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func isHalf(_ action: SnapAction) -> Bool {
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains(action)
    }

    /// Extends a half into the space beside a snapped pane. Layout zones keep
    /// their authored frames; only edge half actions reach this calculation.
    static func fillFrame(for action: SnapAction, fixedFrame: CGRect, visibleFrame: CGRect,
                          snappedFrames: [CGRect]) -> CGRect? {
        guard isHalf(action), fixedFrame.width > 0, fixedFrame.height > 0 else { return nil }
        let tolerance = edgeTolerance
        let spansHeight = fixedFrame.minY <= visibleFrame.minY + tolerance &&
            fixedFrame.maxY >= visibleFrame.maxY - tolerance
        let spansWidth = fixedFrame.minX <= visibleFrame.minX + tolerance &&
            fixedFrame.maxX >= visibleFrame.maxX - tolerance

        switch action {
        case .leftHalf where spansHeight && abs(fixedFrame.minX - visibleFrame.minX) <= tolerance:
            let candidates = snappedFrames.filter {
                abs($0.maxX - visibleFrame.maxX) <= tolerance && $0.minX > visibleFrame.minX + 1
            }
            for edge in Set(candidates.map(\.minX)).sorted() {
                let ranges = candidates.filter { abs($0.minX - edge) <= tolerance }.map { $0.minY...$0.maxY }
                if covers(ranges, from: visibleFrame.minY, to: visibleFrame.maxY, tolerance: tolerance) {
                    return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                                  width: edge - visibleFrame.minX, height: visibleFrame.height)
                }
            }
        case .rightHalf where spansHeight && abs(fixedFrame.maxX - visibleFrame.maxX) <= tolerance:
            let candidates = snappedFrames.filter {
                abs($0.minX - visibleFrame.minX) <= tolerance && $0.maxX < visibleFrame.maxX - 1
            }
            for edge in Set(candidates.map(\.maxX)).sorted(by: >) {
                let ranges = candidates.filter { abs($0.maxX - edge) <= tolerance }.map { $0.minY...$0.maxY }
                if covers(ranges, from: visibleFrame.minY, to: visibleFrame.maxY, tolerance: tolerance) {
                    return CGRect(x: edge, y: visibleFrame.minY,
                                  width: visibleFrame.maxX - edge, height: visibleFrame.height)
                }
            }
        case .topHalf where spansWidth && abs(fixedFrame.maxY - visibleFrame.maxY) <= tolerance:
            let candidates = snappedFrames.filter {
                abs($0.minY - visibleFrame.minY) <= tolerance && $0.maxY < visibleFrame.maxY - 1
            }
            for edge in Set(candidates.map(\.maxY)).sorted(by: >) {
                let ranges = candidates.filter { abs($0.maxY - edge) <= tolerance }.map { $0.minX...$0.maxX }
                if covers(ranges, from: visibleFrame.minX, to: visibleFrame.maxX, tolerance: tolerance) {
                    return CGRect(x: visibleFrame.minX, y: edge, width: visibleFrame.width,
                                  height: visibleFrame.maxY - edge)
                }
            }
        case .bottomHalf where spansWidth && abs(fixedFrame.minY - visibleFrame.minY) <= tolerance:
            let candidates = snappedFrames.filter {
                abs($0.maxY - visibleFrame.maxY) <= tolerance && $0.minY > visibleFrame.minY + 1
            }
            for edge in Set(candidates.map(\.minY)).sorted() {
                let ranges = candidates.filter { abs($0.minY - edge) <= tolerance }.map { $0.minX...$0.maxX }
                if covers(ranges, from: visibleFrame.minX, to: visibleFrame.maxX, tolerance: tolerance) {
                    return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                                  width: visibleFrame.width, height: edge - visibleFrame.minY)
                }
            }
        default:
            break
        }
        return nil
    }

    private static func covers(_ ranges: [ClosedRange<CGFloat>], from lower: CGFloat, to upper: CGFloat,
                               tolerance: CGFloat) -> Bool {
        var edge = lower
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound <= edge + tolerance else { return false }
            edge = max(edge, range.upperBound)
            if edge >= upper - tolerance { return true }
        }
        return false
    }

    /// Rectangle's `leftTopBottomHalf`/`rightTopBottomHalf` compound: near a
    /// top or bottom corner the edge acts like that half instead.
    static func resolveHalfCompound(side: Side, cursor: CGPoint, screenFrame: CGRect) -> SnapAction {
        if cursor.y >= screenFrame.maxY - compoundCornerDistance { return .topHalf }
        if cursor.y <= screenFrame.minY + compoundCornerDistance { return .bottomHalf }
        return side == .left ? .leftHalf : .rightHalf
    }

    /// Rectangle's bottom-edge thirds compound: outer thirds snap directly;
    /// the middle third resolves to a plain center third, unless the cursor
    /// arrived there from a first/last third or two-thirds zone in the same
    /// drag, in which case it expands to two-thirds.
    static func resolveBottomThirdsCompound(cursor: CGPoint, screenFrame: CGRect, previous: SnapAction?) -> SnapAction {
        let thirdWidth = floor(screenFrame.width / 3)
        if cursor.x <= screenFrame.minX + thirdWidth { return .firstThird }
        if cursor.x >= screenFrame.maxX - thirdWidth { return .lastThird }
        switch previous {
        case .firstThird, .firstTwoThirds: return .firstTwoThirds
        case .lastThird, .lastTwoThirds: return .lastTwoThirds
        default: return .centerThird
        }
    }

    /// Rectangle's portrait defaults (`SnapAreaModel.defaultPortrait` plus
    /// `PortraitSideThirdsCompoundCalculation`), for any portrait display:
    /// corners are quarters, top maximizes, the bottom edge is a left/right
    /// half split, and the side edges are a vertical thirds compound.
    static func portraitAction(for position: SnapPosition, cursor: CGPoint, screenFrame: CGRect, previous: SnapAction?) -> SnapAction {
        switch position {
        case .topLeft: return .topLeftQuarter
        case .top: return .maximize
        case .topRight: return .topRightQuarter
        case .bottomLeft: return .bottomLeftQuarter
        case .bottomRight: return .bottomRightQuarter
        case .bottom: return cursor.x < screenFrame.midX ? .leftHalf : .rightHalf
        case .left, .right:
            let thirdHeight = floor(screenFrame.height / 3)
            if cursor.y >= screenFrame.maxY - thirdHeight { return .firstThird }
            if cursor.y <= screenFrame.minY + thirdHeight { return .lastThird }
            switch previous {
            case .firstThird, .firstTwoThirds: return .firstTwoThirds
            case .lastThird, .lastTwoThirds: return .lastTwoThirds
            default: return .centerThird
            }
        }
    }

    /// The frame a plain (non-compound) action produces. `firstThird`,
    /// `lastThird`, `centerThird` and the two-thirds pair are orientation
    /// aware, the way Rectangle's `OrientationAware` calculations are:
    /// landscape splits columns, portrait splits rows.
    static func frame(for action: SnapAction, visibleFrame vf: CGRect, currentWindowFrame: CGRect, portrait: Bool) -> CGRect? {
        let halfWidth = floor(vf.width / 2)
        let halfHeight = floor(vf.height / 2)
        switch action {
        case .none, .leftTopBottomHalfCompound, .rightTopBottomHalfCompound, .bottomThirdsCompound:
            return nil
        case .maximize:
            return vf
        case .leftHalf:
            return CGRect(x: vf.minX, y: vf.minY, width: halfWidth, height: vf.height)
        case .rightHalf:
            return CGRect(x: vf.maxX - halfWidth, y: vf.minY, width: halfWidth, height: vf.height)
        case .topHalf:
            return CGRect(x: vf.minX, y: vf.maxY - halfHeight, width: vf.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: halfHeight)
        case .center:
            var size = currentWindowFrame.size
            size.width = min(size.width, vf.width)
            size.height = min(size.height, vf.height)
            let origin = CGPoint(x: vf.minX + round((vf.width - size.width) / 2),
                                 y: vf.minY + round((vf.height - size.height) / 2))
            return CGRect(origin: origin, size: size)
        case .topLeftQuarter:
            return CGRect(x: vf.minX, y: vf.maxY - halfHeight, width: halfWidth, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: vf.maxX - halfWidth, y: vf.maxY - halfHeight, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: vf.minX, y: vf.minY, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: vf.maxX - halfWidth, y: vf.minY, width: halfWidth, height: halfHeight)
        case .firstThird:
            if portrait {
                let h = floor(vf.height / 3)
                return CGRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h)
            }
            let w = floor(vf.width / 3)
            return CGRect(x: vf.minX, y: vf.minY, width: w, height: vf.height)
        case .lastThird:
            if portrait {
                let h = floor(vf.height / 3)
                return CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: h)
            }
            let w = floor(vf.width / 3)
            return CGRect(x: vf.maxX - w, y: vf.minY, width: w, height: vf.height)
        case .centerThird:
            if portrait {
                let h = floor(vf.height / 3)
                return CGRect(x: vf.minX, y: vf.minY + h, width: vf.width, height: h)
            }
            let w = floor(vf.width / 3)
            return CGRect(x: vf.minX + w, y: vf.minY, width: w, height: vf.height)
        case .commandCenterLeft, .commandCenter, .commandCenterRight:
            let sideFraction = commandCenterSideFraction
            if portrait {
                let sideHeight = floor(vf.height * sideFraction)
                let centerHeight = vf.height - 2 * sideHeight
                switch action {
                case .commandCenterLeft:
                    return CGRect(x: vf.minX, y: vf.maxY - sideHeight, width: vf.width, height: sideHeight)
                case .commandCenter:
                    return CGRect(x: vf.minX, y: vf.minY + sideHeight, width: vf.width, height: centerHeight)
                case .commandCenterRight:
                    return CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: sideHeight)
                default:
                    return nil
                }
            }
            let sideWidth = floor(vf.width * sideFraction)
            let centerWidth = vf.width - 2 * sideWidth
            switch action {
            case .commandCenterLeft:
                return CGRect(x: vf.minX, y: vf.minY, width: sideWidth, height: vf.height)
            case .commandCenter:
                return CGRect(x: vf.minX + sideWidth, y: vf.minY, width: centerWidth, height: vf.height)
            case .commandCenterRight:
                return CGRect(x: vf.maxX - sideWidth, y: vf.minY, width: sideWidth, height: vf.height)
            default:
                return nil
            }
        case .firstTwoThirds:
            if portrait {
                let h = floor(vf.height * 2 / 3)
                return CGRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h)
            }
            let w = floor(vf.width * 2 / 3)
            return CGRect(x: vf.minX, y: vf.minY, width: w, height: vf.height)
        case .lastTwoThirds:
            if portrait {
                let h = floor(vf.height * 2 / 3)
                return CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: h)
            }
            let w = floor(vf.width * 2 / 3)
            return CGRect(x: vf.maxX - w, y: vf.minY, width: w, height: vf.height)
        case .lastThirdTop:
            if portrait {
                let h = floor(vf.height / 3)
                let halfW = floor(vf.width / 2)
                return CGRect(x: vf.minX, y: vf.minY, width: halfW, height: h)
            }
            let w = floor(vf.width / 3)
            let halfH = floor(vf.height / 2)
            return CGRect(x: vf.maxX - w, y: vf.maxY - halfH, width: w, height: halfH)
        case .lastThirdBottom:
            if portrait {
                let h = floor(vf.height / 3)
                let halfW = floor(vf.width / 2)
                return CGRect(x: vf.maxX - halfW, y: vf.minY, width: halfW, height: h)
            }
            let w = floor(vf.width / 3)
            let halfH = floor(vf.height / 2)
            return CGRect(x: vf.maxX - w, y: vf.minY, width: w, height: halfH)
        }
    }
}
