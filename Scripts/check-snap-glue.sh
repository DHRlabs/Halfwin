#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cat > "$scratch/main.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let usable = CGRect(x: 0, y: 0, width: 1440, height: 900)
let left = CGRect(x: 0, y: 0, width: 700, height: 900)
let right = CGRect(x: 710, y: 0, width: 730, height: 900)
assert(SnapGlueGeometry.alignedFrame(right, with: left, in: usable, tolerance: 20) ==
       CGRect(x: 700, y: 0, width: 730, height: 900))

let top = CGRect(x: 0, y: 450, width: 1440, height: 450)
let bottom = CGRect(x: 0, y: 0, width: 1440, height: 440)
assert(SnapGlueGeometry.alignedFrame(bottom, with: top, in: usable, tolerance: 20) ==
       CGRect(x: 0, y: 10, width: 1440, height: 440))

let partial = CGRect(x: 710, y: 80, width: 730, height: 740)
assert(SnapGlueGeometry.alignedFrame(partial, with: left, in: usable, tolerance: 20) == nil)

print("Snap glue geometry assertions passed")
SWIFT

swiftc "$root/Sources/Halfwin/Snapping/SnapGlueGeometry.swift" "$scratch/main.swift" -o "$scratch/check-snap-glue"
"$scratch/check-snap-glue"
