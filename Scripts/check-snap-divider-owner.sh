#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

{
    cat <<'SWIFT'
import CoreGraphics
import Foundation

enum SnapSeamAxis { case vertical, horizontal }
enum SnapSeamSide { case low, high }

final class ResizeOwnerFixture {
    typealias Axis = SnapSeamAxis
    typealias Side = SnapSeamSide
SWIFT
    awk '
        /^    private func validEdgeResize/ { capture = 1 }
        /^    private func resize\(/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$root/Sources/Halfwin/Snapping/SnapDivider.swift"
    cat <<'SWIFT'
    func select(oldFrames: [CGRect], liveFrames: [CGRect?], lowCount: Int,
                preferredIndex: Int?, axis: Axis) -> Int? {
        nativeResizeOwnerIndex(oldFrames: oldFrames, liveFrames: liveFrames, lowCount: lowCount,
                               preferredIndex: preferredIndex, axis: axis)
    }
}

let lowBefore = CGRect(x: 0, y: 0, width: 1000, height: 673)
let highBefore = CGRect(x: 0, y: 673, width: 1000, height: 227)
let lowAfter = CGRect(x: 0, y: 0, width: 1000, height: 525)
let unchangedHigh = highBefore
let fixture = ResizeOwnerFixture()

assert(fixture.select(oldFrames: [lowBefore, highBefore], liveFrames: [lowAfter, unchangedHigh],
                     lowCount: 1, preferredIndex: 1, axis: .horizontal) == 0)
assert(fixture.select(oldFrames: [lowBefore, highBefore], liveFrames: [lowBefore, highBefore],
                     lowCount: 1, preferredIndex: 1, axis: .horizontal) == nil)

let highAfter = CGRect(x: 0, y: 821, width: 1000, height: 79)
assert(fixture.select(oldFrames: [lowBefore, highBefore], liveFrames: [lowAfter, highAfter],
                     lowCount: 1, preferredIndex: 0, axis: .horizontal) == 0)

let titlebarMoved = CGRect(x: 0, y: 10, width: 1000, height: 673)
assert(fixture.select(oldFrames: [lowBefore, highBefore], liveFrames: [titlebarMoved, unchangedHigh],
                     lowCount: 1, preferredIndex: 1, axis: .horizontal) == nil)

let diagonal = CGRect(x: 20, y: 0, width: 980, height: 525)
assert(fixture.select(oldFrames: [lowBefore, highBefore], liveFrames: [diagonal, unchangedHigh],
                     lowCount: 1, preferredIndex: 1, axis: .horizontal) == nil)

print("Snap divider native owner assertions passed")
SWIFT
} > "$scratch/main.swift"

swiftc "$scratch/main.swift" -o "$scratch/check-snap-divider-owner"
"$scratch/check-snap-divider-owner"
