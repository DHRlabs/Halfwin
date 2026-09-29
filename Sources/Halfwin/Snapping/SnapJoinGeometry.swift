import CoreGraphics

enum SnapJoinGeometry {
    static let minimumSeamOverlap: CGFloat = 20

    static func canAdopt(incoming: CGRect, candidate: CGRect, isExposed: Bool,
                         matchesSnapZone: Bool, tolerance: CGFloat) -> Bool {
        guard isExposed, matchesSnapZone, tolerance >= 0,
              incoming.width > 0, incoming.height > 0,
              candidate.width > 0, candidate.height > 0 else { return false }

        let verticalOverlap = min(incoming.maxY, candidate.maxY) - max(incoming.minY, candidate.minY)
        let horizontalOverlap = min(incoming.maxX, candidate.maxX) - max(incoming.minX, candidate.minX)
        return (verticalOverlap > minimumSeamOverlap &&
                (abs(incoming.maxX - candidate.minX) <= tolerance ||
                 abs(candidate.maxX - incoming.minX) <= tolerance)) ||
            (horizontalOverlap > minimumSeamOverlap &&
             (abs(incoming.maxY - candidate.minY) <= tolerance ||
              abs(candidate.maxY - incoming.minY) <= tolerance))
    }

    static func hasVisiblePartner<ID: Equatable>(incomingID: ID, partnerID: ID,
                                                  incoming: CGRect, partner: CGRect,
                                                  incomingOnLow: Bool, vertical: Bool,
                                                  coordinate: CGFloat, visibleRange: ClosedRange<CGFloat>,
                                                  tolerance: CGFloat,
                                                  frontmostAt: (CGPoint) -> ID?) -> Bool {
        guard incomingID != partnerID,
              abs((vertical
                   ? (incomingOnLow ? incoming.maxX : incoming.minX)
                   : (incomingOnLow ? incoming.maxY : incoming.minY)) - coordinate) <= tolerance,
              abs((vertical
                   ? (incomingOnLow ? partner.minX : partner.maxX)
                   : (incomingOnLow ? partner.minY : partner.maxY)) - coordinate) <= tolerance else { return false }

        let lower = max(visibleRange.lowerBound,
                        vertical ? max(incoming.minY, partner.minY) : max(incoming.minX, partner.minX))
        let upper = min(visibleRange.upperBound,
                        vertical ? min(incoming.maxY, partner.maxY) : min(incoming.maxX, partner.maxX))
        guard upper - lower > 1 else { return false }
        let along = (lower + upper) / 2
        let incomingPoint: CGPoint
        let partnerPoint: CGPoint
        if vertical {
            incomingPoint = CGPoint(x: incomingOnLow ? incoming.maxX - 1 : incoming.minX + 1, y: along)
            partnerPoint = CGPoint(x: incomingOnLow ? partner.minX + 1 : partner.maxX - 1, y: along)
        } else {
            incomingPoint = CGPoint(x: along, y: incomingOnLow ? incoming.maxY - 1 : incoming.minY + 1)
            partnerPoint = CGPoint(x: along, y: incomingOnLow ? partner.minY + 1 : partner.maxY - 1)
        }
        return frontmostAt(incomingPoint) == incomingID && frontmostAt(partnerPoint) == partnerID
    }
}
