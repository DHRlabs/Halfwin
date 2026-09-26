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

enum SnapRecordState { case active, hidden, minimized, offSpace, stale, superseded }

struct SnappedWindowRecord {
    let window: AXWindow
    var action: SnapAction
    var frame: CGRect
    var state: SnapRecordState
    let windowID: CGWindowID?
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
                  record.action == action, displayID(for: record.frame) == display else { continue }
            occupants[action] = window
        }
        return occupants
    }

    func fillNeighborFrames(on screen: NSScreen, excluding incoming: AXWindow) -> [CGRect] {
        let display = SnapDisplayID(screen)
        let incomingID = records[incoming]?.windowID ?? incoming.frame.flatMap { matchWindowID(incoming, frame: $0) }
        return records.values.compactMap { record in
            guard record.window != incoming, record.state == .active,
                  displayID(for: record.frame) == display, let windowID = record.windowID,
                  let index = visibleWindows.firstIndex(where: { $0.id == windowID }) else { return nil }
            let covering = visibleWindows[..<index].filter { $0.id != incomingID }.map(\.frame)
            return SnapWindowInventory.isCovered(record.frame, by: covering) ? nil : record.frame
        }
    }

    func seams(on display: SnapDisplayID) -> [SnapSeam] { seamsByDisplay[display] ?? [] }

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
        lastValidationTime = ProcessInfo.processInfo.systemUptime
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
            if record.state == .superseded {
                if AXWindow.frameWithError(of: window.element).error == .invalidUIElement {
                    removeRecord(for: window)
                }
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
                  let screen = screen(for: frame), let windowID = record.windowID else {
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
        rebuildSeams()
    }

    func commitSnap(window: AXWindow, action: SnapAction, screen: NSScreen, frame: CGRect? = nil) {
        guard ![.none, .maximize, .center].contains(action) else {
            unsnap(window)
            return
        }
        AXUIElementSetMessagingTimeout(window.element, 0.1)
        validate()
        guard let frame = frame ?? window.frame else { return }
        let display = SnapDisplayID(screen)
        if let layout = SnapMultiWindowLayout.containing(action) {
            if currentLayouts[display] != layout { zoneOwners[display] = [:] }
            currentLayouts[display] = layout
        }
        let windowID = matchWindowID(window, frame: frame)

        for other in Array(records.keys) where other != window {
            guard let record = records[other], record.action == action,
                  displayID(for: record.frame) == display else { continue }
            switch record.state {
            case .active:
                _ = other.setMinimized(true)
                removeRecord(for: other)
            case .minimized, .hidden:
                removeRecord(for: other)
            case .offSpace, .stale:
                var replaced = record
                replaced.state = .superseded
                records[other] = replaced
            case .superseded:
                break
            }
        }
        for ownerDisplay in Array(zoneOwners.keys) {
            zoneOwners[ownerDisplay] = zoneOwners[ownerDisplay]?.filter { $0.value != window }
        }
        records[window] = SnappedWindowRecord(window: window, action: action, frame: frame,
                                               state: .active, windowID: windowID)
        if SnapMultiWindowLayout.containing(action) != nil { zoneOwners[display, default: [:]][action] = window }
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

    private func removeRecord(for window: AXWindow) {
        records.removeValue(forKey: window)
        for display in Array(zoneOwners.keys) {
            zoneOwners[display] = zoneOwners[display]?.filter { $0.value != window }
        }
    }

    private func retainsSnap(_ action: SnapAction, previous: CGRect, current: CGRect, on screen: NSScreen) -> Bool {
        let visible = screen.visibleFrame
        let tolerance = SnapGeometry.edgeTolerance
        let moved = abs(previous.minX - current.minX) > tolerance || abs(previous.minY - current.minY) > tolerance
        let sameSize = abs(previous.width - current.width) <= 1 && abs(previous.height - current.height) <= 1
        if moved && sameSize { return false }
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
                if maxY - minY > 20 {
                    let overlap = minY...maxY
                    if abs(a.frame.maxX - b.frame.minX) <= 2 {
                        addSeam(.vertical, (a.frame.maxX + b.frame.minX) / 2, overlap, a, b, display, &groups)
                    } else if abs(b.frame.maxX - a.frame.minX) <= 2 {
                        addSeam(.vertical, (b.frame.maxX + a.frame.minX) / 2, overlap, b, a, display, &groups)
                    }
                }
                let minX = max(a.frame.minX, b.frame.minX)
                let maxX = min(a.frame.maxX, b.frame.maxX)
                if maxX - minX > 20 {
                    let overlap = minX...maxX
                    if abs(a.frame.maxY - b.frame.minY) <= 2 {
                        addSeam(.horizontal, (a.frame.maxY + b.frame.minY) / 2, overlap, a, b, display, &groups)
                    } else if abs(b.frame.maxY - a.frame.minY) <= 2 {
                        addSeam(.horizontal, (b.frame.maxY + a.frame.minY) / 2, overlap, b, a, display, &groups)
                    }
                }
            }
        }
        return groups.flatMap(visibleSegments)
    }

    private func addSeam(_ axis: SnapSeamAxis, _ coordinate: CGFloat, _ range: ClosedRange<CGFloat>,
                         _ low: SnapPane, _ high: SnapPane, _ display: SnapDisplayID, _ groups: inout [SnapSeam]) {
        if let index = groups.firstIndex(where: { $0.axis == axis && abs($0.coordinate - coordinate) <= 2 }) {
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

    private func visibleSegments(of seam: SnapSeam) -> [SnapSeam] {
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
        guard cuts.count > 1 else { return [] }
        var visible: [ClosedRange<CGFloat>] = []
        for index in 1..<cuts.count {
            let lower = cuts[index - 1]
            let upper = cuts[index]
            guard upper - lower > 1 else { continue }
            let along = (lower + upper) / 2
            let lowPoint: CGPoint
            let highPoint: CGPoint
            switch seam.axis {
            case .vertical:
                lowPoint = CGPoint(x: seam.coordinate - 4, y: along)
                highPoint = CGPoint(x: seam.coordinate + 4, y: along)
            case .horizontal:
                lowPoint = CGPoint(x: along, y: seam.coordinate - 4)
                highPoint = CGPoint(x: along, y: seam.coordinate + 4)
            }
            if seam.low.contains(where: { $0.windowID == frontmostWindowID(at: lowPoint) }) &&
                seam.high.contains(where: { $0.windowID == frontmostWindowID(at: highPoint) }) {
                visible.append(lower...upper)
            }
        }
        var merged: [ClosedRange<CGFloat>] = []
        for range in visible.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged.map { range in
            var segment = seam
            segment.range = range
            return segment
        }
    }
}
