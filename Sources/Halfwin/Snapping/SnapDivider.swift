import AppKit
import ApplicationServices

/// Shows a handle at visible shared snap edges and links divider and native
/// edge resizing. Snap frames and visibility live in SnapWindowRegistry.
final class SnapDividerManager {
    private typealias Axis = SnapSeamAxis
    private typealias Side = SnapSeamSide
    private typealias Pane = SnapPane
    private typealias Divider = SnapSeam

    private struct ResizeSession {
        var divider: Divider
        let owner: AXWindow?
        let ownerSide: Side?
        let id: UUID
        let anchors: [AXWindow: CGFloat]
        let appQueues: [pid_t: DispatchQueue]
        let primaryScreenHeight: CGFloat
        var clampedEdges: [AXWindow: CGFloat] = [:]
        var lastRequestedCoordinate: CGFloat?
        var lastShrinkingSide: Side?
    }

    private struct ResizeResult {
        var session: ResizeSession
        var frames: [AXWindow: CGRect]
    }

    private var enabled = false
    private var monitor: Any?
    private var validationTimer: Timer?
    private var resizeTimer: Timer?
    private var resizeSession: ResizeSession?
    private var dividerDrag = false
    private var latestDividerPoint: CGPoint?
    private var latestDividerMovement: CGFloat = 0
    private var nativeResizePending = false
    private var resizeFinishPending = false
    private var resizeWorkInFlight = false
    private var draggedSnapWindow: AXWindow?
    private var movedSnapWindow = false
    private var registryObserver: NSObjectProtocol?
    private lazy var panel = SnapDividerPanel(
        mouseDown: { [weak self] event in self?.beginDividerDrag(event) },
        mouseDragged: { [weak self] in self?.dragDivider() },
        mouseUp: { [weak self] in self?.endDividerDrag() }
    )

    init() {
        registryObserver = NotificationCenter.default.addObserver(
            forName: SnapWindowRegistry.didValidate, object: SnapWindowRegistry.shared, queue: .main
        ) { [weak self] _ in self?.invalidateAndRebuild() }
    }

    deinit {
        if let registryObserver { NotificationCenter.default.removeObserver(registryObserver) }
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            SnapWindowRegistry.shared.registerHelperWindow(panel.windowNumber)
            monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] in self?.handle($0) }
            SnapWindowRegistry.shared.validate()
            updateHover(at: NSEvent.mouseLocation)
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            validationTimer?.invalidate()
            validationTimer = nil
            resizeTimer?.invalidate()
            resizeTimer = nil
            resizeSession = nil
            dividerDrag = false
            latestDividerPoint = nil
            latestDividerMovement = 0
            nativeResizePending = false
            resizeFinishPending = false
            draggedSnapWindow = nil
            movedSnapWindow = false
            panel.hide()
        }
    }

    private func handle(_ event: NSEvent) {
        guard enabled else { return }
        let point = NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            guard resizeSession == nil else { return }
            updateHover(at: point)
        case .leftMouseDown:
            resizeSession = nil
            stopResizeTimer()
            dividerDrag = false
            latestDividerPoint = nil
            latestDividerMovement = 0
            nativeResizePending = false
            resizeFinishPending = false
            if nearCachedSeam(point) { SnapWindowRegistry.shared.refreshVisibleWindows() }
            draggedSnapWindow = SnapWindowRegistry.shared.snappedWindow(at: point)
            movedSnapWindow = false
            guard let divider = divider(at: point), let owner = paneUnderCursor(point, in: divider) else {
                hideDivider()
                return
            }
            resizeSession = makeResizeSession(
                divider: divider, owner: owner.window,
                ownerSide: divider.low.contains { $0.window == owner.window } ? .low : .high
            )
            nativeResizePending = false
            resizeFinishPending = false
            startResizeTimer()
            hideDivider()
        case .leftMouseDragged:
            if draggedSnapWindow != nil { movedSnapWindow = true }
            if resizeSession?.owner != nil { nativeResizePending = true }
        case .leftMouseUp:
            if resizeSession?.owner != nil {
                finishResizeSession()
                draggedSnapWindow = nil
                movedSnapWindow = false
                return
            }
            if movedSnapWindow { SnapWindowRegistry.shared.validateIfNeeded(interval: 0.1) }
            draggedSnapWindow = nil
            movedSnapWindow = false
            refreshCacheIfNeeded(at: point)
            updateHover(at: point)
        default:
            break
        }
    }

    private func refreshCacheIfNeeded(at point: CGPoint, interval: TimeInterval = 1) {
        if nearCachedSeam(point) {
            SnapWindowRegistry.shared.validateIfNeeded(interval: interval)
        }
    }

    private func invalidateAndRebuild() {
        guard enabled, resizeSession == nil else { return }
        updateHover(at: NSEvent.mouseLocation)
    }

    private func updateHover(at point: CGPoint) {
        guard resizeSession == nil else { return }
        refreshCacheIfNeeded(at: point, interval: 0.1)
        showHoverFromCache(at: point)
    }

    private func showHoverFromCache(at point: CGPoint) {
        guard let divider = divider(at: point) else {
            hideDivider()
            return
        }
        panel.show(frame: panelFrame(for: divider), vertical: divider.axis == .vertical)
        if validationTimer == nil {
            validationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.enabled, self.resizeSession == nil else { return }
                let pointer = NSEvent.mouseLocation
                self.refreshCacheIfNeeded(at: pointer)
                self.updateHover(at: pointer)
            }
        }
    }

    private func hideDivider() {
        panel.hide()
        validationTimer?.invalidate()
        validationTimer = nil
    }

    private func allSeams() -> [Divider] {
        NSScreen.screens.flatMap { SnapWindowRegistry.shared.seams(on: SnapDisplayID($0)) }
    }

    private func nearCachedSeam(_ point: CGPoint) -> Bool {
        allSeams().contains { seam in
            switch seam.axis {
            case .vertical: return abs(point.x - seam.coordinate) <= 6 && seam.range.contains(point.y)
            case .horizontal: return abs(point.y - seam.coordinate) <= 6 && seam.range.contains(point.x)
            }
        }
    }

    private func divider(at point: CGPoint) -> Divider? {
        return allSeams().filter { seam in
            let along: CGFloat
            switch seam.axis {
            case .vertical:
                along = point.y
                guard abs(point.x - seam.coordinate) <= 6, seam.range.contains(along) else { return false }
            case .horizontal:
                along = point.x
                guard abs(point.y - seam.coordinate) <= 6, seam.range.contains(along) else { return false }
            }
            return visiblePane(seam.low, side: .low, in: seam, at: along) != nil ||
                visiblePane(seam.high, side: .high, in: seam, at: along) != nil
        }.min { distance($0, point) < distance($1, point) }
    }

    private func paneUnderCursor(_ point: CGPoint, in seam: Divider) -> Pane? {
        let side: Side
        let along: CGFloat
        switch seam.axis {
        case .vertical:
            side = point.x < seam.coordinate ? .low : .high
            along = point.y
        case .horizontal:
            side = point.y < seam.coordinate ? .low : .high
            along = point.x
        }
        if let pane = visiblePane(side == .low ? seam.low : seam.high, side: side, in: seam, at: along) {
            return pane
        }
        let otherSide: Side = side == .low ? .high : .low
        return visiblePane(otherSide == .low ? seam.low : seam.high, side: otherSide, in: seam, at: along)
    }

    private func visiblePane(_ panes: [Pane], side: Side, in seam: Divider, at along: CGFloat) -> Pane? {
        panes.first { pane in
            let edgeCoordinate: CGFloat
            let point: CGPoint
            switch (seam.axis, side) {
            case (.vertical, .low):
                edgeCoordinate = pane.frame.maxX
                point = CGPoint(x: edgeCoordinate - 1, y: along)
            case (.vertical, .high):
                edgeCoordinate = pane.frame.minX
                point = CGPoint(x: edgeCoordinate + 1, y: along)
            case (.horizontal, .low):
                edgeCoordinate = pane.frame.maxY
                point = CGPoint(x: along, y: edgeCoordinate - 1)
            case (.horizontal, .high):
                edgeCoordinate = pane.frame.minY
                point = CGPoint(x: along, y: edgeCoordinate + 1)
            }
            let spans = seam.axis == .vertical
                ? along >= pane.frame.minY && along <= pane.frame.maxY
                : along >= pane.frame.minX && along <= pane.frame.maxX
            return spans && abs(edgeCoordinate - seam.coordinate) <= SnapGeometry.edgeTolerance &&
                SnapWindowRegistry.shared.frontmostWindowID(at: point) == pane.windowID
        }
    }

    private func distance(_ seam: Divider, _ point: CGPoint) -> CGFloat {
        abs((seam.axis == .vertical ? point.x : point.y) - seam.coordinate)
    }

    private func panelFrame(for divider: Divider) -> CGRect {
        switch divider.axis {
        case .vertical:
            return CGRect(x: divider.coordinate - 3, y: divider.range.lowerBound,
                          width: 6, height: divider.range.upperBound - divider.range.lowerBound)
        case .horizontal:
            return CGRect(x: divider.range.lowerBound, y: divider.coordinate - 3,
                          width: divider.range.upperBound - divider.range.lowerBound, height: 6)
        }
    }

    private func beginDividerDrag(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        SnapWindowRegistry.shared.refreshVisibleWindows()
        guard let divider = divider(at: point) else {
            hideDivider()
            if let click = event.cgEvent {
                DispatchQueue.main.async { click.post(tap: .cghidEventTap) }
            }
            return
        }
        resizeSession = makeResizeSession(divider: divider, owner: nil, ownerSide: nil)
        dividerDrag = true
        latestDividerPoint = point
        latestDividerMovement = divider.axis == .vertical ? point.x - divider.coordinate : point.y - divider.coordinate
        resizeFinishPending = false
        nativeResizePending = false
        validationTimer?.invalidate()
        validationTimer = nil
        startResizeTimer()
    }

    private func dragDivider() {
        guard dividerDrag else { return }
        let point = NSEvent.mouseLocation
        if let previous = latestDividerPoint, let axis = resizeSession?.divider.axis {
            latestDividerMovement = axis == .vertical ? point.x - previous.x : point.y - previous.y
        }
        latestDividerPoint = point
    }

    private func endDividerDrag() {
        guard dividerDrag else { return }
        let point = NSEvent.mouseLocation
        if let previous = latestDividerPoint, let axis = resizeSession?.divider.axis {
            latestDividerMovement = axis == .vertical ? point.x - previous.x : point.y - previous.y
        }
        latestDividerPoint = point
        finishResizeSession()
    }

    private func makeResizeSession(divider: Divider, owner: AXWindow?, ownerSide: Side?) -> ResizeSession {
        var anchors: [AXWindow: CGFloat] = [:]
        for pane in divider.low { anchors[pane.window] = limit(pane.frame, axis: divider.axis, side: .low) }
        for pane in divider.high { anchors[pane.window] = limit(pane.frame, axis: divider.axis, side: .high) }
        let processIDs = Set((divider.low + divider.high).map { $0.window.processIdentifier ?? 0 })
        let queues = Dictionary(uniqueKeysWithValues: processIDs.map { pid in
            (pid, DispatchQueue(label: "com.halfwin.snap-divider.\(pid)", qos: .userInteractive))
        })
        return ResizeSession(divider: divider, owner: owner, ownerSide: ownerSide, id: UUID(),
                             anchors: anchors, appQueues: queues,
                             primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    private func startResizeTimer() {
        guard resizeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.processResize() }
        resizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishResizeSession() {
        guard resizeSession != nil else { return }
        resizeFinishPending = true
        nativeResizePending = true
        processResize()
    }

    private func processResize() {
        guard enabled, let session = resizeSession else {
            stopResizeTimer()
            return
        }
        let final = resizeFinishPending
        let isDividerDrag = dividerDrag
        let requested: CGFloat?
        var movement: CGFloat = 0
        let now = ProcessInfo.processInfo.systemUptime
        if isDividerDrag, let point = latestDividerPoint {
            let pointerCoordinate = session.divider.axis == .vertical ? point.x : point.y
            requested = pointerCoordinate
            let previous = session.lastRequestedCoordinate ?? session.divider.coordinate
            let pointerMoved = abs(pointerCoordinate - previous) > 0.1
            let netMovement = pointerCoordinate - previous
            movement = abs(netMovement) >= 0.1 ? netMovement : latestDividerMovement
            let coordinate = constrainedCoordinate(pointerCoordinate, in: session)
            var preview = session.divider
            preview.coordinate = coordinate
            panel.show(frame: panelFrame(for: preview), vertical: preview.axis == .vertical)
            guard !resizeWorkInFlight else { return }
            if !final, !pointerMoved { return }
            if final, !pointerMoved { movement = 0 }
        } else {
            requested = nil
            guard !resizeWorkInFlight else { return }
            guard final || nativeResizePending else { return }
        }
        var passSession = session
        if isDividerDrag, let requested { passSession.lastRequestedCoordinate = requested }
        let passMovement = movement
        nativeResizePending = false
        resizeWorkInFlight = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let result = self.resize(session: passSession, requested: requested, pointerMovement: passMovement,
                                     native: !isDividerDrag, final: final)
            DispatchQueue.main.async {
                self.resizeWorkInFlight = false
                let sessionIsCurrent = self.resizeSession?.id == passSession.id
                if let result {
                    for (window, frame) in result.frames {
                        SnapWindowRegistry.shared.recordFrameWrite(window: window, frame: frame)
                    }
                    if sessionIsCurrent { self.resizeSession = result.session }
                    if sessionIsCurrent && self.dividerDrag && final {
                        let divider = result.session.divider
                        self.panel.show(frame: self.panelFrame(for: divider), vertical: divider.axis == .vertical)
                    }
                }
                guard sessionIsCurrent else {
                    if self.resizeSession == nil {
                        self.stopResizeTimer()
                        if final, self.enabled { SnapWindowRegistry.shared.refreshVisibleWindows() }
                    }
                    return
                }
                if final {
                    self.completeResizeSession()
                } else if self.resizeFinishPending || self.nativeResizePending || self.dividerDrag,
                          ProcessInfo.processInfo.systemUptime - now >= 1.0 / 60 {
                    self.processResize()
                }
            }
        }
    }

    private func stopResizeTimer() {
        resizeTimer?.invalidate()
        resizeTimer = nil
    }

    private func completeResizeSession() {
        stopResizeTimer()
        resizeSession = nil
        dividerDrag = false
        latestDividerPoint = nil
        latestDividerMovement = 0
        nativeResizePending = false
        resizeFinishPending = false
        SnapWindowRegistry.shared.refreshVisibleWindows()
        showHoverFromCache(at: NSEvent.mouseLocation)
    }

    private func validEdgeResize(from old: CGRect, to new: CGRect, axis: Axis, side: Side) -> Bool {
        switch axis {
        case .vertical:
            guard abs(old.width - new.width) > 0.1,
                  abs(old.minY - new.minY) <= 2, abs(old.height - new.height) <= 2 else { return false }
            return side == .low ? abs(old.minX - new.minX) <= 1 : abs(old.maxX - new.maxX) <= 1
        case .horizontal:
            guard abs(old.height - new.height) > 0.1,
                  abs(old.minX - new.minX) <= 2, abs(old.width - new.width) <= 2 else { return false }
            return side == .low ? abs(old.minY - new.minY) <= 1 : abs(old.maxY - new.maxY) <= 1
        }
    }

    private func resize(session original: ResizeSession, requested: CGFloat?, pointerMovement: CGFloat,
                        native: Bool, final: Bool) -> ResizeResult? {
        var session = original
        var divider = session.divider
        var frames: [AXWindow: CGRect] = [:]
        let oldOwnerFrame = session.owner.flatMap { owner in
            (divider.low + divider.high).first(where: { $0.window == owner })?.frame
        }
        if let owner = session.owner { AXUIElementSetMessagingTimeout(owner.element, 0.1) }
        let ownerFrame = native ? session.owner?.frame(primaryScreenHeight: session.primaryScreenHeight) : nil
        var desired = requested
        var movement = pointerMovement
        if native, let ownerFrame, let oldOwnerFrame, let ownerSide = session.ownerSide {
            if validEdgeResize(from: oldOwnerFrame, to: ownerFrame, axis: divider.axis, side: ownerSide) {
                let ownerCoordinate = edge(ownerFrame, axis: divider.axis, side: ownerSide)
                desired = ownerCoordinate
                movement = ownerCoordinate - (session.lastRequestedCoordinate ??
                    edge(oldOwnerFrame, axis: divider.axis, side: ownerSide))
                session.lastRequestedCoordinate = ownerCoordinate
            } else if final, let shrinkingSide = session.lastShrinkingSide {
                desired = edge(ownerFrame, axis: divider.axis, side: ownerSide)
                movement = shrinkingSide == .high ? 1 : -1
            } else {
                return final ? verifyFinal(session) : nil
            }
        }
        guard let requestedCoordinate = desired else { return final ? verifyFinal(session) : nil }
        if final, !native, abs(movement) <= 0.1 {
            guard let shrinkingSide = session.lastShrinkingSide else { return verifyFinal(session) }
            movement = shrinkingSide == .high ? 1 : -1
        }
        if !final, native, abs(requestedCoordinate - divider.coordinate) <= 0.1 { return nil }

        var coordinate = constrainedCoordinate(requestedCoordinate, in: session)
        if !final, native, abs(coordinate - divider.coordinate) <= 0.1 {
            let ownerNeedsCorrection: Bool
            if native, let ownerSide = session.ownerSide, let ownerFrame {
                ownerNeedsCorrection = abs(edge(ownerFrame, axis: divider.axis, side: ownerSide) - coordinate) > 0.1
            } else {
                ownerNeedsCorrection = false
            }
            if !ownerNeedsCorrection { return nil }
        }
        var ownerResult = ownerFrame
        if native, let ownerFrame, let ownerSide = session.ownerSide, let owner = session.owner {
            ownerResult = frame(ownerFrame, axis: divider.axis, side: ownerSide, coordinate: coordinate,
                                anchor: session.anchors[owner] ?? limit(ownerFrame, axis: divider.axis, side: ownerSide))
        }
        let increasing = movement > 0
        let shrinkingSide: Side = increasing ? .high : .low
        session.lastShrinkingSide = shrinkingSide
        var shrinkingPanes = shrinkingSide == .low ? divider.low : divider.high
        for attempt in 0..<2 {
            let shrinkFrames = applyFrames(shrinkingPanes, side: shrinkingSide, coordinate: coordinate,
                                           session: session, nativeOwner: native ? session.owner : nil,
                                           ownerFrame: ownerResult, readBack: true)
            for index in shrinkingPanes.indices {
                var pane = shrinkingPanes[index]
                guard var actual = shrinkFrames[pane.window] else { return nil }
                let anchor = session.anchors[pane.window] ?? limit(pane.frame, axis: divider.axis, side: shrinkingSide)
                let target = frame(pane.frame, axis: divider.axis, side: shrinkingSide,
                                   coordinate: coordinate, anchor: anchor)
                let actualSize = divider.axis == .vertical ? actual.width : actual.height
                let targetSize = divider.axis == .vertical ? target.width : target.height
                let previousSize = divider.axis == .vertical ? pane.frame.width : pane.frame.height
                // ponytail: 20 pt absorbs common cell rounding; infer per-app steps if larger cells appear.
                let roundingTolerance = SnapGeometry.edgeTolerance
                let reachedMinimum = actualSize > targetSize + roundingTolerance ||
                    (abs(actualSize - previousSize) <= 0.5 && previousSize - targetSize > roundingTolerance)
                if abs(limit(actual, axis: divider.axis, side: shrinkingSide) - anchor) > 0.5 {
                    pane.window.setFrame(farEdgeAnchored(actual, axis: divider.axis, side: shrinkingSide, anchor: anchor),
                                         primaryScreenHeight: session.primaryScreenHeight)
                    guard let readBack = pane.window.frame(primaryScreenHeight: session.primaryScreenHeight) else { return nil }
                    actual = readBack
                }
                if reachedMinimum, pane.window != session.owner {
                    let clamped = edge(actual, axis: divider.axis, side: shrinkingSide)
                    if shrinkingSide == .low {
                        session.clampedEdges[pane.window] = max(session.clampedEdges[pane.window] ?? clamped, clamped)
                    } else {
                        session.clampedEdges[pane.window] = min(session.clampedEdges[pane.window] ?? clamped, clamped)
                    }
                }
                frames[pane.window] = actual
                pane.frame = actual
                shrinkingPanes[index] = pane
                if pane.window == session.owner { ownerResult = actual }
            }
            let shrinkEdges = shrinkingPanes.map { edge($0.frame, axis: divider.axis, side: shrinkingSide) }
            let accepted = increasing ? (shrinkEdges.min() ?? coordinate) : (shrinkEdges.max() ?? coordinate)
            if attempt == 1 || abs(accepted - coordinate) <= 0.1 {
                coordinate = accepted
                break
            }
            coordinate = accepted
        }

        if native, let owner = session.owner, let ownerSide = session.ownerSide,
           let current = ownerFrame, abs(edge(current, axis: divider.axis, side: ownerSide) - coordinate) > 0.1 {
            let target = frame(current, axis: divider.axis, side: ownerSide, coordinate: coordinate,
                               anchor: session.anchors[owner] ?? limit(current, axis: divider.axis, side: ownerSide))
            AXUIElementSetMessagingTimeout(owner.element, 0.1)
            owner.setFrame(target, primaryScreenHeight: session.primaryScreenHeight)
            ownerResult = owner.frame(primaryScreenHeight: session.primaryScreenHeight) ?? target
        }
        if let owner = session.owner, let ownerResult { frames[owner] = ownerResult }

        let expandingSide: Side = shrinkingSide == .low ? .high : .low
        let expandingPanes = expandingSide == .low ? divider.low : divider.high
        var expansionFrames = applyFrames(expandingPanes, side: expandingSide, coordinate: coordinate,
                                           session: session, nativeOwner: native ? session.owner : nil,
                                           ownerFrame: ownerResult, readBack: final, forceWrite: final)
        if final {
            for pane in expandingPanes {
                guard var actual = expansionFrames[pane.window] else { continue }
                let anchor = session.anchors[pane.window] ??
                    limit(pane.frame, axis: divider.axis, side: expandingSide)
                if abs(limit(actual, axis: divider.axis, side: expandingSide) - anchor) > 0.5 {
                    pane.window.setFrame(farEdgeAnchored(actual, axis: divider.axis, side: expandingSide, anchor: anchor),
                                         primaryScreenHeight: session.primaryScreenHeight)
                    guard let readBack = pane.window.frame(primaryScreenHeight: session.primaryScreenHeight) else { return nil }
                    actual = readBack
                    expansionFrames[pane.window] = actual
                }
            }
            let expandingEdges = expandingPanes.compactMap {
                expansionFrames[$0.window].map { edge($0, axis: divider.axis, side: expandingSide) }
            }
            let releaseCoordinate = increasing ? (expandingEdges.min() ?? coordinate) :
                (expandingEdges.max() ?? coordinate)
            if abs(releaseCoordinate - coordinate) > 0.1 {
                coordinate = releaseCoordinate
                let alignedFrames = applyFrames(shrinkingPanes, side: shrinkingSide, coordinate: coordinate,
                                                session: session, nativeOwner: nil, ownerFrame: nil,
                                                readBack: true, forceWrite: true)
                frames.merge(alignedFrames) { _, new in new }
            }
        }
        frames.merge(expansionFrames) { _, new in new }

        for index in divider.low.indices {
            let pane = divider.low[index]
            if let frame = frames[pane.window] { divider.low[index].frame = frame }
        }
        for index in divider.high.indices {
            let pane = divider.high[index]
            if let frame = frames[pane.window] { divider.high[index].frame = frame }
        }
        divider.coordinate = coordinate
        session.divider = divider
        if final { return verifyFinal(session, seededFrames: frames) }
        return ResizeResult(session: session, frames: frames)
    }

    private func constrainedCoordinate(_ requested: CGFloat, in session: ResizeSession) -> CGFloat {
        let divider = session.divider
        let minimum = divider.low.map {
            (session.anchors[$0.window] ?? limit($0.frame, axis: divider.axis, side: .low)) + 1
        }.max() ?? requested
        let maximum = divider.high.map {
            (session.anchors[$0.window] ?? limit($0.frame, axis: divider.axis, side: .high)) - 1
        }.min() ?? requested
        guard minimum <= maximum else { return divider.coordinate }
        var coordinate = min(max(requested, minimum), maximum)
        for pane in divider.high {
            if let limit = session.clampedEdges[pane.window], requested > limit {
                coordinate = min(coordinate, limit)
            }
        }
        for pane in divider.low {
            if let limit = session.clampedEdges[pane.window], requested < limit {
                coordinate = max(coordinate, limit)
            }
        }
        return coordinate
    }

    private func applyFrames(_ panes: [Pane], side: Side, coordinate: CGFloat, session: ResizeSession,
                             nativeOwner: AXWindow?, ownerFrame: CGRect?, readBack: Bool,
                             forceWrite: Bool = false) -> [AXWindow: CGRect] {
        let groups = Dictionary(grouping: panes, by: { $0.window.processIdentifier ?? 0 })
        let work = DispatchGroup()
        let lock = NSLock()
        var result: [AXWindow: CGRect] = [:]
        for (pid, appPanes) in groups {
            work.enter()
            (session.appQueues[pid] ?? DispatchQueue.global(qos: .userInteractive)).async {
                var appResult: [AXWindow: CGRect] = [:]
                for pane in appPanes {
                    if pane.window == nativeOwner {
                        appResult[pane.window] = ownerFrame ?? pane.frame
                        continue
                    }
                    let anchor = session.anchors[pane.window] ?? self.limit(pane.frame, axis: session.divider.axis, side: side)
                    let target = self.frame(pane.frame, axis: session.divider.axis, side: side,
                                            coordinate: coordinate, anchor: anchor)
                    guard forceWrite || !SnapGeometry.isClose(pane.frame, target, tolerance: 0.1) else {
                        appResult[pane.window] = pane.frame
                        continue
                    }
                    AXUIElementSetMessagingTimeout(pane.window.element, 0.1)
                    pane.window.setFrame(target, primaryScreenHeight: session.primaryScreenHeight)
                    appResult[pane.window] = readBack
                        ? (pane.window.frame(primaryScreenHeight: session.primaryScreenHeight) ?? target) : target
                }
                lock.lock()
                result.merge(appResult) { _, new in new }
                lock.unlock()
                work.leave()
            }
        }
        work.wait()
        return result
    }

    private func verifyFinal(_ session: ResizeSession, seededFrames: [AXWindow: CGRect] = [:]) -> ResizeResult {
        let panes = session.divider.low + session.divider.high
        let actualFrames = readFrames(panes, session: session)
        var divider = session.divider
        var frames = seededFrames
        frames.merge(actualFrames) { _, new in new }
        for index in divider.low.indices {
            let pane = divider.low[index]
            if let frame = frames[pane.window] { divider.low[index].frame = frame }
        }
        for index in divider.high.indices {
            let pane = divider.high[index]
            if let frame = frames[pane.window] { divider.high[index].frame = frame }
        }
        let edges = (divider.low.map { edge($0.frame, axis: divider.axis, side: .low) } +
                     divider.high.map { edge($0.frame, axis: divider.axis, side: .high) }).sorted()
        if !edges.isEmpty { divider.coordinate = edges[edges.count / 2] }
        var result = session
        result.divider = divider
        return ResizeResult(session: result, frames: frames)
    }

    private func readFrames(_ panes: [Pane], session: ResizeSession) -> [AXWindow: CGRect] {
        let groups = Dictionary(grouping: panes, by: { $0.window.processIdentifier ?? 0 })
        let work = DispatchGroup()
        let lock = NSLock()
        var result: [AXWindow: CGRect] = [:]
        for (pid, appPanes) in groups {
            work.enter()
            (session.appQueues[pid] ?? DispatchQueue.global(qos: .userInteractive)).async {
                var appResult: [AXWindow: CGRect] = [:]
                for pane in appPanes {
                    AXUIElementSetMessagingTimeout(pane.window.element, 0.1)
                    appResult[pane.window] = pane.window.frame(primaryScreenHeight: session.primaryScreenHeight) ?? pane.frame
                }
                lock.lock()
                result.merge(appResult) { _, new in new }
                lock.unlock()
                work.leave()
            }
        }
        work.wait()
        return result
    }

    private func limit(_ frame: CGRect, axis: Axis, side: Side) -> CGFloat {
        switch (axis, side) {
        case (.vertical, .low): return frame.minX
        case (.vertical, .high): return frame.maxX
        case (.horizontal, .low): return frame.minY
        case (.horizontal, .high): return frame.maxY
        }
    }

    private func edge(_ frame: CGRect, axis: Axis, side: Side) -> CGFloat {
        switch (axis, side) {
        case (.vertical, .low): return frame.maxX
        case (.vertical, .high): return frame.minX
        case (.horizontal, .low): return frame.maxY
        case (.horizontal, .high): return frame.minY
        }
    }

    private func frame(_ current: CGRect, axis: Axis, side: Side, coordinate: CGFloat, anchor: CGFloat) -> CGRect {
        var result = current
        switch (axis, side) {
        case (.vertical, .low):
            result.origin.x = anchor
            result.size.width = max(1, coordinate - anchor)
        case (.vertical, .high):
            result.origin.x = coordinate
            result.size.width = max(1, anchor - coordinate)
        case (.horizontal, .low):
            result.origin.y = anchor
            result.size.height = max(1, coordinate - anchor)
        case (.horizontal, .high):
            result.origin.y = coordinate
            result.size.height = max(1, anchor - coordinate)
        }
        return result
    }

    private func farEdgeAnchored(_ frame: CGRect, axis: Axis, side: Side, anchor: CGFloat) -> CGRect {
        var result = frame
        switch (axis, side) {
        case (.vertical, .low): result.origin.x = anchor
        case (.vertical, .high): result.origin.x = anchor - frame.width
        case (.horizontal, .low): result.origin.y = anchor
        case (.horizontal, .high): result.origin.y = anchor - frame.height
        }
        return result
    }
}

private final class SnapDividerPanel: NSPanel {
    private let dividerView: SnapDividerView

    init(mouseDown: @escaping (NSEvent) -> Void, mouseDragged: @escaping () -> Void, mouseUp: @escaping () -> Void) {
        dividerView = SnapDividerView(mouseDown: mouseDown, mouseDragged: mouseDragged, mouseUp: mouseUp)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        level = .floating
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = dividerView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(frame: CGRect, vertical: Bool) {
        dividerView.vertical = vertical
        let changed = self.frame != frame
        if changed { setFrame(frame, display: true) }
        if !isVisible || changed { orderFrontRegardless() }
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }
}

private final class SnapDividerView: NSView {
    var vertical = true {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private let onMouseDown: (NSEvent) -> Void
    private let onMouseDragged: () -> Void
    private let onMouseUp: () -> Void

    init(mouseDown: @escaping (NSEvent) -> Void, mouseDragged: @escaping () -> Void, mouseUp: @escaping () -> Void) {
        onMouseDown = mouseDown
        onMouseDragged = mouseDragged
        onMouseUp = mouseUp
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseEntered(with event: NSEvent) {
        (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        for offset in [-3.0, 0, 3.0] {
            let dot = vertical
                ? CGRect(x: bounds.midX - 1.5, y: bounds.midY + offset - 0.5, width: 3, height: 1)
                : CGRect(x: bounds.midX + offset - 0.5, y: bounds.midY - 1.5, width: 1, height: 3)
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged() }
    override func mouseUp(with event: NSEvent) { onMouseUp() }
}
