import AppKit
import ApplicationServices
import CoreGraphics

struct SnapDisplayID: Hashable {
    let number: UInt32

    init(_ screen: NSScreen) {
        number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var screen: NSScreen? {
        NSScreen.screens.first { SnapDisplayID($0) == self }
    }
}

enum SnapRecordState { case active, hidden, minimized, offSpace, stale }

struct SnappedWindowRecord {
    let window: AXWindow
    var action: SnapAction
    var layout: SnapMultiWindowLayout?
    var frame: CGRect
    var state: SnapRecordState
    var windowID: CGWindowID?
}

struct SnapLane {
    let action: SnapAction
    let screen: NSScreen
    let display: SnapDisplayID
}

enum SnapSeamAxis { case vertical, horizontal }
enum SnapSeamSide { case low, high }

struct SnapPane {
    let window: AXWindow
    let windowID: CGWindowID
    var frame: CGRect
}

struct SnapSeam {
    let display: SnapDisplayID
    let axis: SnapSeamAxis
    var coordinate: CGFloat
    var range: ClosedRange<CGFloat>
    var low: [SnapPane]
    var high: [SnapPane]
}

/// The one live index of snapped windows. Callers validate at interaction boundaries;
/// divider movement updates the cached records directly without a window-list scan.
final class SnapWindowRegistry {
    static let shared = SnapWindowRegistry()
    static let didValidate = Notification.Name("SnapWindowRegistryDidValidate")

    private struct VisibleWindow {
        let id: CGWindowID
        let pid: pid_t
        let title: String?
        let layer: Int
        let frame: CGRect
    }

    private var records: [AXWindow: SnappedWindowRecord] = [:]
    private var currentLayouts: [SnapDisplayID: SnapMultiWindowLayout] = [:]
    private var zoneOwners: [SnapDisplayID: [SnapAction: AXWindow]] = [:]
    private var visibleWindows: [VisibleWindow] = []
    private var seamsByDisplay: [SnapDisplayID: [SnapSeam]] = [:]
    private var suspendedForShowDesktop = Set<AXWindow>()
    private var helperWindowIDs = Set<CGWindowID>()
    private var lastValidationTime: TimeInterval = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notificationObservers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.validate()
            })
        }
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.validate() })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: ShowDesktopEvents.windowFrameWillChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.userInfo?["window"] as? AXWindow else { return }
            if notification.userInfo?["pushedAside"] as? Bool == true {
                self.suspendedForShowDesktop.insert(window)
            } else {
                self.suspendedForShowDesktop.remove(window)
            }
        })
    }

    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func registerHelperWindow(_ windowNumber: Int) {
        helperWindowIDs.insert(CGWindowID(windowNumber))
    }

    func record(for window: AXWindow) -> SnappedWindowRecord? { records[window] }

    func hasRecord(for window: AXWindow) -> Bool { records[window] != nil }

    func layout(for window: AXWindow) -> SnapMultiWindowLayout? { records[window]?.layout }

    func snappedLane(for window: AXWindow) -> SnapLane? {
        guard let record = records[window], record.state == .active,
              let display = displayID(for: record.frame), let screen = display.screen else { return nil }
        return SnapLane(action: record.action, screen: screen, display: display)
    }

    func zoneOccupants(for layout: SnapMultiWindowLayout, on screen: NSScreen) -> [SnapAction: AXWindow] {
        let display = SnapDisplayID(screen)
        guard currentLayouts[display] == layout else { return [:] }
        var occupants: [SnapAction: AXWindow] = [:]
        for (action, window) in zoneOwners[display] ?? [:] {
            guard layout.zones.contains(where: { $0.action == action }),
                  let record = records[window], record.state == .active,
                  record.action == action,
                  displayID(for: record.frame) == display else { continue }
            occupants[action] = window
        }
        return occupants
    }

    func fillNeighborFrames(on screen: NSScreen, excluding incoming: AXWindow? = nil) -> [CGRect] {
        return records.values.compactMap { record in
            guard record.window != incoming, record.state == .active,
                  displayID(for: record.frame) == SnapDisplayID(screen),
                  record.frame.intersects(screen.visibleFrame) else { return nil }
            return record.frame
        }
    }

    func seams(on display: SnapDisplayID) -> [SnapSeam] { seamsByDisplay[display] ?? [] }

    func hasVisiblePartner(for window: AXWindow) -> Bool {
        for seam in seamsByDisplay.values.flatMap({ $0 }) {
            let visibleRanges = clippedVisibleIntervals(of: seam).ranges
            for visibleRange in visibleRanges {
                for incoming in seam.low where incoming.window == window {
                    for partner in seam.high where SnapJoinGeometry.hasVisiblePartner(
                        incomingID: incoming.windowID, partnerID: partner.windowID,
                        incoming: incoming.frame, partner: partner.frame, incomingOnLow: true,
                        vertical: seam.axis == .vertical, coordinate: seam.coordinate, visibleRanges: [visibleRange],
                        tolerance: SnapGeometry.edgeTolerance, frontmostAt: { self.frontmostWindowID(at: $0) }
                    ) { return true }
                }
                for incoming in seam.high where incoming.window == window {
                    for partner in seam.low where SnapJoinGeometry.hasVisiblePartner(
                        incomingID: incoming.windowID, partnerID: partner.windowID,
                        incoming: incoming.frame, partner: partner.frame, incomingOnLow: false,
                        vertical: seam.axis == .vertical, coordinate: seam.coordinate, visibleRanges: [visibleRange],
                        tolerance: SnapGeometry.edgeTolerance, frontmostAt: { self.frontmostWindowID(at: $0) }
                    ) { return true }
                }
            }
        }
        return false
    }

    func frontmostWindowID(at point: CGPoint) -> CGWindowID? {
        visibleWindows.first { $0.frame.contains(point) }?.id
    }

    func snappedWindow(at point: CGPoint) -> AXWindow? {
        guard let id = frontmostWindowID(at: point) else { return nil }
        return records.values.first { $0.state == .active && $0.windowID == id }?.window
    }

    func validateIfNeeded(interval: TimeInterval) {
        guard ProcessInfo.processInfo.systemUptime - lastValidationTime >= interval else { return }
        validate()
    }

    func validate() {
        guard let windows = readVisibleWindows() else { return }
        visibleWindows = windows

        for window in Array(records.keys) {
            guard var record = records[window] else { continue }
            guard let pid = window.processIdentifier else {
                record.state = .stale
                records[window] = record
                continue
            }
            guard let application = NSRunningApplication(processIdentifier: pid) else {
                removeRecord(for: window)
                continue
            }
            if application.isHidden {
                record.state = .hidden
                records[window] = record
                continue
            }
            if window.isMinimized {
                record.state = .minimized
                records[window] = record
                continue
            }
            if suspendedForShowDesktop.contains(window) { continue }

            let read = AXWindow.frameWithError(of: window.element)
            if read.error == .invalidUIElement {
                removeRecord(for: window)
                continue
            }
            guard read.error == .success, let frame = read.frame,
                  let screen = screen(for: frame) else {
                record.state = .stale
                records[window] = record
                continue
            }
            if record.windowID == nil { record.windowID = matchWindowID(window, frame: frame) }
            guard let windowID = record.windowID else {
                record.state = .stale
                records[window] = record
                continue
            }
            guard windows.contains(where: { $0.id == windowID }) else {
                record.state = .offSpace
                records[window] = record
                continue
            }
            guard retainsSnap(record.action, previous: record.frame, current: frame, on: screen) else {
                removeRecord(for: window)
                continue
            }
            record.frame = frame
            record.state = .active
            records[window] = record
        }
        rebuildZoneOwners()
        rebuildSeams()
        lastValidationTime = ProcessInfo.processInfo.systemUptime
        NotificationCenter.default.post(name: Self.didValidate, object: self)
    }

    func refreshVisibleWindows() {
        guard let windows = readVisibleWindows() else { return }
        visibleWindows = windows
        rebuildSeams()
    }

    func commitSnap(window: AXWindow, action: SnapAction, screen: NSScreen, frame: CGRect? = nil,
                    origin: SnapOrigin = .other,
                    layout chosenLayout: SnapMultiWindowLayout? = nil) {
        guard ![.none, .maximize, .center].contains(action) else {
            unsnap(window)
            return
        }
        AXUIElementSetMessagingTimeout(window.element, 0.1)
        validate()
        guard let frame = frame ?? window.frame else { return }
        let display = SnapDisplayID(screen)
        let isFill = action == .fill
        let fillOwner = isFill ? matchingFillOwner(for: frame, on: screen) : nil
        let storedAction = fillOwner ?? action
        let layout = chosenLayout ?? (isFill ? nil : SnapMultiWindowLayout.containing(action))
        if let layout {
            if currentLayouts[display] != layout { zoneOwners[display] = [:] }
            currentLayouts[display] = layout
        }
        let windowID = matchWindowID(window, frame: frame)

        let replacementAction = isFill ? fillOwner : (layout == nil ? nil : action)
        if let replacementAction {
            for other in Array(records.keys) where other != window {
                guard let record = records[other], record.action == replacementAction,
                      displayID(for: record.frame) == display else { continue }
                switch record.state {
                case .active:
                    _ = other.setMinimized(true)
                    removeRecord(for: other)
                case .minimized, .hidden:
                    removeRecord(for: other)
                case .offSpace:
                    break
                case .stale:
                    removeRecord(for: other)
                }
            }
        }
        for ownerDisplay in Array(zoneOwners.keys) {
            zoneOwners[ownerDisplay] = zoneOwners[ownerDisplay]?.filter { $0.value != window }
        }
        records[window] = SnappedWindowRecord(window: window, action: storedAction, layout: layout, frame: frame,
                                               state: .active, windowID: windowID)
        if origin == .other, chosenLayout == nil {
            adoptVisiblePartners(near: frame, on: screen, preferredLayout: layout, excluding: window)
        }
        rebuildZoneOwners()
        rebuildSeams()
    }

    func unsnap(_ window: AXWindow) {
        guard records[window] != nil else { return }
        removeRecord(for: window)
        rebuildSeams()
    }

    func recordFrameWrite(window: AXWindow, frame: CGRect) {
        guard var record = records[window] else { return }
        record.frame = frame
        record.state = .active
        records[window] = record
        if let windowID = record.windowID {
            visibleWindows = visibleWindows.map { visible in
                guard visible.id == windowID else { return visible }
                return VisibleWindow(id: visible.id, pid: visible.pid, title: visible.title,
                                     layer: visible.layer, frame: frame)
            }
        }
        rebuildSeams()
    }

    private func matchWindowID(_ window: AXWindow, frame: CGRect) -> CGWindowID? {
        guard let pid = window.processIdentifier else { return nil }
        let candidates = visibleWindows.filter { $0.pid == pid && $0.layer == 0 }
        if let title = window.title,
           let match = candidates.first(where: { $0.title == title && SnapGeometry.isClose($0.frame, frame, tolerance: 8) }) {
            return match.id
        }
        return candidates.first { SnapGeometry.isClose($0.frame, frame, tolerance: 8) }?.id
    }

    private func adoptVisiblePartners(near frame: CGRect, on screen: NSScreen,
                                      preferredLayout: SnapMultiWindowLayout?, excluding incoming: AXWindow) {
        let display = SnapDisplayID(screen)
        var excluded = Set(records.keys)
        excluded.insert(incoming)
        let zones = snapZones(on: screen, preferredLayout: preferredLayout)
        for choice in SnapWindowInventory.choices(on: screen, excluding: excluded) {
            guard !choice.window.isMinimized, !choice.window.isFullScreen,
                  let candidateFrame = choice.window.frame,
                  displayID(for: candidateFrame) == display,
                  let index = visibleWindows.firstIndex(where: { $0.id == choice.id }) else { continue }
            let isExposed = !SnapWindowInventory.isCovered(candidateFrame, by: visibleWindows[..<index].map(\.frame))
            let zone = zones.first {
                SnapGeometry.isClose(candidateFrame, $0.frame, tolerance: SnapGeometry.edgeTolerance)
            }
            guard SnapJoinGeometry.canAdopt(incoming: frame, candidate: candidateFrame, isExposed: isExposed,
                                            matchesSnapZone: zone != nil, tolerance: SnapGeometry.edgeTolerance),
                  let zone else { continue }
            records[choice.window] = SnappedWindowRecord(window: choice.window, action: zone.action,
                                                          layout: zone.layout, frame: candidateFrame,
                                                          state: .active, windowID: choice.id)
        }
    }

    private func snapZones(on screen: NSScreen, preferredLayout: SnapMultiWindowLayout?)
        -> [(action: SnapAction, layout: SnapMultiWindowLayout, frame: CGRect)] {
        let portrait = screen.frame.height > screen.frame.width
        let layouts = [preferredLayout].compactMap { $0 } + SnapMultiWindowLayout.allCases.filter { $0 != preferredLayout }
        var result: [(action: SnapAction, layout: SnapMultiWindowLayout, frame: CGRect)] = []
        for layout in layouts {
            for zone in layout.zones(portrait: portrait) {
                guard let expected = SnapGeometry.frame(for: zone.action, visibleFrame: screen.visibleFrame,
                                                        currentWindowFrame: screen.visibleFrame, portrait: portrait) else { continue }
                result.append((zone.action, layout, expected))
            }
        }
        return result
    }

    private func removeRecord(for window: AXWindow) {
        records.removeValue(forKey: window)
        for display in Array(zoneOwners.keys) {
            zoneOwners[display] = zoneOwners[display]?.filter { $0.value != window }
        }
    }

    private func matchingFillOwner(for frame: CGRect, on screen: NSScreen) -> SnapAction? {
        let portrait = screen.frame.height > screen.frame.width
        func matches(_ layouts: [SnapMultiWindowLayout]) -> Set<SnapAction> {
            Set(layouts.flatMap { $0.zones(portrait: portrait) }.compactMap { zone in
                guard let expected = SnapGeometry.frame(for: zone.action, visibleFrame: screen.visibleFrame,
                                                         currentWindowFrame: frame, portrait: portrait),
                      SnapGeometry.isClose(frame, expected, tolerance: SnapGeometry.edgeTolerance) else { return nil }
                return zone.action
            })
        }
        if let layout = currentLayouts[SnapDisplayID(screen)] {
            let current = matches([layout])
            if current.count == 1 { return current.first }
            if !current.isEmpty { return nil }
        }
        let all = matches(SnapMultiWindowLayout.allCases)
        return all.count == 1 ? all.first : nil
    }

    private func rebuildZoneOwners() {
        zoneOwners = [:]
        for record in records.values where record.state == .active {
            guard let display = displayID(for: record.frame),
                  let layout = currentLayouts[display],
                  layout.zones.contains(where: { $0.action == record.action }) else { continue }
            zoneOwners[display, default: [:]][record.action] = record.window
        }
    }

    private func retainsSnap(_ action: SnapAction, previous: CGRect, current: CGRect, on screen: NSScreen) -> Bool {
        let visible = screen.visibleFrame
        let tolerance = SnapGeometry.edgeTolerance
        let moved = abs(previous.minX - current.minX) > tolerance || abs(previous.minY - current.minY) > tolerance
        let sameSize = abs(previous.width - current.width) <= 1 && abs(previous.height - current.height) <= 1
        if moved && sameSize { return false }
        if action == .fill {
            let anchors = [
                (previous.minX, visible.minX, current.minX),
                (previous.maxX, visible.maxX, current.maxX),
                (previous.minY, visible.minY, current.minY),
                (previous.maxY, visible.maxY, current.maxY),
            ].filter { abs($0.0 - $0.1) <= 1 }
            return anchors.allSatisfy { abs($0.1 - $0.2) <= tolerance } &&
                (anchors.isEmpty ? SnapGeometry.isClose(previous, current, tolerance: tolerance) || !sameSize : true)
        }
        guard let expected = SnapGeometry.frame(for: action, visibleFrame: visible,
                                                currentWindowFrame: current,
                                                portrait: screen.frame.height > screen.frame.width) else { return false }
        if expected.minX <= visible.minX + tolerance && abs(current.minX - visible.minX) > tolerance { return false }
        if expected.maxX >= visible.maxX - tolerance && abs(current.maxX - visible.maxX) > tolerance { return false }
        if expected.minY <= visible.minY + tolerance && abs(current.minY - visible.minY) > tolerance { return false }
        if expected.maxY >= visible.maxY - tolerance && abs(current.maxY - visible.maxY) > tolerance { return false }
        let expectedSpansWidth = expected.width >= visible.width - tolerance
        let expectedSpansHeight = expected.height >= visible.height - tolerance
        if !expectedSpansWidth && current.width >= visible.width - tolerance { return false }
        if !expectedSpansHeight && current.height >= visible.height - tolerance { return false }
        return true
    }

    private func screen(for frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func displayID(for frame: CGRect) -> SnapDisplayID? {
        screen(for: frame).map(SnapDisplayID.init)
    }

    private func readVisibleWindows() -> [VisibleWindow]? {
        guard let values = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return values.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  !helperWindowIDs.contains(id),
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, (0...3).contains(layer),
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let rawTitle = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return VisibleWindow(id: id, pid: pid, title: rawTitle?.isEmpty == false ? rawTitle : nil,
                                 layer: layer, frame: frame.axFlipped)
        }
    }

    private func rebuildSeams() {
        var panesByDisplay: [SnapDisplayID: [SnapPane]] = [:]
        for record in records.values where record.state == .active {
            guard let display = displayID(for: record.frame), let windowID = record.windowID,
                  let index = visibleWindows.firstIndex(where: { $0.id == windowID }) else { continue }
            let covering = visibleWindows[..<index].map(\.frame)
            guard !SnapWindowInventory.isCovered(record.frame, by: covering) else { continue }
            panesByDisplay[display, default: []].append(SnapPane(window: record.window,
                                                                 windowID: windowID, frame: record.frame))
        }
        seamsByDisplay = panesByDisplay.mapValues(makeSeams)
    }

    private func makeSeams(_ panes: [SnapPane]) -> [SnapSeam] {
        guard let display = panes.first.flatMap({ displayID(for: $0.frame) }) else { return [] }
        var groups: [SnapSeam] = []
        for first in panes.indices {
            for second in panes.indices where second > first {
                let a = panes[first]
                let b = panes[second]
                let minY = max(a.frame.minY, b.frame.minY)
                let maxY = min(a.frame.maxY, b.frame.maxY)
                if maxY - minY > SnapJoinGeometry.minimumSeamOverlap {
                    let overlap = minY...maxY
                    if abs(a.frame.maxX - b.frame.minX) <= SnapGeometry.edgeTolerance {
                        addSeam(.vertical, (a.frame.maxX + b.frame.minX) / 2, overlap, a, b, display, &groups)
                    } else if abs(b.frame.maxX - a.frame.minX) <= SnapGeometry.edgeTolerance {
                        addSeam(.vertical, (b.frame.maxX + a.frame.minX) / 2, overlap, b, a, display, &groups)
                    }
                }
                let minX = max(a.frame.minX, b.frame.minX)
                let maxX = min(a.frame.maxX, b.frame.maxX)
                if maxX - minX > SnapJoinGeometry.minimumSeamOverlap {
                    let overlap = minX...maxX
                    if abs(a.frame.maxY - b.frame.minY) <= SnapGeometry.edgeTolerance {
                        addSeam(.horizontal, (a.frame.maxY + b.frame.minY) / 2, overlap, a, b, display, &groups)
                    } else if abs(b.frame.maxY - a.frame.minY) <= SnapGeometry.edgeTolerance {
                        addSeam(.horizontal, (b.frame.maxY + a.frame.minY) / 2, overlap, b, a, display, &groups)
                    }
                }
            }
        }
        return groups.flatMap(visibleSegments)
    }

    private func addSeam(_ axis: SnapSeamAxis, _ coordinate: CGFloat, _ range: ClosedRange<CGFloat>,
                         _ low: SnapPane, _ high: SnapPane, _ display: SnapDisplayID, _ groups: inout [SnapSeam]) {
        if let index = groups.firstIndex(where: {
            $0.axis == axis && abs($0.coordinate - coordinate) <= SnapGeometry.edgeTolerance
        }) {
            var group = groups[index]
            group.coordinate = (group.coordinate + coordinate) / 2
            group.range = min(group.range.lowerBound, range.lowerBound)...max(group.range.upperBound, range.upperBound)
            if !group.low.contains(where: { $0.window == low.window }) { group.low.append(low) }
            if !group.high.contains(where: { $0.window == high.window }) { group.high.append(high) }
            groups[index] = group
        } else {
            groups.append(SnapSeam(display: display, axis: axis, coordinate: coordinate, range: range,
                                   low: [low], high: [high]))
        }
    }

    private func clippedVisibleIntervals(of seam: SnapSeam) -> (cuts: [CGFloat], ranges: [ClosedRange<CGFloat>]) {
        let endpoints: [CGFloat]
        switch seam.axis {
        case .vertical:
            endpoints = visibleWindows.flatMap { [$0.frame.minY, $0.frame.maxY] } +
                seam.low.flatMap { [$0.frame.minY, $0.frame.maxY] } + seam.high.flatMap { [$0.frame.minY, $0.frame.maxY] }
        case .horizontal:
            endpoints = visibleWindows.flatMap { [$0.frame.minX, $0.frame.maxX] } +
                seam.low.flatMap { [$0.frame.minX, $0.frame.maxX] } + seam.high.flatMap { [$0.frame.minX, $0.frame.maxX] }
        }
        let cuts = Set([seam.range.lowerBound, seam.range.upperBound] +
            endpoints.filter { $0 > seam.range.lowerBound && $0 < seam.range.upperBound }).sorted()
        guard cuts.count > 1 else { return (cuts, []) }
        var visible: [ClosedRange<CGFloat>] = []
        for index in 1..<cuts.count {
            let lower = cuts[index - 1]
            let upper = cuts[index]
            guard upper - lower > 1 else { continue }
            let along = (lower + upper) / 2
            let lowVisible = seam.low.contains { pane in
                seamTouches(pane, seam: seam, at: along, side: .low) &&
                    pane.windowID == frontmostWindowID(at: pointInside(pane, seam: seam, along: along, side: .low))
            }
            let highVisible = seam.high.contains { pane in
                seamTouches(pane, seam: seam, at: along, side: .high) &&
                    pane.windowID == frontmostWindowID(at: pointInside(pane, seam: seam, along: along, side: .high))
            }
            if lowVisible && highVisible {
                visible.append(lower...upper)
            }
        }
        return (cuts, visible)
    }

    private func visibleSegments(of seam: SnapSeam) -> [SnapSeam] {
        let (cuts, visible) = clippedVisibleIntervals(of: seam)
        var merged: [ClosedRange<CGFloat>] = []
        for range in visible.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last {
                let gapCuts = [last.upperBound] + cuts.filter {
                    $0 > last.upperBound && $0 < range.lowerBound
                } + [range.lowerBound]
                let intervals = zip(gapCuts, gapCuts.dropFirst())
                let lowVisibleAcrossGap = intervals.allSatisfy { lower, upper in
                    let along = (lower + upper) / 2
                    return sideVisible(seam, at: along, side: .low)
                }
                let highVisibleAcrossGap = intervals.allSatisfy { lower, upper in
                    sideVisible(seam, at: (lower + upper) / 2, side: .high)
                }
                if range.lowerBound <= last.upperBound + 1 ||
                    (range.lowerBound - last.upperBound < SnapGeometry.edgeTolerance &&
                     (lowVisibleAcrossGap || highVisibleAcrossGap)) {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                    continue
                }
            }
            merged.append(range)
        }
        return merged.map { range in
            var segment = seam
            segment.range = range
            return segment
        }
    }

    private func sideVisible(_ seam: SnapSeam, at along: CGFloat, side: SnapSeamSide) -> Bool {
        let panes = side == .low ? seam.low : seam.high
        return panes.contains { pane in
            seamTouches(pane, seam: seam, at: along, side: side) &&
                pane.windowID == frontmostWindowID(at: pointInside(pane, seam: seam, along: along, side: side))
        }
    }

    private func seamTouches(_ pane: SnapPane, seam: SnapSeam, at along: CGFloat, side: SnapSeamSide) -> Bool {
        let edge: CGFloat
        switch (seam.axis, side) {
        case (.vertical, .low): edge = pane.frame.maxX
        case (.vertical, .high): edge = pane.frame.minX
        case (.horizontal, .low): edge = pane.frame.maxY
        case (.horizontal, .high): edge = pane.frame.minY
        }
        let spans = seam.axis == .vertical
            ? along >= pane.frame.minY && along <= pane.frame.maxY
            : along >= pane.frame.minX && along <= pane.frame.maxX
        return spans && abs(edge - seam.coordinate) <= SnapGeometry.edgeTolerance
    }

    private func pointInside(_ pane: SnapPane, seam: SnapSeam, along: CGFloat, side: SnapSeamSide) -> CGPoint {
        switch (seam.axis, side) {
        case (.vertical, .low): return CGPoint(x: pane.frame.maxX - 1, y: along)
        case (.vertical, .high): return CGPoint(x: pane.frame.minX + 1, y: along)
        case (.horizontal, .low): return CGPoint(x: along, y: pane.frame.maxY - 1)
        case (.horizontal, .high): return CGPoint(x: along, y: pane.frame.minY + 1)
        }
    }
}
