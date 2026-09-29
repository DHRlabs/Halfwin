#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cat > "$scratch/main.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let usable = CGRect(x: 0, y: 0, width: 1440, height: 900)
let leftHalf = CGRect(x: 0, y: 0, width: 720, height: 900)
let rightHalf = CGRect(x: 720, y: 0, width: 720, height: 900)
let tolerance: CGFloat = 20

assert(SnapJoinGeometry.canAdopt(incoming: rightHalf, candidate: leftHalf, isExposed: true,
                                 matchesSnapZone: true, tolerance: tolerance))
assert(!SnapJoinGeometry.canAdopt(incoming: rightHalf, candidate: leftHalf, isExposed: false,
                                  matchesSnapZone: true, tolerance: tolerance))
assert(!SnapJoinGeometry.canAdopt(incoming: rightHalf, candidate: leftHalf, isExposed: true,
                                  matchesSnapZone: false, tolerance: tolerance))
let floating = CGRect(x: 450, y: 200, width: 300, height: 300)
assert(!SnapJoinGeometry.canAdopt(incoming: rightHalf, candidate: floating, isExposed: true,
                                  matchesSnapZone: false, tolerance: tolerance))

let firstTwoThirds = CGRect(x: 0, y: 0, width: 960, height: 900)
let lastThirdTop = CGRect(x: 960, y: 450, width: 480, height: 450)
assert(SnapJoinGeometry.canAdopt(incoming: lastThirdTop, candidate: firstTwoThirds, isExposed: true,
                                 matchesSnapZone: true, tolerance: tolerance))

let halvesVisible: (CGPoint) -> Int? = { point in
    leftHalf.contains(point) ? 1 : rightHalf.contains(point) ? 2 : nil
}
assert(SnapJoinGeometry.hasVisiblePartner(incomingID: 2, partnerID: 1,
                                           incoming: rightHalf, partner: leftHalf, incomingOnLow: false,
                                           vertical: true, coordinate: 720, visibleRanges: [0...900],
                                           tolerance: tolerance, frontmostAt: halvesVisible))
assert(!SnapJoinGeometry.hasVisiblePartner(incomingID: 2, partnerID: 1,
                                           incoming: rightHalf, partner: leftHalf, incomingOnLow: false,
                                           vertical: true, coordinate: 720, visibleRanges: [],
                                           tolerance: tolerance, frontmostAt: halvesVisible))

let exposedLowerRight = CGRect(x: 720, y: 0, width: 720, height: 300)
let incomingUpperRight = CGRect(x: 720, y: 450, width: 720, height: 450)
let visibleOnlyBelow: (CGPoint) -> Int? = { point in
    leftHalf.contains(point) ? 1 : exposedLowerRight.contains(point) ? 3 : incomingUpperRight.contains(point) ? 2 : nil
}
assert(!SnapJoinGeometry.hasVisiblePartner(incomingID: 2, partnerID: 1,
                                           incoming: incomingUpperRight, partner: leftHalf, incomingOnLow: false,
                                           vertical: true, coordinate: 720, visibleRanges: [0...300],
                                           tolerance: tolerance, frontmostAt: visibleOnlyBelow))

let blocker = CGRect(x: 720, y: 450, width: 10, height: 450)
let coveredAtSeam: (CGPoint) -> Int? = { point in
    blocker.contains(point) ? 9 : halvesVisible(point)
}
assert(!SnapJoinGeometry.hasVisiblePartner(incomingID: 2, partnerID: 1,
                                           incoming: rightHalf, partner: leftHalf, incomingOnLow: false,
                                           vertical: true, coordinate: 720, visibleRanges: [0...900],
                                           tolerance: tolerance, frontmostAt: coveredAtSeam))

let smallBlocker = CGRect(x: 720, y: 445, width: 10, height: 10)
let visibleAroundSmallBlocker: (CGPoint) -> Int? = { point in
    smallBlocker.contains(point) ? 9 : halvesVisible(point)
}
assert(!SnapJoinGeometry.hasVisiblePartner(incomingID: 2, partnerID: 1,
                                           incoming: rightHalf, partner: leftHalf, incomingOnLow: false,
                                           vertical: true, coordinate: 720, visibleRanges: [0...900],
                                           tolerance: tolerance, frontmostAt: visibleAroundSmallBlocker))
assert(SnapJoinGeometry.hasVisiblePartner(incomingID: 2, partnerID: 1,
                                           incoming: rightHalf, partner: leftHalf, incomingOnLow: false,
                                           vertical: true, coordinate: 720, visibleRanges: [0...445, 455...900],
                                           tolerance: tolerance, frontmostAt: visibleAroundSmallBlocker))

let resizedFill = CGRect(x: 720, y: 0, width: 720, height: 300)
let resizedFillVisible: (CGPoint) -> Int? = { point in
    leftHalf.contains(point) ? 1 : resizedFill.contains(point) ? 4 : nil
}
assert(SnapJoinGeometry.hasVisiblePartner(incomingID: 4, partnerID: 1,
                                           incoming: resizedFill, partner: leftHalf, incomingOnLow: false,
                                           vertical: true, coordinate: 720, visibleRanges: [0...300],
                                           tolerance: tolerance, frontmostAt: resizedFillVisible))

print("Snap Assist join assertions passed")
SWIFT

swiftc "$root/Sources/Halfwin/Snapping/SnapJoinGeometry.swift" "$scratch/main.swift" -o "$scratch/check-snap-assist-join"
"$scratch/check-snap-assist-join"
