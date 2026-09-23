import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class DockPreviewManager {
    private struct Selection {
        let token: Int
        let app: NSRunningApplication
        let iconFrame: CGRect
        let edge: DockPreviewEdge
        let screenFrame: CGRect
    }

    private var enabled = false
    private var running = false
    private var permissionTimer: Timer?
    private var dockRetryTimer: Timer?
    private var hoverTimer: Timer?
    private var hideTimer: Timer?
    private var pointerTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var observer: AXObserver?
    private var observedList: AXUIElement?
    private var observerSource: CFRunLoopSource?
    private var selection: Selection?
    private var selectedIconFrame: CGRect?
    private var activeApp: NSRunningApplication?
    private var windows: [Int: AXWindow] = [:]
    private var generation = 0
    private var isShowing = false
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
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated { self?.restartDockObserver() }
        }
        startDockObserver()
    }

    private func stopRuntime() {
        guard running else { return }
        running = false
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        dockRetryTimer?.invalidate()
        dockRetryTimer = nil
        stopDockObserver()
        hoverTimer?.invalidate()
        hoverTimer = nil
        selection = nil
        selectedIconFrame = nil
        hidePreview()
    }

    private func startDockObserver() {
        guard running, Permissions.accessibilityGranted, observer == nil else { return }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            retryDockObserver()
            return
        }
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
        guard AXObserverCreate(dock.processIdentifier, dockPreviewSelectionChanged, &createdObserver) == .success,
              let createdObserver else {
            retryDockObserver()
            return
        }
        AXUIElementSetMessagingTimeout(list, 0.1)
        let result = AXObserverAddNotification(
            createdObserver, list, kAXSelectedChildrenChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard result == .success else {
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
        stopDockObserver()
        dockRetryTimer?.invalidate()
        dockRetryTimer = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        selection = nil
        selectedIconFrame = nil
        hidePreview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startDockObserver()
        }
    }

    private func stopDockObserver() {
        if let observer, let observedList {
            AXObserverRemoveNotification(observer, observedList, kAXSelectedChildrenChangedNotification as CFString)
        }
        if let observerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), observerSource, .commonModes)
        }
        observer = nil
        observedList = nil
        observerSource = nil
    }

    func dockSelectionChanged() {
        guard running, let observedList else { return }
        AXUIElementSetMessagingTimeout(observedList, 0.1)
        guard let items: [AXUIElement] = attribute(observedList, kAXSelectedChildrenAttribute),
              let item = items.first else {
            selectedIconFrame = nil
            selection = nil
            hoverTimer?.invalidate()
            hoverTimer = nil
            scheduleHide()
            return
        }
        AXUIElementSetMessagingTimeout(item, 0.1)
        guard let iconFrame = frame(of: item) else { return }
        let _: String? = attribute(item, kAXTitleAttribute)
        selectedIconFrame = iconFrame
        guard let url = appURL(of: item),
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
              }),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(iconFrame) }) else {
            selection = nil
            hoverTimer?.invalidate()
            hoverTimer = nil
            scheduleHide()
            return
        }
        let next = Selection(token: Int(truncatingIfNeeded: CFHash(item)), app: app, iconFrame: iconFrame,
                             edge: dockEdge(for: iconFrame, screen: screen.frame), screenFrame: screen.frame)
        selection = next
        hideTimer?.invalidate()
        hideTimer = nil
        guard activeApp?.processIdentifier != app.processIdentifier || !isShowing else { return }
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.selection?.token == next.token else { return }
                self.hoverTimer = nil
                self.showPreview(for: next)
            }
        }
    }

    private func showPreview(for selection: Selection) {
        generation += 1
        let captureGeneration = generation
        let visibleFrames = onScreenFrames(processID: selection.app.processIdentifier)
        var usedWindowIDs = Set<CGWindowID>()
        var tileItems: [DockPreviewItem] = []
        var nextWindows: [Int: AXWindow] = [:]
        var screenshotIDs: [Int: CGWindowID] = [:]
        let icon = selection.app.icon ?? NSWorkspace.shared.icon(forFile: selection.app.bundleURL?.path ?? "")

        for window in AXWindow.standardWindows(of: selection.app) {
            let minimized = window.isMinimized
            let visible = minimized ? nil : visibleFrames.first(where: { candidate in
                !usedWindowIDs.contains(candidate.id) && window.frame.map { SnapGeometry.isClose($0, candidate.frame, tolerance: 4) } == true
            })
            guard minimized || visible != nil else { continue }
            if let visible { usedWindowIDs.insert(visible.id) }
            let id = Int(truncatingIfNeeded: CFHash(window.element))
            tileItems.append(DockPreviewItem(id: id, title: window.title ?? "Untitled window", appIcon: icon, minimized: minimized))
            nextWindows[id] = window
            if let visible { screenshotIDs[id] = visible.id }
        }
        guard !tileItems.isEmpty else {
            self.selection = nil
            scheduleHide()
            return
        }
        windows = nextWindows
        activeApp = selection.app
        isShowing = true
        panel.show(items: tileItems, edge: selection.edge, anchor: selection.iconFrame, screenFrame: selection.screenFrame)
        startPointerTimer()
        captureThumbnails(screenshotIDs, generation: captureGeneration)
    }

    private func captureThumbnails(_ idsByTile: [Int: CGWindowID], generation: Int) {
        guard Permissions.screenRecordingGranted, !idsByTile.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let content = try? await SCShareableContent.current else { return }
            for (tileID, windowID) in idsByTile {
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(320 * CGFloat(filter.pointPixelScale)))
                configuration.height = max(1, Int(CGFloat(configuration.width) * window.frame.height / max(window.frame.width, 1)))
                configuration.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
                await self?.setCapturedImage(image, for: tileID, generation: generation)
            }
        }
    }

    private func setCapturedImage(_ image: CGImage, for id: Int, generation: Int) {
        guard self.generation == generation, isShowing else { return }
        panel.setImage(NSImage(cgImage: image, size: .zero), for: id)
    }

    private func selectWindow(_ id: Int) {
        guard let app = activeApp, let window = windows[id] else { return }
        window.restoreAndRaise(in: app)
        hidePreview()
    }

    private func startPointerTimer() {
        guard pointerTimer == nil else { return }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                let overDock = self.selection != nil && self.selectedIconFrame?.contains(NSEvent.mouseLocation) == true
                if overDock || self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.hideTimer?.invalidate()
                    self.hideTimer = nil
                } else {
                    self.scheduleHide()
                }
            }
        }
    }

    private func scheduleHide() {
        guard isShowing, hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                let overDock = self.selection != nil && self.selectedIconFrame?.contains(NSEvent.mouseLocation) == true
                if !overDock && !self.panel.frame.contains(NSEvent.mouseLocation) { self.hidePreview() }
            }
        }
    }

    private func hidePreview() {
        generation += 1
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

    private func frame(of element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions).axFlipped
    }

    private func dockEdge(for iconFrame: CGRect, screen: CGRect) -> DockPreviewEdge {
        let distances: [(DockPreviewEdge, CGFloat)] = [
            (.bottom, abs(iconFrame.minY - screen.minY)),
            (.top, abs(screen.maxY - iconFrame.maxY)),
            (.left, abs(iconFrame.minX - screen.minX)),
            (.right, abs(screen.maxX - iconFrame.maxX))
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .bottom
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

private let dockPreviewSelectionChanged: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let manager = Unmanaged<DockPreviewManager>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { manager.dockSelectionChanged() }
}
