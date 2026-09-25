import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class DockPreviewManager {
    private struct Selection {
        let token: Int
        let item: AXUIElement
        let app: NSRunningApplication
        let placement: PreviewPlacement
    }

    private struct CachedThumbnail {
        let image: CGImage
        let width: Int
    }

    private struct CachedPreview {
        let items: [DockPreviewItem]
        let windows: [Int: AXWindow]
        let screenshotIDs: [Int: CGWindowID]
    }

    private struct PreviewPlacement {
        let edge: DockPreviewEdge
        let dockFrame: CGRect
        let itemFrame: CGRect
        let visibleFrame: CGRect
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
        let frontmostPID: pid_t?
        let ownsTopmostWindow: Bool
        var windowsToMinimize: [AXWindow] = []
        var focusedWindow: AXWindow?
        var previousMinimizedSet: MinimizedWindowSet?
        var windowsToRestore: MinimizedWindowSet?
        var thumbnailTask: Task<Void, Never>?
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
    private var backgroundCaptureTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var captureSuspendedForSession = false
    private var captureSuspendedForSleep = false
    private var hoverTimer: Timer?
    private var hideTimer: Timer?
    private var pointerTimer: Timer?
    private var peekHoverTimer: Timer?
    private var peekLeaveTimer: Timer?
    private var clickMonitor: Any?
    private var pendingDockClick: DockClick?
    private var dockClickInFlight = false
    private var mouseDownGeneration = 0
    private var dockListFrame: CGRect?
    private var observer: AXObserver?
    private var observedList: AXUIElement?
    private var observerSource: CFRunLoopSource?
    private var minimizeObserver: AXObserver?
    private var minimizeObserverSource: CFRunLoopSource?
    private var minimizeObserverPID: pid_t?
    private var observedApplicationElement: AXUIElement?
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
    private var peekCaptureTask: Task<Void, Never>?
    private var peekCaptureGeneration = 0
    private var hoveredTileID: Int?
    private var peekedTileID: Int?
    private var backgroundCaptureTask: Task<Void, Never>?
    private var warmThumbnailTasks: [UUID: Task<Void, Never>] = [:]
    private var thumbnailCache: [CGWindowID: CachedThumbnail] = [:]
    private var previewCache: [pid_t: CachedPreview] = [:]
    private var screenshotIDsByTile: [Int: CGWindowID] = [:]
    private var previewPlacement: PreviewPlacement?
    private var shareableContentCache: CachedShareableContent?
    private var shareableContentTask: Task<(SCShareableContent?, Date), Never>?
    private var shareableContentRequestID: UUID?
    private var shareableContentTaskIsForced = false
    private var cachedOnScreenWindowRecords: (records: [CGWindowRecord], loadedAt: TimeInterval)?
    private let panel = DockPreviewPanel()
    private let peekPanel = DockWindowPeek()
    private let settings: DockPreviewSettings
    private var settingsObserver: AnyCancellable?

    init(settings: DockPreviewSettings) {
        self.settings = settings
        panel.onSelect = { [weak self] in self?.selectWindow($0) }
        panel.onHover = { [weak self] id, inside in self?.previewTileHoverChanged(id, inside: inside) }
        settingsObserver = settings.$peekOnHover.dropFirst().sink { [weak self] enabled in
            guard !enabled else { return }
            Task { @MainActor [weak self] in self?.clearPeek() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        previewsEnabled = enabled
        if enabled {
            startWorkspaceObserver()
            if running {
                startBackgroundCaptureRefresh()
                if let app = NSWorkspace.shared.frontmostApplication { prepareApplication(app) }
            }
        } else {
            stopBackgroundCaptureRefresh()
            cancelWarmThumbnailCaptures()
            hidePreview()
            thumbnailCache.removeAll()
            previewCache.removeAll()
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

    func setSessionActive(_ active: Bool) {
        captureSuspendedForSession = !active
    }

    private func startRuntime() {
        guard !running else { return }
        running = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            let eventType = event.type
            let point = event.cgEvent?.location
            let timestamp = event.timestamp
            let clickCount = event.clickCount
            let modifierFlags = event.modifierFlags
            let keyCode = event.keyCode
            if eventType == .keyDown,
               keyCode != 46 || !modifierFlags.contains(.command)
                    || !modifierFlags.intersection([.shift, .option, .control]).isEmpty {
                return
            }
            let frontmost = eventType == .keyDown || eventType == .leftMouseDown
                ? NSWorkspace.shared.frontmostApplication : nil
            if eventType == .leftMouseDown || eventType == .keyDown {
                let captureBeforeDelivery = {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if eventType == .leftMouseDown, let point {
                            self.captureMinimizeButtonWindow(atQuartzPoint: point)
                        } else if eventType == .keyDown {
                            _ = self.captureFrontmostFocusedWindow(in: frontmost, usingSavedContent: true)
                        }
                    }
                }
                if Thread.isMainThread {
                    captureBeforeDelivery()
                } else {
                    DispatchQueue.main.sync(execute: captureBeforeDelivery)
                }
            }
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
                if self.previewsEnabled {
                    self.pruneThumbnailCache()
                }
            }
        }
        startWorkspaceObserver()
        if previewsEnabled {
            startBackgroundCaptureRefresh()
            if let app = NSWorkspace.shared.frontmostApplication { prepareApplication(app) }
        }
        startDockObserver()
    }

    private func stopRuntime() {
        guard running else { return }
        running = false
        stopBackgroundCaptureRefresh()
        cancelWarmThumbnailCaptures()
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
        previewCache.removeAll()
        shareableContentTask?.cancel()
        shareableContentTask = nil
        shareableContentRequestID = nil
        shareableContentTaskIsForced = false
        shareableContentCache = nil
        hidePreview()
    }

    private func startWorkspaceObserver() {
        guard running, workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.applicationDidDeactivate(notification) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.applicationDidActivate(notification) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureSuspendedForSession = true }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureSuspendedForSession = false
                self.refreshFrontmostThumbnails()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureSuspendedForSleep = true }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureSuspendedForSleep = false
                self.refreshFrontmostThumbnails()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureSuspendedForSleep = true }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureSuspendedForSleep = false
                self.refreshFrontmostThumbnails()
            }
        })
    }

    private func stopWorkspaceObserver() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
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
        dockListFrame = nil
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
        if observedApplicationElement == nil {
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.1)
            if AXObserverAddNotification(
                minimizeObserver, application, kAXFocusedWindowChangedNotification as CFString, context
            ) == .success {
                observedApplicationElement = application
            }
        }
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
            if let observedApplicationElement {
                AXObserverRemoveNotification(
                    minimizeObserver,
                    observedApplicationElement,
                    kAXFocusedWindowChangedNotification as CFString
                )
            }
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
        observedApplicationElement = nil
        observedWindowElements.removeAll()
    }

    func focusedWindowDidChange() {
        guard previewsEnabled, running, Permissions.screenRecordingGranted,
              let processID = minimizeObserverPID,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == processID }),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return }
        refreshPreviewCacheLater(for: app)
        _ = captureFrontmostFocusedWindow(in: app, priority: .utility, usingSavedContent: true)
    }

    func windowWillMinimize(_ element: AXUIElement) {
        guard previewsEnabled, running, Permissions.accessibilityGranted,
              Permissions.screenRecordingGranted else { return }
        AXUIElementSetMessagingTimeout(element, 0.1)
        let window = AXWindow(element: element)
        guard let processID = window.processIdentifier,
              let records = windowRecordsIfReadable(options: .optionAll)?.filter({ $0.processID == processID }),
              let record = matchingVisibleWindow(window, among: records)
                ?? matchingWindow(window, among: records, excluding: []) else { return }
        _ = warmThumbnails([record.id], priority: .userInitiated, usingSavedContent: true)
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
            dockListFrame = nil
            clearSelection()
            scheduleHide()
            return
        }
        dockListFrame = listFrame
        let orientation: String? = attribute(observedList, kAXOrientationAttribute)
        guard frameExtendedToDockEdge(listFrame, dockListFrame: listFrame, screenFrame: screen.frame, orientation: orientation).contains(pointer) else {
            clearSelection()
            scheduleHide()
            return
        }
        if Permissions.screenRecordingGranted { prefetchShareableContent() }
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
        guard let itemFrame = AXWindow.frame(of: item) else {
            clearSelection()
            scheduleHide()
            return
        }
        guard let app = runningApplication(forDockItem: item) else {
            clearSelection()
            scheduleHide()
            return
        }

        let next = Selection(
            token: Int(truncatingIfNeeded: CFHash(item)),
            item: item,
            app: app,
            placement: PreviewPlacement(
                edge: dockEdge(for: listFrame, screen: screen.frame, orientation: orientation),
                dockFrame: listFrame,
                itemFrame: itemFrame,
                visibleFrame: screen.visibleFrame
            )
        )
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
        let delay = settings.hoverDelay
        guard delay > 0 else {
            showPreview(for: next)
            return
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
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
                let validated = Selection(
                    token: current.token,
                    item: current.item,
                    app: current.app,
                    placement: PreviewPlacement(
                        edge: self.dockEdge(for: listFrame, screen: screen.frame, orientation: orientation),
                        dockFrame: listFrame,
                        itemFrame: itemFrame,
                        visibleFrame: screen.visibleFrame
                    )
                )
                self.selection = validated
                self.showPreview(for: validated)
            }
        }
    }

    private func captureMinimizeButtonWindow(atQuartzPoint point: CGPoint) {
        guard previewsEnabled, running, Permissions.accessibilityGranted,
              Permissions.screenRecordingGranted,
              clickMayBeMinimizeButton(atQuartzPoint: point),
              var element = AXWindow.element(atQuartzPoint: point) else { return }
        for _ in 0..<8 {
            AXUIElementSetMessagingTimeout(element, 0.1)
            if AXWindow.subrole(of: element) == (kAXMinimizeButtonSubrole as String),
               let windowElement: AXUIElement = attribute(element, kAXWindowAttribute) {
                AXUIElementSetMessagingTimeout(windowElement, 0.1)
                let window = AXWindow(element: windowElement)
                guard let processID = window.processIdentifier,
                      let record = matchingVisibleWindow(
                        window,
                        among: windowRecords(processID: processID, options: .optionOnScreenOnly)
                      ) else { return }
                _ = warmThumbnails([record.id], priority: .userInitiated, usingSavedContent: true)
                return
            }
            guard let parent: AXUIElement = attribute(element, kAXParentAttribute) else { return }
            element = parent
        }
    }

    private func clickMayBeMinimizeButton(atQuartzPoint point: CGPoint) -> Bool {
        let point = point.axFlipped
        guard dockListFrame?.contains(point) != true else { return false }
        let isInTitleBar: (CGRect) -> Bool = { frame in
            CGRect(
                x: frame.minX,
                y: frame.maxY - min(30, frame.height),
                width: min(90, frame.width),
                height: min(30, frame.height)
            ).contains(point)
        }
        if shareableContentCache?.content.windows.contains(where: { window in
            guard window.isOnScreen, window.owningApplication?.processID != dockPID else { return false }
            return isInTitleBar(window.frame.axFlipped)
        }) == true { return true }
        return recentOnScreenWindowRecords()?.contains { record in
            record.isOnScreen && record.processID != dockPID && record.frame.map(isInTitleBar) == true
        } == true
    }

    private func recentOnScreenWindowRecords() -> [CGWindowRecord]? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedOnScreenWindowRecords, now - cachedOnScreenWindowRecords.loadedAt <= 0.25 {
            return cachedOnScreenWindowRecords.records
        }
        guard let records = windowRecordsIfReadable(options: .optionOnScreenOnly) else { return nil }
        cachedOnScreenWindowRecords = (records, now)
        return records
    }

    private func captureFrontmostFocusedWindow(
        in app: NSRunningApplication?,
        priority: TaskPriority = .userInitiated,
        usingSavedContent: Bool = false
    ) -> Task<Void, Never>? {
        guard canCapturePreviews, Permissions.accessibilityGranted,
              let app,
              let window = AXWindow.focusedWindow(of: app),
              let processID = window.processIdentifier,
              let record = matchingVisibleWindow(
                window,
                among: windowRecords(processID: processID, options: .optionOnScreenOnly)
              ) else { return nil }
        return warmThumbnails([record.id], priority: priority, usingSavedContent: usingSavedContent)
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
        guard let onScreenRecords = windowRecordsIfReadable(options: .optionOnScreenOnly) else { return }
        let ownsTopmostWindow = onScreenRecords.first?.processID == processID
        pendingDockClick = DockClick(
            itemFrame: itemFrame,
            app: app,
            mouseDownPoint: point,
            mouseDownTimestamp: timestamp,
            mouseDownGeneration: clickGeneration,
            frontmostPID: frontmostPID,
            ownsTopmostWindow: ownsTopmostWindow
        )
        dockClickInFlight = true
    }

    private func handleGlobalMouseUp(
        at point: CGPoint?,
        timestamp: TimeInterval,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let pendingClick = pendingDockClick else { return }
        pendingDockClick = nil
        let pressDuration = timestamp - pendingClick.mouseDownTimestamp
        guard clickToMinimizeEnabled, Permissions.accessibilityGranted,
              clickCount == 1, !hasUnsupportedModifiers(modifierFlags),
              pressDuration >= 0, pressDuration < 0.4,
              let point,
              hypot(point.x - pendingClick.mouseDownPoint.x, point.y - pendingClick.mouseDownPoint.y) <= 4,
              pendingClick.itemFrame.contains(point.axFlipped),
              pendingClick.mouseDownGeneration == mouseDownGeneration else {
            if pendingClick.mouseDownGeneration == mouseDownGeneration { dockClickInFlight = false }
            return
        }
        var click = pendingClick
        let processID = click.app.processIdentifier
        guard let appWindows = AXWindow.standardWindowsIfReadable(of: click.app),
              let onScreenRecords = windowRecordsIfReadable(options: .optionOnScreenOnly) else {
            if pendingClick.mouseDownGeneration == mouseDownGeneration { dockClickInFlight = false }
            return
        }
        let appRecords = onScreenRecords.filter { $0.processID == processID }
        guard let matchedWindows = visibleStandardWindows(of: appWindows, among: appRecords) else {
            if pendingClick.mouseDownGeneration == mouseDownGeneration { dockClickInFlight = false }
            return
        }
        let visibleWindows = matchedWindows.map(\.window)
        if visibleWindows.isEmpty {
            guard let restoreSet = prunedMinimizedSet(for: processID) else {
                if pendingClick.mouseDownGeneration == mouseDownGeneration { dockClickInFlight = false }
                return
            }
            click.previousMinimizedSet = restoreSet
            click.windowsToRestore = restoreSet
        } else {
            guard click.frontmostPID == processID, click.ownsTopmostWindow else {
                if pendingClick.mouseDownGeneration == mouseDownGeneration { dockClickInFlight = false }
                return
            }
            click.windowsToMinimize = visibleWindows
            click.previousMinimizedSet = prunedMinimizedSet(for: processID)
            click.focusedWindow = AXWindow.focusedWindow(of: click.app)
                .flatMap { visibleWindows.contains($0) ? $0 : nil }
            click.thumbnailTask = warmThumbnails(matchedWindows.map(\.record.id), usingSavedContent: true)
        }
        observeWindowMinimization(in: click.app, windows: appWindows)
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
            guard let self, self.mouseDownGeneration == click.mouseDownGeneration else { return }
            self.performDockIconClick(click)
        }
    }

    private func hasUnsupportedModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    private func performDockIconClick(_ click: DockClick) {
        guard clickToMinimizeEnabled, Permissions.accessibilityGranted,
              !click.app.isTerminated,
              NSWorkspace.shared.runningApplications.contains(where: {
                  $0.processIdentifier == click.app.processIdentifier
              }) else {
            if mouseDownGeneration == click.mouseDownGeneration { dockClickInFlight = false }
            return
        }
        hidePreview()

        if let restoreSet = click.windowsToRestore {
            let restoreWindows = restoreSet.windows.filter { !isConfirmedDead($0) }
            guard !restoreWindows.isEmpty else {
                if mouseDownGeneration == click.mouseDownGeneration { dockClickInFlight = false }
                return
            }
            var restoredAny = false
            for window in restoreWindows {
                restoredAny = window.setMinimized(false) || restoredAny
            }
            guard restoredAny else {
                if mouseDownGeneration == click.mouseDownGeneration { dockClickInFlight = false }
                return
            }
            let focused = restoreSet.focusedWindow.flatMap { restoreWindows.contains($0) ? $0 : nil }
                ?? restoreWindows.first
            focused?.restoreAndRaise(in: click.app)
            minimizedWindowsByApp.removeValue(forKey: click.app.processIdentifier)
            if mouseDownGeneration == click.mouseDownGeneration { dockClickInFlight = false }
            return
        }

        guard !click.windowsToMinimize.isEmpty else {
            if mouseDownGeneration == click.mouseDownGeneration { dockClickInFlight = false }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.mouseDownGeneration == click.mouseDownGeneration { self.dockClickInFlight = false }
            }
            await self.waitForThumbnailCapture(click.thumbnailTask)
            guard self.mouseDownGeneration == click.mouseDownGeneration,
                  self.clickToMinimizeEnabled, Permissions.accessibilityGranted,
                  !click.app.isTerminated,
                  NSWorkspace.shared.runningApplications.contains(where: {
                      $0.processIdentifier == click.app.processIdentifier
                  }) else { return }
            for window in click.windowsToMinimize { window.setMinimized(true) }
            let remembered = click.previousMinimizedSet?.windows ?? []
            let combined = remembered + click.windowsToMinimize.filter { !remembered.contains($0) }
            guard !combined.isEmpty else { return }
            let focused = click.focusedWindow ?? click.previousMinimizedSet?.focusedWindow
            self.minimizedWindowsByApp[click.app.processIdentifier] = MinimizedWindowSet(
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
    }

    private func visibleStandardWindows(of windows: [AXWindow], among visibleFrames: [CGWindowRecord]) -> [MatchedWindow]? {
        var usedWindowIDs = Set<CGWindowID>()
        var matched: [MatchedWindow] = []
        for window in windows {
            var value: AnyObject?
            let minimizedError = AXUIElementCopyAttributeValue(window.element, kAXMinimizedAttribute as CFString, &value)
            if minimizedError == .noValue || minimizedError == .attributeUnsupported { continue }
            guard minimizedError == .success, let minimized = value as? Bool else { return nil }
            if minimized { continue }
            let (frame, frameError) = AXWindow.frameWithError(of: window.element)
            if frameError == .noValue || frameError == .attributeUnsupported { continue }
            guard frameError == .success, let frame else { return nil }
            guard let match = visibleFrames.first(where: { candidate in
                !usedWindowIDs.contains(candidate.id)
                    && candidate.frame.map { SnapGeometry.isClose(frame, $0, tolerance: 4) } == true
            }) else { continue }
            usedWindowIDs.insert(match.id)
            matched.append(MatchedWindow(window: window, record: match))
        }
        return matched
    }

    private func prunedMinimizedSet(for processID: pid_t) -> MinimizedWindowSet? {
        guard var saved = minimizedWindowsByApp[processID] else { return nil }
        saved.windows = saved.windows.filter { !isConfirmedDead($0) }
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

    private func isConfirmedDead(_ window: AXWindow) -> Bool {
        AXUIElementSetMessagingTimeout(window.element, 0.1)
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
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
        guard observedList != nil else {
            hidePreview()
            return
        }
        activeApp = selection.app
        isShowing = true
        previewPlacement = selection.placement
        let cached = previewCache[selection.app.processIdentifier].flatMap { $0.items.isEmpty ? nil : $0 }
            ?? placeholderPreview(for: selection.app)
        present(cached, preservingImages: false)
        startPointerTimer()
        captureThumbnails(cached.screenshotIDs, generation: captureGeneration)
        let selectionToken = selection.token
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.generation == captureGeneration,
                  self.isShowing,
                  self.activeApp?.processIdentifier == selection.app.processIdentifier,
                  self.selection?.token == selectionToken,
                  self.selection?.placement.itemFrame.contains(NSEvent.mouseLocation) == true else { return }
            self.refreshPreviewCache(for: selection.app, visibleGeneration: captureGeneration)
        }
    }

    private func placeholderPreview(for app: NSRunningApplication) -> CachedPreview {
        let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "")
        return CachedPreview(
            items: [DockPreviewItem(id: Int.min, title: app.localizedName ?? "Loading windows…", appIcon: icon, minimized: false)],
            windows: [:],
            screenshotIDs: [:]
        )
    }

    private func present(_ preview: CachedPreview, preservingImages: Bool) {
        guard let placement = previewPlacement else { return }
        if let peekedTileID, !preview.items.contains(where: { $0.id == peekedTileID }) { clearPeek() }
        windows = preview.windows
        screenshotIDsByTile = preview.screenshotIDs
        panel.show(
            items: preview.items,
            edge: placement.edge,
            dockFrame: placement.dockFrame,
            itemFrame: placement.itemFrame,
            visibleFrame: placement.visibleFrame,
            previewScale: CGFloat(settings.previewSize),
            preservingImages: preservingImages
        )
        let targetWidth = captureWidth
        for (tileID, windowID) in preview.screenshotIDs {
            if let cached = thumbnailCache[windowID], cached.width >= targetWidth {
                panel.setImage(NSImage(cgImage: cached.image, size: .zero), for: tileID)
            }
        }
    }

    private func buildCachedPreview(for app: NSRunningApplication) -> CachedPreview? {
        let processID = app.processIdentifier
        guard let allRecords = windowRecordsIfReadable(options: .optionAll) else { return nil }
        let allFrames = allRecords.filter { $0.processID == processID }
        let visibleFrames = allFrames.filter(\.isOnScreen)
        pruneThumbnailCache(keeping: Set(allRecords.map(\.id)))
        let hiddenApp = app.isHidden
        var usedWindowIDs = Set<CGWindowID>()
        var tileItems: [DockPreviewItem] = []
        var nextWindows: [Int: AXWindow] = [:]
        var screenshotIDs: [Int: CGWindowID] = [:]
        let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "")
        guard let appWindows = AXWindow.standardWindowsIfReadable(of: app) else {
            return previewCache[processID]
        }

        for window in appWindows {
            let minimized = window.isMinimized
            let record = minimized
                ? matchingWindow(window, among: allFrames, excluding: usedWindowIDs)
                : visibleFrames.first { candidate in
                    !usedWindowIDs.contains(candidate.id) && candidate.frame.map { frame in
                        window.frame.map { SnapGeometry.isClose($0, frame, tolerance: 4) } == true
                    } == true
                }
            guard minimized || record != nil || hiddenApp else { continue }
            if let record { usedWindowIDs.insert(record.id) }
            let id = Int(truncatingIfNeeded: CFHash(window.element))
            tileItems.append(DockPreviewItem(id: id, title: window.title ?? "Untitled window", appIcon: icon, minimized: minimized))
            nextWindows[id] = window
            if let record { screenshotIDs[id] = record.id }
        }
        observeWindowMinimization(in: app, windows: appWindows)
        return CachedPreview(items: tileItems, windows: nextWindows, screenshotIDs: screenshotIDs)
    }

    private func refreshPreviewCache(for app: NSRunningApplication, visibleGeneration: Int? = nil) {
        guard previewsEnabled, running, Permissions.accessibilityGranted, !app.isTerminated,
              let cached = buildCachedPreview(for: app) else { return }
        previewCache[app.processIdentifier] = cached
        guard let visibleGeneration,
              generation == visibleGeneration,
              isShowing,
              activeApp?.processIdentifier == app.processIdentifier else { return }
        guard !cached.items.isEmpty else {
            hidePreview()
            return
        }
        captureTask?.cancel()
        captureTask = nil
        present(cached, preservingImages: true)
        captureThumbnails(cached.screenshotIDs, generation: visibleGeneration)
    }

    private func refreshPreviewCacheLater(for app: NSRunningApplication) {
        let visibleGeneration = isShowing && activeApp?.processIdentifier == app.processIdentifier ? generation : nil
        DispatchQueue.main.async { [weak self] in
            self?.refreshPreviewCache(for: app, visibleGeneration: visibleGeneration)
        }
    }

    private var captureWidth: Int {
        min(960, max(320, Int((320 * settings.previewSize).rounded())))
    }

    private var canCapturePreviews: Bool {
        previewsEnabled && running && Permissions.screenRecordingGranted
            && !captureSuspendedForSession && !captureSuspendedForSleep
    }

    private func captureThumbnails(_ idsByTile: [Int: CGWindowID], generation: Int) {
        guard canCapturePreviews, !idsByTile.isEmpty else { return }
        let targetWidth = captureWidth
        for (tileID, windowID) in idsByTile {
            if let cached = thumbnailCache[windowID], cached.width >= targetWidth {
                panel.setImage(NSImage(cgImage: cached.image, size: .zero), for: tileID)
            }
        }
        captureTask = Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  await self.canCapturePreviews,
                  let content = await self.shareableContentForCapture(),
                  !Task.isCancelled else { return }
            let images = await captureWindowImages(Array(Set(idsByTile.values)), content: content, width: targetWidth)
            guard !Task.isCancelled else { return }
            for (tileID, windowID) in idsByTile {
                guard let image = images[windowID] else { continue }
                await self.setCapturedImage(
                    image,
                    for: tileID,
                    windowID: windowID,
                    width: targetWidth,
                    generation: generation
                )
            }
        }
    }

    private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        prepareApplication(app)
    }

    private func applicationDidDeactivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        prepareApplication(app)
    }

    private func prepareApplication(_ app: NSRunningApplication) {
        guard previewsEnabled, running else { return }
        refreshPreviewCacheLater(for: app)
        refreshThumbnails(for: app, priority: .utility)
    }

    private func startBackgroundCaptureRefresh() {
        guard backgroundCaptureTimer == nil else { return }
        backgroundCaptureTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.canCapturePreviews else { return }
                self.backgroundCaptureTask?.cancel()
                self.backgroundCaptureTask = self.captureFrontmostFocusedWindow(
                    in: NSWorkspace.shared.frontmostApplication,
                    priority: .background,
                    usingSavedContent: true
                )
            }
        }
    }

    private func stopBackgroundCaptureRefresh() {
        backgroundCaptureTimer?.invalidate()
        backgroundCaptureTimer = nil
        backgroundCaptureTask?.cancel()
        backgroundCaptureTask = nil
    }

    private func refreshFrontmostThumbnails() {
        guard canCapturePreviews, let app = NSWorkspace.shared.frontmostApplication else { return }
        refreshThumbnails(for: app, priority: .background)
    }

    private func refreshThumbnails(for app: NSRunningApplication, priority: TaskPriority) {
        guard canCapturePreviews else { return }
        let ids = windowRecords(processID: app.processIdentifier, options: .optionOnScreenOnly)
            .filter(\.isOnScreen).map(\.id)
        _ = warmThumbnails(ids, priority: priority)
    }

    private func warmThumbnails(
        _ windowIDs: [CGWindowID],
        priority: TaskPriority = .utility,
        usingSavedContent: Bool = false
    ) -> Task<Void, Never>? {
        guard canCapturePreviews, !windowIDs.isEmpty else { return nil }
        let targetWidth = captureWidth
        let savedContent = usingSavedContent ? shareableContentCache?.content : nil
        let savedWindowIDs = Set(savedContent?.windows.map(\.windowID) ?? [])
        let needsFreshContent = usingSavedContent && !windowIDs.allSatisfy(savedWindowIDs.contains)
        let contentRefreshTask = needsFreshContent ? prefetchShareableContent(forceRefresh: true) : nil
        if !needsFreshContent { prefetchShareableContent() }
        let taskID = UUID()
        let task = Task.detached(priority: priority) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in self?.warmThumbnailTasks[taskID] = nil }
            }
            guard await self.canCapturePreviews, !Task.isCancelled else { return }
            let content: SCShareableContent?
            if !needsFreshContent, let savedContent {
                content = savedContent
            } else if let contentRefreshTask {
                content = (await contentRefreshTask.value).0
            } else {
                content = await self.shareableContentForCapture()
            }
            guard let content, !Task.isCancelled else { return }
            let images = await captureWindowImages(windowIDs, content: content, width: targetWidth)
            guard !Task.isCancelled else { return }
            for (windowID, image) in images {
                await self.setWarmedThumbnail(image, windowID: windowID, width: targetWidth)
            }
        }
        warmThumbnailTasks[taskID] = task
        return task
    }

    private func cancelWarmThumbnailCaptures() {
        for task in warmThumbnailTasks.values { task.cancel() }
        warmThumbnailTasks.removeAll()
    }

    private func waitForThumbnailCapture(_ task: Task<Void, Never>?) async {
        guard let task else { return }
        let finished = AsyncStream<Void> { continuation in
            Task {
                await task.value
                continuation.yield(())
                continuation.finish()
            }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                continuation.yield(())
                continuation.finish()
            }
        }
        for await _ in finished { break }
    }

    @discardableResult
    private func prefetchShareableContent(
        forceRefresh: Bool = false
    ) -> Task<(SCShareableContent?, Date), Never>? {
        if !forceRefresh, let cache = shareableContentCache, Date().timeIntervalSince(cache.loadedAt) <= 4 {
            return nil
        }
        if let shareableContentTask {
            if !forceRefresh || shareableContentTaskIsForced { return shareableContentTask }
            shareableContentTask.cancel()
        }
        let requestID = UUID()
        let task = Task.detached(priority: forceRefresh ? .userInitiated : .utility) {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return (content, Date())
        }
        shareableContentTask = task
        shareableContentRequestID = requestID
        shareableContentTaskIsForced = forceRefresh
        Task { [weak self] in
            let (content, loadedAt) = await task.value
            guard let self, self.shareableContentRequestID == requestID else { return }
            if let content {
                self.shareableContentCache = CachedShareableContent(content: content, loadedAt: loadedAt)
            }
            self.shareableContentTask = nil
            self.shareableContentRequestID = nil
            self.shareableContentTaskIsForced = false
        }
        return task
    }

    private func shareableContentForCapture() async -> SCShareableContent? {
        if let cache = shareableContentCache, Date().timeIntervalSince(cache.loadedAt) <= 4 {
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
            shareableContentTaskIsForced = false
        }
        return content
    }

    private func setCapturedImage(
        _ image: CGImage,
        for id: Int,
        windowID: CGWindowID,
        width: Int,
        generation: Int
    ) {
        guard canCapturePreviews,
              !thumbnailImageIsBlank(image) else { return }
        thumbnailCache[windowID] = CachedThumbnail(image: image, width: width)
        guard self.generation == generation, isShowing else { return }
        guard width >= captureWidth, screenshotIDsByTile[id] == windowID else { return }
        panel.setImage(NSImage(cgImage: image, size: .zero), for: id)
    }

    private func setWarmedThumbnail(_ image: CGImage, windowID: CGWindowID, width: Int) {
        guard canCapturePreviews,
              !thumbnailImageIsBlank(image) else { return }
        thumbnailCache[windowID] = CachedThumbnail(image: image, width: width)
        guard width >= captureWidth,
              let tileID = screenshotIDsByTile.first(where: { $0.value == windowID })?.key,
              isShowing else { return }
        panel.setImage(NSImage(cgImage: image, size: .zero), for: tileID)
    }

    private func previewTileHoverChanged(_ id: Int, inside: Bool) {
        if !inside {
            guard hoveredTileID == id else { return }
            hoveredTileID = nil
            peekHoverTimer?.invalidate()
            peekHoverTimer = nil
            guard peekedTileID != nil else { return }
            peekLeaveTimer?.invalidate()
            peekLeaveTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearPeek() }
            }
            return
        }
        guard isShowing, settings.peekOnHover, canCapturePreviews else {
            clearPeek()
            return
        }
        peekLeaveTimer?.invalidate()
        peekLeaveTimer = nil
        guard hoveredTileID != id else { return }
        hoveredTileID = id
        peekHoverTimer?.invalidate()
        if peekedTileID != nil {
            showPeek(for: id)
            return
        }
        peekHoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hoveredTileID == id else { return }
                self.peekHoverTimer = nil
                self.showPeek(for: id)
            }
        }
    }

    private func showPeek(for id: Int) {
        guard settings.peekOnHover, canCapturePreviews,
              let window = windows[id] else {
            clearPeek()
            return
        }
        AXUIElementSetMessagingTimeout(window.element, 0.1)
        guard let frame = window.frame, frame.width > 0, frame.height > 0,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else {
            clearPeek()
            return
        }
        peekCaptureTask?.cancel()
        peekCaptureTask = nil
        peekCaptureGeneration += 1
        let captureGeneration = peekCaptureGeneration
        peekedTileID = id
        let windowID = screenshotIDsByTile[id]
        let cachedImage = windowID.flatMap { thumbnailCache[$0]?.image }
        let minimized = window.isMinimized
        peekPanel.show(frame: frame, on: screen.frame, image: cachedImage, minimized: minimized)
        guard let windowID else { return }

        let targetWidth = min(4096, max(1, Int((frame.width * screen.backingScaleFactor).rounded())))
        let cachedContent = shareableContentCache?.content
        let hasWindow = cachedContent?.windows.contains(where: { $0.windowID == windowID }) == true
        let freshContentTask = hasWindow ? nil : prefetchShareableContent(forceRefresh: true)
        peekCaptureTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, await self.canCapturePreviews, !Task.isCancelled else { return }
            let content: SCShareableContent?
            if hasWindow {
                content = cachedContent
            } else if let freshContentTask {
                content = (await freshContentTask.value).0
            } else {
                content = await self.shareableContentForCapture()
            }
            guard let content, !Task.isCancelled,
                  let captureWindow = content.windows.first(where: { $0.windowID == windowID }),
                  let image = await captureWindowThumbnail(captureWindow, width: targetWidth, maxHeight: nil),
                  !Task.isCancelled else { return }
            await self.setPeekImage(
                image,
                for: id,
                windowID: windowID,
                generation: captureGeneration
            )
        }
    }

    private func setPeekImage(_ image: CGImage, for id: Int, windowID: CGWindowID, generation: Int) {
        guard canCapturePreviews, !thumbnailImageIsBlank(image),
              peekCaptureGeneration == generation,
              peekedTileID == id,
              screenshotIDsByTile[id] == windowID else { return }
        peekPanel.setImage(image)
    }

    private func clearPeek() {
        peekHoverTimer?.invalidate()
        peekHoverTimer = nil
        peekLeaveTimer?.invalidate()
        peekLeaveTimer = nil
        peekCaptureGeneration += 1
        peekCaptureTask?.cancel()
        peekCaptureTask = nil
        hoveredTileID = nil
        peekedTileID = nil
        peekPanel.hide()
    }

    private func selectWindow(_ id: Int) {
        guard let app = activeApp, let window = windows[id] else { return }
        mouseDownGeneration += 1
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
        clearPeek()
        clearSelection()
        panel.hide()
        isShowing = false
        activeApp = nil
        windows.removeAll()
        screenshotIDsByTile.removeAll()
        previewPlacement = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func windowRecords(processID: pid_t, options: CGWindowListOption) -> [CGWindowRecord] {
        windowRecords(options: options).filter { $0.processID == processID }
    }

    private func windowRecords(options: CGWindowListOption) -> [CGWindowRecord] {
        windowRecordsIfReadable(options: options) ?? []
    }

    private func windowRecordsIfReadable(options: CGWindowListOption) -> [CGWindowRecord]? {
        // On-screen-only keeps previews on the current Space; other Spaces require private APIs.
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            guard let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber else { return nil }
            let bounds = entry[kCGWindowBounds as String] as? NSDictionary
            let frame = bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary)?.axFlipped }
            let rawTitle = entry[kCGWindowName as String] as? String
            let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
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

    private func matchingVisibleWindow(_ window: AXWindow, among candidates: [CGWindowRecord]) -> CGWindowRecord? {
        let frameMatches = candidates.filter { candidate in
            guard candidate.isOnScreen, let candidateFrame = candidate.frame,
                  let windowFrame = window.frame else { return false }
            return SnapGeometry.isClose(windowFrame, candidateFrame, tolerance: 4)
        }
        if let title = window.title {
            let titleMatches = frameMatches.filter { $0.title?.localizedCaseInsensitiveCompare(title) == .orderedSame }
            if titleMatches.count == 1 { return titleMatches[0] }
        }
        return frameMatches.count == 1 ? frameMatches[0] : nil
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
        guard previewsEnabled else { return }
        guard let records = windowRecordsIfReadable(options: .optionAll) else { return }
        let existingIDs = Set(records.map(\.id))
        let existingProcesses = Set(records.map(\.processID))
        thumbnailCache = thumbnailCache.filter { existingIDs.contains($0.key) }
        previewCache = previewCache.filter { existingProcesses.contains($0.key) }
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

private func captureWindowImages(
    _ ids: [CGWindowID],
    content: SCShareableContent,
    width: Int
) async -> [CGWindowID: CGImage] {
    let windowsByID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
    var images: [CGWindowID: CGImage] = [:]
    await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
        for id in Set(ids) {
            guard let window = windowsByID[id] else { continue }
            group.addTask {
                (id, await captureWindowThumbnail(window, width: width))
            }
        }
        for await (id, image) in group {
            if let image { images[id] = image }
        }
    }
    return images
}

private func captureWindowThumbnail(_ window: SCWindow, width: Int, maxHeight: Int? = 2048) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    let sourceWidth = max(window.frame.width, 1)
    let sourceHeight = max(window.frame.height, 1)
    let widthScale = CGFloat(width) / sourceWidth
    let scale = maxHeight.map { min(widthScale, CGFloat($0) / sourceHeight) } ?? widthScale
    configuration.width = max(1, Int(sourceWidth * scale))
    configuration.height = max(1, Int(sourceHeight * scale))
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
        if notification as String == kAXFocusedWindowChangedNotification as String {
            manager.focusedWindowDidChange()
        } else if notification as String == kAXWindowMiniaturizedNotification as String {
            manager.windowWillMinimize(element)
        } else if notification as String == kAXUIElementDestroyedNotification as String {
            manager.windowElementDestroyed(element)
        }
    }
}
