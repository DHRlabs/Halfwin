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
        let capturedAt: Date
    }

    private struct CachedShareableContent {
        let content: SCShareableContent
        let loadedAt: Date
    }

    private var enabled = false
    private var running = false
    private var permissionTimer: Timer?
    private var dockRetryTimer: Timer?
    private var dockProcessTimer: Timer?
    private var hoverTimer: Timer?
    private var hideTimer: Timer?
    private var pointerTimer: Timer?
    private var clickMonitor: Any?
    private var observer: AXObserver?
    private var observedList: AXUIElement?
    private var observerSource: CFRunLoopSource?
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
        self.enabled = enabled
        refreshPermission()
    }

    func refreshPermission() {
        guard enabled else {
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
        enabled = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopRuntime()
    }

    private func startRuntime() {
        guard !running else { return }
        running = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isShowing else { return }
                    self.hidePreview()
                }
            }
        }
        dockProcessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDockProcess() }
        }
        startDockObserver()
    }

    private func stopRuntime() {
        guard running else { return }
        running = false
        dockProcessTimer?.invalidate()
        dockProcessTimer = nil
        dockRetryTimer?.invalidate()
        dockRetryTimer = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        stopDockObserver()
        dockPID = nil
        dockRestartPending = false
        thumbnailCache.removeAll()
        shareableContentTask?.cancel()
        shareableContentTask = nil
        shareableContentRequestID = nil
        shareableContentCache = nil
        hidePreview()
    }

    private func checkDockProcess() {
        guard running else { return }
        let currentPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        guard currentPID != dockPID else { return }
        dockPID = currentPID
        restartDockObserver()
    }

    private func startDockObserver() {
        guard running, Permissions.accessibilityGranted, observer == nil else { return }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
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

    func dockElementDestroyed() {
        restartDockObserver()
    }

    func dockSelectionChanged() {
        guard running, let observedList else { return }
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
        guard let url = appURL(of: item) else {
            clearSelection()
            scheduleHide()
            return
        }
        let runningApps = NSWorkspace.shared.runningApplications
        let standardizedURL = url.standardizedFileURL
        let app = runningApps.first { $0.bundleURL?.standardizedFileURL == standardizedURL }
            ?? runningApps.first { candidate in
                guard let bundleURL = candidate.bundleURL else { return false }
                return bundleURL.resolvingSymlinksInPath().standardizedFileURL
                    == url.resolvingSymlinksInPath().standardizedFileURL
            }
        guard let app else {
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

        let visibleFrames = onScreenFrames(processID: selection.app.processIdentifier)
        let hiddenApp = selection.app.isHidden
        var usedWindowIDs = Set<CGWindowID>()
        var tileItems: [DockPreviewItem] = []
        var nextWindows: [Int: AXWindow] = [:]
        var screenshotIDs: [Int: CGWindowID] = [:]
        let icon = selection.app.icon ?? NSWorkspace.shared.icon(forFile: selection.app.bundleURL?.path ?? "")

        for window in AXWindow.standardWindows(of: selection.app) {
            let minimized = window.isMinimized
            // ponytail: frame-only matching can confuse overlapping windows.
            // Use AX-to-window identity if macOS exposes a stable key.
            let visible = minimized ? nil : visibleFrames.first(where: { candidate in
                !usedWindowIDs.contains(candidate.id) && window.frame.map { SnapGeometry.isClose($0, candidate.frame, tolerance: 4) } == true
            })
            guard minimized || visible != nil || hiddenApp else { continue }
            if let visible { usedWindowIDs.insert(visible.id) }
            let id = Int(truncatingIfNeeded: CFHash(window.element))
            tileItems.append(DockPreviewItem(id: id, title: window.title ?? "Untitled window", appIcon: icon, minimized: minimized))
            nextWindows[id] = window
            if let visible { screenshotIDs[id] = visible.id }
        }
        guard !tileItems.isEmpty else {
            hidePreview()
            return
        }

        windows = nextWindows
        activeApp = selection.app
        isShowing = true
        let orientation: String? = attribute(list, kAXOrientationAttribute)
        let edge = dockEdge(for: listFrame, screen: screen.frame, orientation: orientation)
        panel.show(items: tileItems, edge: edge, dockFrame: listFrame, itemFrame: itemFrame, visibleFrame: screen.visibleFrame)
        startPointerTimer()
        captureThumbnails(screenshotIDs, generation: captureGeneration)
    }

    private func captureThumbnails(_ idsByTile: [Int: CGWindowID], generation: Int) {
        guard Permissions.screenRecordingGranted, !idsByTile.isEmpty else { return }
        let now = Date()
        thumbnailCache = thumbnailCache.filter { now.timeIntervalSince($0.value.capturedAt) <= 5 }
        var uncached: [Int: CGWindowID] = [:]
        for (tileID, windowID) in idsByTile {
            if let cached = thumbnailCache[windowID] {
                panel.setImage(NSImage(cgImage: cached.image, size: .zero), for: tileID)
            } else {
                uncached[tileID] = windowID
            }
        }
        guard !uncached.isEmpty else { return }
        captureTask = Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  let content = await self.shareableContentForCapture(),
                  !Task.isCancelled else { return }
            await withTaskGroup(of: (Int, CGWindowID, CGImage?).self) { group in
                for (tileID, windowID) in uncached {
                    guard let window = content.windows.first(where: { $0.windowID == windowID }) else { continue }
                    group.addTask {
                        guard !Task.isCancelled else { return (tileID, windowID, nil) }
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        let configuration = SCStreamConfiguration()
                        configuration.width = max(1, Int(320 * CGFloat(filter.pointPixelScale)))
                        configuration.height = max(1, Int(CGFloat(configuration.width) * window.frame.height / max(window.frame.width, 1)))
                        configuration.showsCursor = false
                        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                              !Task.isCancelled else { return (tileID, windowID, nil) }
                        return (tileID, windowID, image)
                    }
                }
                for await (tileID, windowID, image) in group {
                    guard !Task.isCancelled, let image else { continue }
                    await self.setCapturedImage(image, for: tileID, windowID: windowID, generation: generation)
                }
            }
        }
    }

    private func prefetchShareableContent() {
        if let cache = shareableContentCache, Date().timeIntervalSince(cache.loadedAt) <= 2 { return }
        guard shareableContentTask == nil else { return }
        let requestID = UUID()
        let task = Task.detached(priority: .utility) {
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
        guard self.generation == generation, isShowing else { return }
        thumbnailCache[windowID] = CachedThumbnail(image: image, capturedAt: Date())
        panel.setImage(NSImage(cgImage: image, size: .zero), for: id)
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

    private func onScreenFrames(processID: pid_t) -> [(id: CGWindowID, frame: CGRect)] {
        // On-screen-only keeps previews on the current Space; other Spaces require private APIs.
        guard let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (id: CGWindowID(number.uint32Value), frame: frame.axFlipped)
        }
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
