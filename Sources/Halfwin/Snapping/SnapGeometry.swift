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

    static func matchesSnapSize(_ actual: CGRect, target: CGRect) -> Bool {
        abs(actual.width - target.width) <= edgeTolerance && abs(actual.height - target.height) <= edgeTolerance
    }

    static func matchesSnapEdges(_ actual: CGRect, target: CGRect, screenFrame: CGRect,
                                requireInnerEdges: Bool = false) -> Bool {
        let edges = [
            (target.minX, screenFrame.minX, actual.minX),
            (target.maxX, screenFrame.maxX, actual.maxX),
            (target.minY, screenFrame.minY, actual.minY),
            (target.maxY, screenFrame.maxY, actual.maxY),
        ].filter { abs($0.0 - $0.1) <= 1 }
        guard !edges.isEmpty else { return isClose(actual, target, tolerance: 8) }
        guard edges.allSatisfy({ abs($0.0 - $0.2) <= edgeTolerance }) else { return false }
        guard requireInnerEdges else { return true }
        let innerEdges = [
            (target.minX, screenFrame.minX, actual.minX),
            (target.maxX, screenFrame.maxX, actual.maxX),
            (target.minY, screenFrame.minY, actual.minY),
            (target.maxY, screenFrame.maxY, actual.maxY),
        ].filter { abs($0.0 - $0.1) > 1 }
        return innerEdges.allSatisfy { abs($0.0 - $0.2) <= edgeTolerance }
    }

    static func isHalf(_ action: SnapAction) -> Bool {
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains(action)
    }

    enum FillResult { case fixed, fill(CGRect) }
    static let minimumFillSize = CGSize(width: 200, height: 120)

    static func fillFrame(at point: CGPoint, position: SnapPosition, action: SnapAction,
                          fixedFrame: CGRect, visibleFrame: CGRect, snappedFrames: [CGRect],
                          previousFrame: CGRect? = nil,
                          pointIsRequired: Bool = true) -> FillResult {
        guard !snappedFrames.isEmpty else { return .fixed }
        guard isHalf(action) || snappedFrames.contains(where: { fixedFrame.intersects($0) }) else { return .fixed }
        let contact = projectedContact(point, position: position, in: visibleFrame)
        let obstacles = snappedFrames.filter { !containsClosed($0.standardized, contact) }
        var candidates = emptyFrames(visibleFrame: visibleFrame, snappedFrames: obstacles).filter {
            touches($0, position: position, visibleFrame: visibleFrame)
        }
        if pointIsRequired {
            candidates = candidates.filter { containsClosed($0, contact) }
        } else if !isCorner(position), !candidates.isEmpty {
            let nearest = candidates.map { contactDistance($0, to: contact, position: position) }.min()!
            candidates = candidates.filter { abs(contactDistance($0, to: contact, position: position) - nearest) < 0.001 }
        }
        guard let frame = preferred(candidates, position: position, visibleFrame: visibleFrame,
                                    previousFrame: previousFrame) else { return .fixed }
        return .fill(frame)
    }

    static func largestEmptyFrame(visibleFrame: CGRect, snappedFrames: [CGRect]) -> CGRect? {
        preferred(emptyFrames(visibleFrame: visibleFrame, snappedFrames: snappedFrames), position: nil, visibleFrame: visibleFrame,
                  previousFrame: nil)
    }

    private static func emptyFrames(visibleFrame: CGRect, snappedFrames: [CGRect]) -> [CGRect] {
        let obstacles = snappedFrames.compactMap { frame -> CGRect? in
            guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { return nil }
            let clipped = frame.standardized.intersection(visibleFrame)
            return clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? nil : clipped
        }
        guard !obstacles.isEmpty else { return [] }
        let xs = Set([visibleFrame.minX, visibleFrame.maxX] + obstacles.flatMap { [$0.minX, $0.maxX] }).sorted()
        guard xs.count > 1 else { return [] }
        var result: [CGRect] = []
        for leftIndex in 0..<(xs.count - 1) {
            for rightIndex in (leftIndex + 1)..<xs.count {
                let left = xs[leftIndex], right = xs[rightIndex]
                let intervals = obstacles.filter { $0.minX < right && $0.maxX > left }
                    .map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
                var merged: [(CGFloat, CGFloat)] = []
                for interval in intervals {
                    if let last = merged.indices.last, interval.0 <= merged[last].1 {
                        merged[last].1 = max(merged[last].1, interval.1)
                    } else {
                        merged.append(interval)
                    }
                }
                var bottom = visibleFrame.minY
                for interval in merged {
                    if interval.0 - bottom >= minimumFillSize.height, right - left >= minimumFillSize.width {
                        result.append(CGRect(x: left, y: bottom, width: right - left, height: interval.0 - bottom))
                    }
                    bottom = max(bottom, interval.1)
                }
                if visibleFrame.maxY - bottom >= minimumFillSize.height, right - left >= minimumFillSize.width {
                    result.append(CGRect(x: left, y: bottom, width: right - left, height: visibleFrame.maxY - bottom))
                }
            }
        }
        return result
    }

    private static func preferred(_ candidates: [CGRect], position: SnapPosition?, visibleFrame: CGRect,
                                  previousFrame: CGRect?) -> CGRect? {
        guard let largest = candidates.map({ $0.width * $0.height }).max() else { return nil }
        let tolerance = max(visibleFrame.width, visibleFrame.height)
        let tied = candidates.filter { largest - $0.width * $0.height <= tolerance }
        if let position, isCorner(position), let previousFrame,
           let previous = tied.first(where: { isClose($0, previousFrame, tolerance: 1) }) {
            return previous
        }
        return tied.min {
            if let position, !isCorner(position), contactLength($0, position: position) != contactLength($1, position: position) {
                return contactLength($0, position: position) > contactLength($1, position: position)
            }
            if position.map(isCorner) == true, $0.width != $1.width { return $0.width > $1.width }
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.maxY != $1.maxY { return $0.maxY > $1.maxY }
            return false
        }
    }

    private static func projectedContact(_ point: CGPoint, position: SnapPosition, in frame: CGRect) -> CGPoint {
        let x = min(max(point.x, frame.minX), frame.maxX)
        let y = min(max(point.y, frame.minY), frame.maxY)
        switch position {
        case .left: return CGPoint(x: frame.minX, y: y)
        case .right: return CGPoint(x: frame.maxX, y: y)
        case .top: return CGPoint(x: x, y: frame.maxY)
        case .bottom: return CGPoint(x: x, y: frame.minY)
        case .topLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.minY)
        }
    }

    private static func touches(_ candidate: CGRect, position: SnapPosition, visibleFrame: CGRect) -> Bool {
        let tolerance: CGFloat = 0.001
        switch position {
        case .left: return abs(candidate.minX - visibleFrame.minX) < tolerance
        case .right: return abs(candidate.maxX - visibleFrame.maxX) < tolerance
        case .top: return abs(candidate.maxY - visibleFrame.maxY) < tolerance
        case .bottom: return abs(candidate.minY - visibleFrame.minY) < tolerance
        case .topLeft: return abs(candidate.minX - visibleFrame.minX) < tolerance && abs(candidate.maxY - visibleFrame.maxY) < tolerance
        case .topRight: return abs(candidate.maxX - visibleFrame.maxX) < tolerance && abs(candidate.maxY - visibleFrame.maxY) < tolerance
        case .bottomLeft: return abs(candidate.minX - visibleFrame.minX) < tolerance && abs(candidate.minY - visibleFrame.minY) < tolerance
        case .bottomRight: return abs(candidate.maxX - visibleFrame.maxX) < tolerance && abs(candidate.minY - visibleFrame.minY) < tolerance
        }
    }

    private static func containsClosed(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    private static func contactDistance(_ frame: CGRect, to point: CGPoint, position: SnapPosition) -> CGFloat {
        let interval: ClosedRange<CGFloat> = [.left, .right].contains(position) ? frame.minY...frame.maxY : frame.minX...frame.maxX
        let value = [.left, .right].contains(position) ? point.y : point.x
        return value < interval.lowerBound ? interval.lowerBound - value : max(0, value - interval.upperBound)
    }

    private static func contactLength(_ frame: CGRect, position: SnapPosition) -> CGFloat {
        [.left, .right].contains(position) ? frame.height : frame.width
    }

    private static func isCorner(_ position: SnapPosition) -> Bool {
        [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(position)
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
        case .none, .leftTopBottomHalfCompound, .rightTopBottomHalfCompound, .bottomThirdsCompound, .fill:
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
