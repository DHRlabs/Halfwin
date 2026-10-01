#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_file="${1:-$root/Sources/Halfwin/Snapping/SnapManager.swift}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

{
    cat <<'SWIFT'
import CoreGraphics
import Foundation
import os

SWIFT
    awk '/^enum SnapPosition/ { capture = 1 } /^typealias SnapMap/ { capture = 0 } capture { print }' \
        "$root/Sources/Halfwin/Snapping/SnapModel.swift"
    cat <<'SWIFT'

enum LayoutPreset: Equatable { case leftHalf, rightHalf, center, restore, maximize }
enum SnapMultiWindowLayout: Equatable { case fixture }
enum LayoutDropZone: Equatable {
    case preset(LayoutPreset)
    case layout(SnapMultiWindowLayout, SnapAction)
}

final class NSScreen: Equatable {
    static var screens: [NSScreen] = []
    let frame: CGRect
    let visibleFrame: CGRect
    init(frame: CGRect, visibleFrame: CGRect) { self.frame = frame; self.visibleFrame = visibleFrame }
    static func == (lhs: NSScreen, rhs: NSScreen) -> Bool { lhs === rhs }
}

func NSMouseInRect(_ point: CGPoint, _ rect: CGRect, _ flipped: Bool) -> Bool { rect.contains(point) }
extension CGRect { var isPortrait: Bool { height > width } }

struct AXUIElement: Hashable { let id: Int }
func CFHash(_ element: AXUIElement) -> CFHashCode { CFHashCode(element.id) }

final class WindowState {
    var frame: CGRect?
    var writes: [CGRect] = []
    init(frame: CGRect) { self.frame = frame }
}

struct AXWindow: Hashable {
    let element: AXUIElement
    let state: WindowState
    var processIdentifier: pid_t? { 4242 }
    var frame: CGRect? { state.frame }
    func setFrame(_ frame: CGRect) { state.writes.append(frame); state.frame = frame }
    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool { lhs.element == rhs.element }
    func hash(into hasher: inout Hasher) { hasher.combine(element) }
}

final class SnapSettings {
    var dragSnappingEnabled = true
    var glueTouchingWindowsEnabled = false
    var fillAvailableSpace = false
    var sideEdgesSnapToTopBottomHalf = false
    func action(for position: SnapPosition) -> SnapAction { .leftHalf }
}

final class LayoutMenuManager {
    var isDropBarVisible = false
    var hotZoneWidth: CGFloat = 400
    func showDropBar(on screen: NSScreen, for window: AXWindow, startFrame: CGRect) {}
    func dropZone(at point: CGPoint) -> LayoutDropZone? { nil }
    func highlight(_ zone: LayoutDropZone?) {}
    func dropPreviewFrame(for zone: LayoutDropZone, currentWindowFrame: CGRect) -> CGRect? { nil }
    func isDropBarNear(_ point: CGPoint) -> Bool { false }
    func applyDrop(_ zone: LayoutDropZone) -> CGRect? { nil }
    func hideDropBar() { isDropBarVisible = false }
}

final class SnapWindowRegistry {
    static let shared = SnapWindowRegistry()
    func validate() {}
    func validateIfNeeded(interval: TimeInterval) {}
    func fillNeighborFrames(on screen: NSScreen, excluding: AXWindow) -> [CGRect] { [] }
    func unsnap(_ window: AXWindow) {}
}

final class FootprintWindow {
    func hide() {}
    func show(in frame: CGRect) {}
}

enum NSEvent { static var mouseLocation = CGPoint.zero }
enum SnapEvents {
    static func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen, frame: CGRect) {}
}

final class SnapManager {
    struct Zone {
        let screen: NSScreen
        let position: SnapPosition
        let action: SnapAction
        var effectiveAction: SnapAction
        var frame: CGRect
        let cursor: CGPoint
    }

    let settings = SnapSettings()
    let layoutMenu = LayoutMenuManager()
    let diagLogger = Logger(subsystem: "release-target-check", category: "test")
    let footprint = FootprintWindow()
    var draggedWindow: AXWindow?
    var initialFrame: CGRect?
    var lockedSize: CGSize?
    var isWindowMoving = false
    var didReceiveDrag = false
    var cancelled = false
    var currentZone: Zone?
    var currentPreviewFrame: CGRect?
    var dragToTopLayoutsEnabled = false
    var dropScreen: NSScreen?
    var currentDropZone: LayoutDropZone?
    var preSnapSizes: [AXWindow: CGSize] = [:]

    func layoutTriggerScreen(for cursor: CGPoint) -> NSScreen? { nil }
    func clearDropBar() { layoutMenu.hideDropBar(); dropScreen = nil; currentDropZone = nil }
    func hidePreview() { currentPreviewFrame = nil; footprint.hide() }
    func showPreview(_ frame: CGRect) { currentPreviewFrame = frame; footprint.show(in: frame) }
    func resetDrag() {
        clearDropBar(); draggedWindow = nil; initialFrame = nil
        isWindowMoving = false; didReceiveDrag = false; cancelled = false
        currentZone = nil; currentPreviewFrame = nil
    }
    func scheduleReleaseSnapshots(for window: AXWindow, releasedAt: TimeInterval) {}
    func glue(_ window: AXWindow, to frame: CGRect) {}

    func configure(window: AXWindow, initial: CGRect, cachedZone: Zone?) {
        draggedWindow = window
        initialFrame = initial
        lockedSize = initial.size
        isWindowMoving = true
        didReceiveDrag = true
        currentZone = cachedZone
        currentDropZone = nil
    }

SWIFT
    awk '
        /^    private func updateTarget\(at cursor: CGPoint/ { capture = 1 }
        /^    private func layoutTriggerScreen/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$source_file"
    awk '
        /^    private func resolvedAction\(/ { capture = 1 }
        /^    private func resolvedFrame\(/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$source_file"
    awk '
        /^    private func resolvedFrame\(/ { capture = 1 }
        /^    private func showPreview/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$source_file"
    if rg -q '^    private func endDrag\(at cursor: CGPoint\)' "$source_file"; then
        awk '
            /^    private func endDrag\(at cursor: CGPoint\)/ { capture = 1 }
            /^    private func scheduleReleaseSnapshots/ { capture = 0 }
            capture { sub(/^    /, ""); print }
        ' "$source_file"
        cat <<'SWIFT'
    func release(at point: CGPoint) { NSEvent.mouseLocation = point; endDrag(at: point) }
SWIFT
    else
        awk '
            /^    private func endDrag\(\)/ { capture = 1 }
            /^    private func (scheduleReleaseSnapshots|glue)\(/ { capture = 0 }
            capture { sub(/^    /, ""); print }
        ' "$source_file"
        cat <<'SWIFT'
    func release(at point: CGPoint) { NSEvent.mouseLocation = point; endDrag() }
SWIFT
    fi
    cat <<'SWIFT'
}

let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
let screen = NSScreen(frame: screenFrame, visibleFrame: screenFrame)
NSScreen.screens = [screen]
let initial = CGRect(x: 120, y: 100, width: 800, height: 600)
let edgeTarget = CGRect(x: 0, y: 0, width: 720, height: 900)

let edgeState = WindowState(frame: initial)
let edgeWindow = AXWindow(element: AXUIElement(id: 1), state: edgeState)
let edgeManager = SnapManager()
edgeManager.configure(window: edgeWindow, initial: initial, cachedZone: nil)
edgeManager.release(at: CGPoint(x: 1, y: 450))
let edgePassed = edgeState.writes == [edgeTarget] && edgeState.frame == edgeTarget
print(edgePassed ? "PASS release edge selects and applies target" : "FAIL release edge selects and applies target: writes=\(edgeState.writes)")

let outsideState = WindowState(frame: initial)
let outsideWindow = AXWindow(element: AXUIElement(id: 2), state: outsideState)
let outsideManager = SnapManager()
let staleZone = SnapManager.Zone(screen: screen, position: .left, action: .leftHalf,
                                effectiveAction: .leftHalf, frame: edgeTarget, cursor: CGPoint(x: 1, y: 450))
outsideManager.configure(window: outsideWindow, initial: initial, cachedZone: staleZone)
outsideManager.release(at: CGPoint(x: 720, y: 450))
let outsidePassed = outsideState.writes.isEmpty
print(outsidePassed ? "PASS release outside clears stale target" : "FAIL release outside clears stale target: writes=\(outsideState.writes)")

if !edgePassed || !outsidePassed { exit(1) }
SWIFT
} > "$scratch/main.swift"

swiftc "$root/Sources/Halfwin/Snapping/SnapGeometry.swift" "$scratch/main.swift" -o "$scratch/check-snap-release-target"
"$scratch/check-snap-release-target"
