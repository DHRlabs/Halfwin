import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class DockPreviewManager {
    private struct Selection {
        let token: Int
        let item: AXUIElement
        let app: NSRunningApplication
    }

    private struct CachedThumbnail {
        let image: CGImage
    }

    private struct CGWindowRecord {
        let id: CGWindowID
        let processID: pid_t
        let frame: CGRect?
        let title: String?
        let isOnScreen: Bool
    }

    private struct MatchedWindow {
        let window: AXWindow
        let record: CGWindowRecord
    }

    private struct MinimizedWindowSet {
        var windows: [AXWindow]
        var focusedWindow: AXWindow?
    }

    private struct DockClick {
        let itemFrame: CGRect
        let app: NSRunningApplication
        let mouseDownPoint: CGPoint
        let mouseDownTimestamp: TimeInterval
        let mouseDownGeneration: Int
        let windowsToMinimize: [AXWindow]
        let focusedWindow: AXWindow?
        let previousMinimizedSet: MinimizedWindowSet?
        let windowsToRestore: MinimizedWindowSet?
    }

    private struct CachedShareableContent {
        let content: SCShareableContent
        let loadedAt: Date
    }

    private var previewsEnabled = false
    private var clickToMinimizeEnabled = false
    private var running = false
    private var permissionTimer: Timer?
    private var dockRetryTimer: Timer?
    private var dockProcessTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var hoverTimer: Timer?
    private var hideTimer: Timer?
    private var pointerTimer: Timer?
    private var clickMonitor: Any?
    private var pendingDockClick: DockClick?
    private var dockClickInFlight = false
    private var mouseDownGeneration = 0
    private var observer: AXObserver?
    private var observedList: AXUIElement?
    private var observerSource: CFRunLoopSource?
    private var minimizeObserver: AXObserver?
    private var minimizeObserverSource: CFRunLoopSource?
    private var minimizeObserverPID: pid_t?
    private var observedWindowElements: [Int: AXUIElement] = [:]
    private var minimizedWindowsByApp: [pid_t: MinimizedWindowSet] = [:]
    private var dockPID: pid_t?
    private var dockRestartPending = false
    private var selection: Selection?
    private var activeApp: NSRunningApplication?
    private var windows: [Int: AXWindow] = [:]
    private var generation = 0
    private var isShowing = false
    private var captureTask: Task<Void, Never>?
    private var thumbnailCache: [CGWindowID: CachedThumbnail] = [:]
    private var shareableContentCache: CachedShareableContent?
    private var shareableContentTask: Task<(SCShareableContent?, Date), Never>?
    private var shareableContentRequestID: UUID?
    private let panel = DockPreviewPanel()

    init() {
        panel.onSelect = { [weak self] in self?.selectWindow($0) }
    }

    func setEnabled(_ enabled: Bool) {
        previewsEnabled = enabled
        if enabled {
            startWorkspaceObserver()
        } else {
            stopWorkspaceObserver()
            hidePreview()
            thumbnailCache.removeAll()
        }
        refreshPermission()
    }

    func setClickToMinimizeEnabled(_ enabled: Bool) {
        clickToMinimizeEnabled = enabled
        if !enabled {
            pendingDockClick = nil
            dockClickInFlight = false
            mouseDownGeneration += 1
            minimizedWindowsByApp.removeAll()
        }
        refreshPermission()
    }

    func refreshPermission() {
        guard previewsEnabled || clickToMinimizeEnabled else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            stopRuntime()
            return
        }
        guard Permissions.accessibilityGranted else {
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshPermission() }
                }
            }
            stopRuntime()
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        startRuntime()
        checkDockProcess()
    }

    func stop() {
        previewsEnabled = false
        clickToMinimizeEnabled = false
        pendingDockClick = nil
        dockClickInFlight = false
        mouseDownGeneration += 1
        minimizedWindowsByApp.removeAll()
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopRuntime()
    }

    private func startRuntime() {
        guard !running else { return }
        running = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let eventType = event.type
            let point = event.cgEvent?.location
            let timestamp = event.timestamp
            let clickCount = event.clickCount
            let modifierFlags = event.modifierFlags
            let frontmost = eventType == .leftMouseDown ? NSWorkspace.shared.frontmostApplication : nil
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if eventType == .leftMouseDown {
                        self.handleGlobalMouseDown(
                            at: point,
                            timestamp: timestamp,
                            clickCount: clickCount,
                            modifierFlags: modifierFlags,
                            frontmost: frontmost
                        )
                    } else if eventType == .leftMouseUp {
                        self.handleGlobalMouseUp(
                            at: point,
                            timestamp: timestamp,
                            clickCount: clickCount,
                            modifierFlags: modifierFlags
                        )
                    }
                }
            }
        }
        dockProcessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkDockProcess()
                if self.previewsEnabled, !self.thumbnailCache.isEmpty {
                    self.pruneThumbnailCache()
                }
            }
        }
        startWorkspaceObserver()
        startDockObserver()
    }

    private func stopRuntime() {
        guard running else { return }
        running = false
        dockProcessTimer?.invalidate()
        dockProcessTimer = nil
        dockRetryTimer?.invalidate()
        dockRetryTimer = nil
        stopWorkspaceObserver()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        stopDockObserver()
        stopWindowMinimizationObserver()
        dockPID = nil
        dockRestartPending = false
        thumbnailCache.removeAll()
        shareableContentTask?.cancel()
        shareableContentTask = nil
        shareableContentRequestID = nil
        shareableContentCache = nil
        hidePreview()
    }

    private func startWorkspaceObserver() {
        guard running, previewsEnabled, workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.applicationDidDeactivate(notification) }
        }
    }

    private func stopWorkspaceObserver() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        self.workspaceObserver = nil
    }

    private func checkDockProcess() {
        guard running else { return }
        let currentPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated })?.processIdentifier
        guard currentPID != dockPID else { return }
        dockPID = currentPID
        restartDockObserver()
    }

    private func startDockObserver() {
        guard running, Permissions.accessibilityGranted, observer == nil else { return }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated }) else {
            dockPID = nil
            retryDockObserver()
            return
        }
        dockPID = dock.processIdentifier
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let children: [AXUIElement] = attribute(application, kAXChildrenAttribute),
              let list = children.first(where: { child in
                  AXUIElementSetMessagingTimeout(child, 0.1)
                  return AXWindow.role(of: child) == kAXListRole
              }) else {
            retryDockObserver()
            return
        }

        var createdObserver: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, dockPreviewNotificationReceived, &createdObserver) == .success,
              let createdObserver else {
            retryDockObserver()
            return
        }
        AXUIElementSetMessagingTimeout(list, 0.1)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            createdObserver, list, kAXSelectedChildrenChangedNotification as CFString, context
        ) == .success else {
            retryDockObserver()
            return
        }
        guard AXObserverAddNotification(
            createdObserver, list, kAXUIElementDestroyedNotification as CFString, context
        ) == .success else {
            AXObserverRemoveNotification(createdObserver, list, kAXSelectedChildrenChangedNotification as CFString)
            retryDockObserver()
            return
        }
        observer = createdObserver
        observedList = list
        observerSource = AXObserverGetRunLoopSource(createdObserver)
        if let observerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), observerSource, .commonModes)
        }
        dockRetryTimer?.invalidate()
        dockRetryTimer = nil
        dockSelectionChanged()
    }

    private func retryDockObserver() {
        guard dockRetryTimer == nil else { return }
        dockRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startDockObserver() }
        }
    }

    private func restartDockObserver() {
        guard running, !dockRestartPending else { return }
        dockRestartPending = true
        dockRetryTimer?.invalidate()
        dockRetryTimer = nil
        stopDockObserver()
        hidePreview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.dockRestartPending = false
            self.startDockObserver()
        }
    }

    private func stopDockObserver() {
        if let observer, let observedList {
            AXObserverRemoveNotification(observer, observedList, kAXSelectedChildrenChangedNotification as CFString)
            AXObserverRemoveNotification(observer, observedList, kAXUIElementDestroyedNotification as CFString)
        }
        if let observerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), observerSource, .commonModes)
        }
        observer = nil
        observedList = nil
        observerSource = nil
    }

    private func observeWindowMinimization(in app: NSRunningApplication, windows: [AXWindow]) {
        guard running, Permissions.accessibilityGranted else { return }
        let processID = app.processIdentifier
        if minimizeObserverPID != processID { stopWindowMinimizationObserver() }
        if minimizeObserver == nil {
            var createdObserver: AXObserver?
            guard AXObserverCreate(processID, dockWindowNotificationReceived, &createdObserver) == .success,
                  let createdObserver else { return }
            minimizeObserver = createdObserver
            minimizeObserverPID = processID
            minimizeObserverSource = AXObserverGetRunLoopSource(createdObserver)
            if let minimizeObserverSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), minimizeObserverSource, .commonModes)
            }
        }
        guard let minimizeObserver else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for window in windows {
            let id = Int(truncatingIfNeeded: CFHash(window.element))
            guard observedWindowElements[id] == nil else { continue }
            AXUIElementSetMessagingTimeout(window.element, 0.1)
            guard AXObserverAddNotification(
                minimizeObserver, window.element, kAXWindowMiniaturizedNotification as CFString, context
            ) == .success else { continue }
            observedWindowElements[id] = window.element
            AXObserverAddNotification(
                minimizeObserver, window.element, kAXUIElementDestroyedNotification as CFString, context
            )
        }
    }

    private func stopWindowMinimizationObserver() {
        if let minimizeObserver {
            for element in observedWindowElements.values {
                AXObserverRemoveNotification(minimizeObserver, element, kAXWindowMiniaturizedNotification as CFString)
                AXObserverRemoveNotification(minimizeObserver, element, kAXUIElementDestroyedNotification as CFString)
            }
        }
        if let minimizeObserverSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), minimizeObserverSource, .commonModes)
        }
        minimizeObserver = nil
        minimizeObserverSource = nil
        minimizeObserverPID = nil
        observedWindowElements.removeAll()
    }

    func windowWillMinimize(_ element: AXUIElement) {
        guard previewsEnabled, running, Permissions.accessibilityGranted,
              Permissions.screenRecordingGranted else { return }
        AXUIElementSetMessagingTimeout(element, 0.1)
        let window = AXWindow(element: element)
        guard let processID = window.processIdentifier,
              let record = matchingWindow(
                window,
                among: windowRecords(processID: processID, options: .optionAll),
                excluding: []
              ) else { return }
        let tileID = Int(truncatingIfNeeded: CFHash(element))
        let visibleTile = isShowing && windows[tileID] != nil ? tileID : nil
        let captureGeneration = generation
        Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  let content = await self.shareableContentForCapture(),
                  !Task.isCancelled,
                  let image = await captureWindowImages([record.id], content: content)[record.id] else { return }
            if let visibleTile {
                await self.setCapturedImage(image, for: visibleTile, windowID: record.id, generation: captureGeneration)
            } else {
                await self.setWarmedThumbnail(image, windowID: record.id)
            }
        }
    }

    func windowElementDestroyed(_ element: AXUIElement) {
        let id = Int(truncatingIfNeeded: CFHash(element))
        guard let tracked = observedWindowElements.removeValue(forKey: id), let minimizeObserver else { return }
        AXObserverRemoveNotification(minimizeObserver, tracked, kAXWindowMiniaturizedNotification as CFString)
        AXObserverRemoveNotification(minimizeObserver, tracked, kAXUIElementDestroyedNotification as CFString)
    }

    func dockElementDestroyed() {
        restartDockObserver()
    }

    func dockSelectionChanged() {
        guard running, previewsEnabled, Permissions.accessibilityGranted, let observedList else {
            if isShowing { hidePreview() }
            return
        }
        if dockClickInFlight {
            hidePreview()
            return
        }
        let pointer = NSEvent.mouseLocation
        AXUIElementSetMessagingTimeout(observedList, 0.1)
        guard let listFrame = AXWindow.frame(of: observedList),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(listFrame) }) else {
            clearSelection()
            scheduleHide()
            return
        }
        let orientation: String? = attribute(observedList, kAXOrientationAttribute)
        guard frameExtendedToDockEdge(listFrame, dockListFrame: listFrame, screenFrame: screen.frame, orientation: orientation).contains(pointer) else {
            clearSelection()
            scheduleHide()
            return
        }
        prefetchShareableContent()
        guard !isShowing || !panel.frame.contains(pointer) else {
            clearSelection()
            scheduleHide()
            return
        }
        guard let items: [AXUIElement] = attribute(observedList, kAXSelectedChildrenAttribute),
              let item = items.first else {
            clearSelection()
            scheduleHide()
            return
        }
        AXUIElementSetMessagingTimeout(item, 0.1)
        if let isRunning: NSNumber = attribute(item, kAXIsApplicationRunningAttribute), isRunning.intValue == 0 {
            clearSelection()
            scheduleHide()
            return
        }
        guard AXWindow.frame(of: item) != nil else {
            clearSelection()
            scheduleHide()
            return
        }
        guard let app = runningApplication(forDockItem: item) else {
            clearSelection()
            scheduleHide()
            return
        }

        let next = Selection(token: Int(truncatingIfNeeded: CFHash(item)), item: item, app: app)
        selection = next
        hideTimer?.invalidate()
        hideTimer = nil
        guard activeApp?.processIdentifier != app.processIdentifier || !isShowing else { return }
        hoverTimer?.invalidate()
        hoverTimer = nil
        if isShowing {
            showPreview(for: next)
            return
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.selection, current.token == next.token else { return }
                self.hoverTimer = nil
                let pointer = NSEvent.mouseLocation
                guard let list = self.observedList else {
                    self.clearSelection()
                    self.scheduleHide()
                    return
                }
                AXUIElementSetMessagingTimeout(list, 0.1)
                AXUIElementSetMessagingTimeout(current.item, 0.1)
                guard let listFrame = AXWindow.frame(of: list),
                      let screen = NSScreen.screens.first(where: { $0.frame.intersects(listFrame) }),
                      let itemFrame = AXWindow.frame(of: current.item) else {
                    self.clearSelection()
                    self.scheduleHide()
                    return
                }
                let orientation: String? = self.attribute(list, kAXOrientationAttribute)
                guard self.frameExtendedToDockEdge(listFrame, dockListFrame: listFrame, screenFrame: screen.frame, orientation: orientation).contains(pointer),
                      self.frameExtendedToDockEdge(itemFrame, dockListFrame: listFrame, screenFrame: screen.frame, orientation: orientation).contains(pointer),
                      !self.isShowing || !self.panel.frame.contains(pointer) else {
                    self.clearSelection()
                    self.scheduleHide()
                    return
                }
                self.showPreview(for: current)
            }
        }
    }

    private func handleGlobalMouseDown(
        at point: CGPoint?,
        timestamp: TimeInterval,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags,
        frontmost: NSRunningApplication?
    ) {
        mouseDownGeneration += 1
        let clickGeneration = mouseDownGeneration
        if isShowing { hidePreview() }
        pendingDockClick = nil
        dockClickInFlight = false
        guard ProcessInfo.processInfo.systemUptime - timestamp <= 0.05,
              clickToMinimizeEnabled, Permissions.accessibilityGranted,
              clickCount == 1, !hasUnsupportedModifiers(modifierFlags), let point else { return }
        checkDockProcess()
        guard let item = dockApplicationDockItem(atQuartzPoint: point),
              let app = runningApplication(forDockItem: item) else { return }

        let processID = app.processIdentifier
        let frontmostPID = frontmost?.processIdentifier
        guard frontmostPID == processID || minimizedWindowsByApp[processID] != nil else { return }
        guard let itemFrame = AXWindow.frame(of: item) else { return }
        let appWindows = AXWindow.standardWindows(of: app)
        let onScreenRecords = windowRecords(options: .optionOnScreenOnly)
        let appRecords = onScreenRecords.filter { $0.processID == processID }
        let matchedWindows = visibleStandardWindows(of: appWindows, among: appRecords)
        let visibleWindows = matchedWindows.map(\.window)
        let previousSet = prunedMinimizedSet(for: processID)
        let restoreSet = visibleWindows.isEmpty ? previousSet : nil
        guard restoreSet != nil
                || (onScreenRecords.first?.processID == processID
                    && !visibleWindows.isEmpty) else { return }

        let focusedWindow = AXWindow.focusedWindow(of: app).flatMap { visibleWindows.contains($0) ? $0 : nil }
        observeWindowMinimization(in: app, windows: appWindows)
        pendingDockClick = DockClick(
            itemFrame: itemFrame,
            app: app,
            mouseDownPoint: point,
            mouseDownTimestamp: timestamp,
            mouseDownGeneration: clickGeneration,
            windowsToMinimize: visibleWindows,
            focusedWindow: focusedWindow,
            previousMinimizedSet: previousSet,
            windowsToRestore: restoreSet
        )
        dockClickInFlight = true
        if restoreSet == nil {
            warmThumbnails(matchedWindows.map(\.record.id))
        }
    }

    private func handleGlobalMouseUp(
        at point: CGPoint?,
        timestamp: TimeInterval,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let click = pendingDockClick else { return }
        pendingDockClick = nil
        let pressDuration = timestamp - click.mouseDownTimestamp
        guard ProcessInfo.processInfo.systemUptime - timestamp <= 0.05,
              clickToMinimizeEnabled, Permissions.accessibilityGranted,
              clickCount == 1, !hasUnsupportedModifiers(modifierFlags),
              pressDuration >= 0, pressDuration < 0.4,
              let point,
              hypot(point.x - click.mouseDownPoint.x, point.y - click.mouseDownPoint.y) <= 4,
              click.itemFrame.contains(point.axFlipped),
              click.mouseDownGeneration == mouseDownGeneration else {
            dockClickInFlight = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
            guard let self, self.mouseDownGeneration == click.mouseDownGeneration else { return }
            self.performDockIconClick(click)
        }
    }

    private func hasUnsupportedModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    private func performDockIconClick(_ click: DockClick) {
        defer { dockClickInFlight = false }
        guard clickToMinimizeEnabled, Permissions.accessibilityGranted,
              !click.app.isTerminated,
              NSWorkspace.shared.runningApplications.contains(where: {
                  $0.processIdentifier == click.app.processIdentifier
              }) else { return }
        hidePreview()

        if let restoreSet = click.windowsToRestore {
            let existing = Set(AXWindow.standardWindows(of: click.app))
            let restoreWindows = restoreSet.windows.filter { existing.contains($0) }
            guard !restoreWindows.isEmpty else {
                minimizedWindowsByApp.removeValue(forKey: click.app.processIdentifier)
                return
            }
            for window in restoreWindows { window.setMinimized(false) }
            let focused = restoreSet.focusedWindow.flatMap { restoreWindows.contains($0) ? $0 : nil }
                ?? restoreWindows.first
            focused?.restoreAndRaise(in: click.app)
            minimizedWindowsByApp.removeValue(forKey: click.app.processIdentifier)
            return
        }

        guard !click.windowsToMinimize.isEmpty else { return }
        for window in click.windowsToMinimize { window.setMinimized(true) }
        let remembered = click.previousMinimizedSet?.windows ?? []
        let combined = remembered + click.windowsToMinimize.filter { !remembered.contains($0) }
        guard !combined.isEmpty else { return }
        let focused = click.focusedWindow ?? click.previousMinimizedSet?.focusedWindow
        minimizedWindowsByApp[click.app.processIdentifier] = MinimizedWindowSet(
            windows: combined,
            focusedWindow: focused
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self,
                  self.mouseDownGeneration == click.mouseDownGeneration,
                  self.clickToMinimizeEnabled,
                  let saved = self.minimizedWindowsByApp[click.app.processIdentifier] else { return }
            for window in saved.windows where !window.isMinimized {
                window.setMinimized(true)
            }
        }
    }

    private func visibleStandardWindows(of windows: [AXWindow], among visibleFrames: [CGWindowRecord]) -> [MatchedWindow] {
        var usedWindowIDs = Set<CGWindowID>()
        return windows.compactMap { window in
            guard !window.isMinimized,
                  let frame = window.frame,
                  let match = visibleFrames.first(where: { candidate in
                      !usedWindowIDs.contains(candidate.id)
                          && candidate.frame.map { SnapGeometry.isClose(frame, $0, tolerance: 4) } == true
                  }) else { return nil }
            usedWindowIDs.insert(match.id)
            return MatchedWindow(window: window, record: match)
        }
    }

    private func prunedMinimizedSet(for processID: pid_t) -> MinimizedWindowSet? {
        guard var saved = minimizedWindowsByApp[processID] else { return nil }
        saved.windows = saved.windows.filter(\.isMinimized)
        if let focusedWindow = saved.focusedWindow, !saved.windows.contains(focusedWindow) {
            saved.focusedWindow = nil
        }
        guard !saved.windows.isEmpty else {
            minimizedWindowsByApp.removeValue(forKey: processID)
            return nil
        }
        minimizedWindowsByApp[processID] = saved
        return saved
    }

    private func dockApplicationDockItem(atQuartzPoint point: CGPoint) -> AXUIElement? {
        guard let dockPID, let observedList else { return nil }
        AXUIElementSetMessagingTimeout(observedList, 0.1)
        guard let listFrame = AXWindow.frame(of: observedList),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(listFrame) }) else { return nil }
        let orientation: String? = attribute(observedList, kAXOrientationAttribute)
        guard frameExtendedToDockEdge(
            listFrame,
            dockListFrame: listFrame,
            screenFrame: screen.frame,
            orientation: orientation
        ).contains(point.axFlipped),
        var current = AXWindow.element(atQuartzPoint: point) else { return nil }

        var firstProcessID: pid_t = 0
        guard AXUIElementGetPid(current, &firstProcessID) == .success,
              firstProcessID == dockPID else { return nil }
        for _ in 0..<8 {
            AXUIElementSetMessagingTimeout(current, 0.1)
            if AXWindow.subrole(of: current) == (kAXApplicationDockItemSubrole as String) {
                return current
            }
            guard let parent: AXUIElement = attribute(current, kAXParentAttribute) else { break }
            var parentProcessID: pid_t = 0
            guard AXUIElementGetPid(parent, &parentProcessID) == .success,
                  parentProcessID == dockPID else { return nil }
            current = parent
        }
        return nil
    }

    private func runningApplication(forDockItem item: AXUIElement) -> NSRunningApplication? {
        guard let url = appURL(of: item) else { return nil }
        let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let standardizedURL = url.standardizedFileURL
        return runningApps.first { $0.bundleURL?.standardizedFileURL == standardizedURL }
            ?? runningApps.first { candidate in
                guard let bundleURL = candidate.bundleURL else { return false }
                return bundleURL.resolvingSymlinksInPath().standardizedFileURL
                    == url.resolvingSymlinksInPath().standardizedFileURL
            }
    }

    private func clearSelection() {
        selection = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func showPreview(for selection: Selection) {
        captureTask?.cancel()
        captureTask = nil
        generation += 1
        let captureGeneration = generation
        guard let list = observedList else {
            hidePreview()
            return
        }
        AXUIElementSetMessagingTimeout(list, 0.1)
        AXUIElementSetMessagingTimeout(selection.item, 0.1)
        guard let listFrame = AXWindow.frame(of: list),
              let itemFrame = AXWindow.frame(of: selection.item),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(listFrame) }) else {
            hidePreview()
            return
        }

        let processID = selection.app.processIdentifier
        let allRecords = windowRecords(options: .optionAll)
        let allFrames = allRecords.filter { $0.processID == processID }
        let visibleFrames = allFrames.filter(\.isOnScreen)
        pruneThumbnailCache(keeping: Set(allRecords.map(\.id)))
        let hiddenApp = selection.app.isHidden
        var usedWindowIDs = Set<CGWindowID>()
        var tileItems: [DockPreviewItem] = []
        var nextWindows: [Int: AXWindow] = [:]
        var screenshotIDs: [Int: CGWindowID] = [:]
        let icon = selection.app.icon ?? NSWorkspace.shared.icon(forFile: selection.app.bundleURL?.path ?? "")

        let appWindows = AXWindow.standardWindows(of: selection.app)
        for window in appWindows {
            let minimized = window.isMinimized
            let record = minimized
                ? matchingWindow(window, among: allFrames, excluding: usedWindowIDs)
                : visibleFrames.first { candidate in
                    !usedWindowIDs.contains(candidate.id) && candidate.frame.map { frame in
                        window.frame.map { SnapGeometry.isClose($0, frame, tolerance: 4) } == true
                    } == true
                }
            let visible = minimized ? nil : record
            guard minimized || visible != nil || hiddenApp else { continue }
            if let record { usedWindowIDs.insert(record.id) }
            let id = Int(truncatingIfNeeded: CFHash(window.element))
            tileItems.append(DockPreviewItem(id: id, title: window.title ?? "Untitled window", appIcon: icon, minimized: minimized))
            nextWindows[id] = window
            if let record { screenshotIDs[id] = record.id }
        }
        guard !tileItems.isEmpty else {
            hidePreview()
            return
        }

        windows = nextWindows
        observeWindowMinimization(in: selection.app, windows: appWindows)
        activeApp = selection.app
        isShowing = true
        let orientation: String? = attribute(list, kAXOrientationAttribute)
        let edge = dockEdge(for: listFrame, screen: screen.frame, orientation: orientation)
        panel.show(items: tileItems, edge: edge, dockFrame: listFrame, itemFrame: itemFrame, visibleFrame: screen.visibleFrame)
        startPointerTimer()
        captureThumbnails(screenshotIDs, generation: captureGeneration)
    }

    private func captureThumbnails(_ idsByTile: [Int: CGWindowID], generation: Int) {
        guard !idsByTile.isEmpty else { return }
        for (tileID, windowID) in idsByTile {
            if let cached = thumbnailCache[windowID] {
                panel.setImage(NSImage(cgImage: cached.image, size: .zero), for: tileID)
            }
        }
        guard Permissions.screenRecordingGranted else { return }
        captureTask = Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  let content = await self.shareableContentForCapture(),
                  !Task.isCancelled else { return }
            let images = await captureWindowImages(Array(Set(idsByTile.values)), content: content)
            guard !Task.isCancelled else { return }
            for (tileID, windowID) in idsByTile {
                guard let image = images[windowID] else { continue }
                await self.setCapturedImage(image, for: tileID, windowID: windowID, generation: generation)
            }
        }
    }

    private func applicationDidDeactivate(_ notification: Notification) {
        guard previewsEnabled, Permissions.accessibilityGranted, Permissions.screenRecordingGranted,
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let windowIDs = windowRecords(processID: app.processIdentifier, options: .optionOnScreenOnly).map(\.id)
        guard !windowIDs.isEmpty else { return }
        pruneThumbnailCache()
        warmThumbnails(windowIDs)
    }

    private func warmThumbnails(_ windowIDs: [CGWindowID]) {
        guard previewsEnabled, running, Permissions.screenRecordingGranted, !windowIDs.isEmpty else { return }
        prefetchShareableContent()
        _ = Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  let content = await self.shareableContentForCapture(),
                  !Task.isCancelled else { return }
            let images = await captureWindowImages(windowIDs, content: content)
            guard !Task.isCancelled else { return }
            for (windowID, image) in images {
                await self.setWarmedThumbnail(image, windowID: windowID)
            }
        }
    }

    private func prefetchShareableContent() {
        if let cache = shareableContentCache, Date().timeIntervalSince(cache.loadedAt) <= 2 { return }
        guard shareableContentTask == nil else { return }
        let requestID = UUID()
        let task = Task.detached(priority: .utility) {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return (content, Date())
        }
        shareableContentTask = task
        shareableContentRequestID = requestID
        Task { [weak self] in
            let (content, loadedAt) = await task.value
            guard let self, self.shareableContentRequestID == requestID else { return }
            if let content {
                self.shareableContentCache = CachedShareableContent(content: content, loadedAt: loadedAt)
            }
            self.shareableContentTask = nil
            self.shareableContentRequestID = nil
        }
    }

    private func shareableContentForCapture() async -> SCShareableContent? {
        if let cache = shareableContentCache, Date().timeIntervalSince(cache.loadedAt) <= 2 {
            return cache.content
        }
        prefetchShareableContent()
        guard let task = shareableContentTask, let requestID = shareableContentRequestID else { return nil }
        let (content, loadedAt) = await task.value
        if shareableContentRequestID == requestID {
            if let content {
                shareableContentCache = CachedShareableContent(content: content, loadedAt: loadedAt)
            }
            shareableContentTask = nil
            shareableContentRequestID = nil
        }
        return content
    }

    private func setCapturedImage(_ image: CGImage, for id: Int, windowID: CGWindowID, generation: Int) {
        guard running, previewsEnabled, Permissions.screenRecordingGranted,
              !thumbnailImageIsBlank(image) else { return }
        thumbnailCache[windowID] = CachedThumbnail(image: image)
        guard self.generation == generation, isShowing else { return }
        panel.setImage(NSImage(cgImage: image, size: .zero), for: id)
    }

    private func setWarmedThumbnail(_ image: CGImage, windowID: CGWindowID) {
        guard running, previewsEnabled, Permissions.screenRecordingGranted,
              !thumbnailImageIsBlank(image) else { return }
        thumbnailCache[windowID] = CachedThumbnail(image: image)
    }

    private func selectWindow(_ id: Int) {
        guard let app = activeApp, let window = windows[id] else { return }
        if app.isHidden { app.unhide() }
        window.restoreAndRaise(in: app)
        hidePreview()
    }

    private func startPointerTimer() {
        guard pointerTimer == nil else { return }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                let pointer = NSEvent.mouseLocation
                if self.pointerIsOverDock(pointer) || self.panel.frame.contains(pointer) {
                    self.hideTimer?.invalidate()
                    self.hideTimer = nil
                } else {
                    self.scheduleHide()
                }
            }
        }
    }

    private func pointerIsOverDock(_ pointer: CGPoint) -> Bool {
        guard let observedList else { return false }
        AXUIElementSetMessagingTimeout(observedList, 0.1)
        guard let listFrame = AXWindow.frame(of: observedList),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(listFrame) }) else { return false }
        let orientation: String? = attribute(observedList, kAXOrientationAttribute)
        return frameExtendedToDockEdge(listFrame, dockListFrame: listFrame, screenFrame: screen.frame, orientation: orientation).contains(pointer)
    }

    private func scheduleHide() {
        guard isShowing, hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                let pointer = NSEvent.mouseLocation
                if !self.pointerIsOverDock(pointer) && !self.panel.frame.contains(pointer) { self.hidePreview() }
            }
        }
    }

    private func hidePreview() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        clearSelection()
        panel.hide()
        isShowing = false
        activeApp = nil
        windows.removeAll()
        pointerTimer?.invalidate()
        pointerTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func windowRecords(processID: pid_t, options: CGWindowListOption) -> [CGWindowRecord] {
        windowRecords(options: options).filter { $0.processID == processID }
    }

    private func windowRecords(options: CGWindowListOption) -> [CGWindowRecord] {
        // On-screen-only keeps previews on the current Space; other Spaces require private APIs.
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber else { return nil }
            let bounds = entry[kCGWindowBounds as String] as? NSDictionary
            let frame = bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary)?.axFlipped }
            let rawTitle = entry[kCGWindowName as String] as? String
            let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            return CGWindowRecord(
                id: CGWindowID(number.uint32Value),
                processID: processID,
                frame: frame,
                title: title?.isEmpty == false ? title : nil,
                isOnScreen: isOnScreen
            )
        }
    }

    private func matchingWindow(
        _ window: AXWindow,
        among candidates: [CGWindowRecord],
        excluding usedWindowIDs: Set<CGWindowID>
    ) -> CGWindowRecord? {
        let available = candidates.filter { !$0.isOnScreen && !usedWindowIDs.contains($0.id) }
        if let title = window.title {
            let titleMatches = available.filter { $0.title?.localizedCaseInsensitiveCompare(title) == .orderedSame }
            if titleMatches.count == 1 { return titleMatches[0] }
            if !titleMatches.isEmpty { return closestSizeMatch(window.frame, among: titleMatches) }
        }
        return closestSizeMatch(window.frame, among: available)
    }

    private func closestSizeMatch(_ frame: CGRect?, among candidates: [CGWindowRecord]) -> CGWindowRecord? {
        guard let frame else { return nil }
        let matches = candidates.compactMap { candidate -> (CGWindowRecord, CGFloat)? in
            guard let candidateFrame = candidate.frame else { return nil }
            let distance = abs(candidateFrame.width - frame.width) + abs(candidateFrame.height - frame.height)
            return (candidate, distance)
        }
        guard let closestDistance = matches.map({ $0.1 }).min(), closestDistance <= 16,
              let closest = matches.first(where: { $0.1 == closestDistance }),
              matches.filter({ $0.1 == closestDistance }).count == 1 else { return nil }
        return closest.0
    }

    private func pruneThumbnailCache() {
        guard previewsEnabled, !thumbnailCache.isEmpty else { return }
        pruneThumbnailCache(keeping: Set(windowRecords(options: .optionAll).map(\.id)))
    }

    private func pruneThumbnailCache(keeping existingIDs: Set<CGWindowID>) {
        guard previewsEnabled, !thumbnailCache.isEmpty else { return }
        thumbnailCache = thumbnailCache.filter { existingIDs.contains($0.key) }
    }

    private func appURL(of item: AXUIElement) -> URL? {
        if let url: URL = attribute(item, kAXURLAttribute) { return url }
        if let value: String = attribute(item, kAXURLAttribute) {
            return URL(string: value) ?? URL(fileURLWithPath: value)
        }
        return nil
    }

    private func dockEdge(for listFrame: CGRect, screen: CGRect, orientation: String?) -> DockPreviewEdge {
        if orientation == kAXHorizontalOrientationValue { return .bottom }
        guard orientation == kAXVerticalOrientationValue else { return .bottom }
        let leftDistance = abs(listFrame.minX - screen.minX)
        let rightDistance = abs(screen.maxX - listFrame.maxX)
        return leftDistance <= rightDistance ? .left : .right
    }

    private func frameExtendedToDockEdge(
        _ frame: CGRect,
        dockListFrame: CGRect,
        screenFrame: CGRect,
        orientation: String?
    ) -> CGRect {
        switch dockEdge(for: dockListFrame, screen: screenFrame, orientation: orientation) {
        case .bottom:
            let minY = min(frame.minY, screenFrame.minY)
            return CGRect(x: frame.minX, y: minY, width: frame.width, height: frame.maxY - minY)
        case .left:
            let minX = min(frame.minX, screenFrame.minX)
            return CGRect(x: minX, y: frame.minY, width: frame.maxX - minX, height: frame.height)
        case .right:
            let maxX = max(frame.maxX, screenFrame.maxX)
            return CGRect(x: frame.minX, y: frame.minY, width: maxX - frame.minX, height: frame.height)
        }
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

private func captureWindowImages(_ ids: [CGWindowID], content: SCShareableContent) async -> [CGWindowID: CGImage] {
    let windowsByID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
    var images: [CGWindowID: CGImage] = [:]
    await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
        for id in Set(ids) {
            guard let window = windowsByID[id] else { continue }
            group.addTask {
                (id, await captureWindowThumbnail(window))
            }
        }
        for await (id, image) in group {
            if let image { images[id] = image }
        }
    }
    return images
}

private func captureWindowThumbnail(_ window: SCWindow) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.width = 320
    configuration.height = max(1, Int(CGFloat(configuration.width) * window.frame.height / max(window.frame.width, 1)))
    configuration.showsCursor = false
    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
          !Task.isCancelled else {
        return nil
    }
    return image
}

private func thumbnailImageIsBlank(_ image: CGImage) -> Bool {
    let side = 16
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let result: Bool? = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = buffer.bindMemory(to: UInt8.self)
        let colors = (0..<(side * side)).map { index in
            let offset = index * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
        guard let first = colors.first else { return false }
        return colors.allSatisfy { $0.3 == 0 }
            || colors.allSatisfy {
                abs(Int($0.0) - Int(first.0)) <= 8
                    && abs(Int($0.1) - Int(first.1)) <= 8
                    && abs(Int($0.2) - Int(first.2)) <= 8
                    && abs(Int($0.3) - Int(first.3)) <= 8
            }
    }
    return result ?? false
}

private let dockPreviewNotificationReceived: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let manager = Unmanaged<DockPreviewManager>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        if notification as String == kAXUIElementDestroyedNotification as String {
            manager.dockElementDestroyed()
        } else {
            manager.dockSelectionChanged()
        }
    }
}

private let dockWindowNotificationReceived: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let manager = Unmanaged<DockPreviewManager>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        if notification as String == kAXWindowMiniaturizedNotification as String {
            manager.windowWillMinimize(element)
        } else if notification as String == kAXUIElementDestroyedNotification as String {
            manager.windowElementDestroyed(element)
        }
    }
}
