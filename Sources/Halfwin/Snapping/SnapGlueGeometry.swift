import Foundation
import CoreGraphics

enum SnapGlueGeometry {
    static func alignedFrame(_ handled: CGRect, with neighbor: CGRect, in usableFrame: CGRect,
                             tolerance: CGFloat) -> CGRect? {
        guard tolerance.isFinite, tolerance >= 0,
              handled.width > 0, handled.height > 0,
              neighbor.width > 0, neighbor.height > 0,
              usableFrame.width > 0, usableFrame.height > 0 else { return nil }

        let fullHeight = abs(handled.minY - usableFrame.minY) <= tolerance &&
            abs(handled.maxY - usableFrame.maxY) <= tolerance &&
            abs(neighbor.minY - usableFrame.minY) <= tolerance &&
            abs(neighbor.maxY - usableFrame.maxY) <= tolerance
        if fullHeight {
            if abs(handled.minX - neighbor.maxX) <= tolerance {
                var result = handled
                if handled.minX >= neighbor.maxX {
                    result.origin.x = neighbor.maxX
                } else {
                    result.origin.x = neighbor.maxX
                    result.size.width = handled.maxX - neighbor.maxX
                }
                return result.width > 0 ? result : nil
            }
            if abs(handled.maxX - neighbor.minX) <= tolerance {
                var result = handled
                if handled.maxX <= neighbor.minX {
                    result.origin.x += neighbor.minX - handled.maxX
                } else {
                    result.size.width = neighbor.minX - handled.minX
                }
                return result.width > 0 ? result : nil
            }
        }

        let fullWidth = abs(handled.minX - usableFrame.minX) <= tolerance &&
            abs(handled.maxX - usableFrame.maxX) <= tolerance &&
            abs(neighbor.minX - usableFrame.minX) <= tolerance &&
            abs(neighbor.maxX - usableFrame.maxX) <= tolerance
        if fullWidth {
            if abs(handled.minY - neighbor.maxY) <= tolerance {
                var result = handled
                if handled.minY >= neighbor.maxY {
                    result.origin.y = neighbor.maxY
                } else {
                    result.origin.y = neighbor.maxY
                    result.size.height = handled.maxY - neighbor.maxY
                }
                return result.height > 0 ? result : nil
            }
            if abs(handled.maxY - neighbor.minY) <= tolerance {
                var result = handled
                if handled.maxY <= neighbor.minY {
                    result.origin.y += neighbor.minY - handled.maxY
                } else {
                    result.size.height = neighbor.minY - handled.minY
                }
                return result.height > 0 ? result : nil
            }
        }
        return nil
    }
}
