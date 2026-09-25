import AppKit
import ApplicationServices
import SwiftUI

final class SnapAssistManager {
    private struct Display: Hashable {
        let number: UInt32
        let frame: CGRect

        init(_ screen: NSScreen) {
            number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            frame = screen.frame
        }
    }

    private struct RememberedWindow {
        let window: AXWindow
    }

    private struct ZoneMemory {
        let layout: SnapMultiWindowLayout
        var windows: [SnapAction: RememberedWindow]
    }

    private var enabled = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var activeScreen: NSScreen?
    private var activeWindow: AXWindow?
    private var activeLayout: SnapMultiWindowLayout?
    private var activeAction: SnapAction?
    private var pickedWindows = Set<AXWindow>()
    private var zoneMemory: [Display: ZoneMemory] = [:]
    private var suppressNextAssist = false
    private var lastSnappedProcessIdentifier: pid_t?
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var thumbnailTask: Task<Void, Never>?

    private var panel: SnapAssistPanel?
    private let settings: SnapAssistSettings
    private let thumbnailProvider: @MainActor ([CGWindowID]) async -> [CGWindowID: CGImage]

    init(settings: SnapAssistSettings,
         thumbnailProvider: @escaping @MainActor ([CGWindowID]) async -> [CGWindowID: CGImage]) {
        self.settings = settings
        self.thumbnailProvider = thumbnailProvider
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier == self.lastSnappedProcessIdentifier else {
                self.hidePanel()
                return
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hidePanel() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hidePanel() }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refreshPermission()
    }

    func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen, origin: SnapOrigin = .other) {
        let layout = remember(window: window, action: action, screen: screen)
        guard !suppressNextAssist else { return }
        guard let layout else {
            hidePanel()
            return
        }
        activeScreen = screen
        activeWindow = window
        activeLayout = layout
        pickedWindows = [window]
        lastSnappedProcessIdentifier = window.processIdentifier
        if origin == .layoutMenu, settings.fillEmptySpots == .mostRecent {
            fillEmptyZones(in: layout, excluding: window, on: screen)
        }
        guard enabled, Permissions.accessibilityGranted else {
            hidePanel()
            return
        }
        showNextZone()
    }

    func refreshPermission() {
        guard enabled else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            stop()
            return
        }
        guard Permissions.accessibilityGranted else {
            stop()
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.refreshPermission()
                }
            }
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        start()
    }

    private func start() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] in
                self?.handle($0)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
    }

    private func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        hidePanel()
    }

    private func handle(_ event: NSEvent) {
        guard Permissions.accessibilityGranted else {
            refreshPermission()
            return
        }
        guard let panel, panel.isVisible else { return }
        if event.type == .keyDown, event.keyCode == 53 {
            // Escape also reaches the frontmost app; this monitor only hides the panel.
            hidePanel()
        } else if event.type == .leftMouseDown, !panel.frame.contains(NSEvent.mouseLocation) {
            hidePanel()
        }
    }

    private func hidePanel() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        panel?.hide()
        activeScreen = nil
        activeWindow = nil
        activeLayout = nil
        activeAction = nil
        pickedWindows.removeAll()
        lastSnappedProcessIdentifier = nil
    }

    private func pick(_ choice: SnapWindowChoice) {
        guard let screen = activeScreen, let action = activeAction else {
            hidePanel()
            return
        }
        guard Permissions.accessibilityGranted else {
            hidePanel()
            return
        }
        guard let currentFrame = choice.window.frame,
              let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                               currentWindowFrame: currentFrame,
                                               portrait: screen.frame.height > screen.frame.width) else {
            hidePanel()
            return
        }
        activeAction = nil
        panel?.hide()
        lastSnappedProcessIdentifier = choice.application.processIdentifier
        choice.window.setFrame(target)
        choice.window.raise()
        let mainError = AXUIElementSetAttributeValue(choice.window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let appElement = AXUIElementCreateApplication(choice.application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        let frontmostError = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if mainError != .success || frontmostError != .success {
            choice.application.activate(options: [])
        }
        guard let readBack = choice.window.frame, SnapGeometry.isClose(readBack, target) else {
            hidePanel()
            return
        }
        pickedWindows.insert(choice.window)
        activeWindow = choice.window
        suppressNextAssist = true
        SnapEvents.didSnap(window: choice.window, action: action, screen: screen)
        suppressNextAssist = false
        showNextZone()
    }

    private func remember(window: AXWindow, action: SnapAction, screen: NSScreen) -> SnapMultiWindowLayout? {
        guard let layout = SnapMultiWindowLayout.containing(action) else { return nil }
        pruneGoneDisplays()
        let display = Display(screen)
        var memory = zoneMemory[display]
        if memory?.layout != layout {
            memory = ZoneMemory(layout: layout, windows: [:])
        } else if var current = memory {
            let canUpdate = prune(&current, on: display)
            memory = current
            if !canUpdate {
                if !window.isMinimized, window.frame != nil {
                    current.windows[action] = RememberedWindow(window: window)
                }
                zoneMemory[display] = current
                return layout
            }
        }
        guard var memory else { return layout }
        if let previous = memory.windows[action], previous.window != window {
            previous.window.setMinimized(true)
        }
        if !window.isMinimized, window.frame != nil {
            memory.windows[action] = RememberedWindow(window: window)
        }
        zoneMemory[display] = memory
        return layout
    }

    private func fillEmptyZones(in layout: SnapMultiWindowLayout, excluding window: AXWindow, on screen: NSScreen) {
        guard Permissions.accessibilityGranted else { return }
        let display = Display(screen)
        guard var memory = zoneMemory[display], memory.layout == layout else { return }
        _ = prune(&memory, on: display)
        zoneMemory[display] = memory

        var excluded = Set(memory.windows.values.map(\.window))
        excluded.insert(window)
        var choices = SnapWindowInventory.choices(on: screen, excluding: excluded).makeIterator()
        var filled: [(AXWindow, SnapAction)] = []
        for zone in layout.zones where memory.windows[zone.action] == nil {
            guard let choice = choices.next(), let current = choice.window.frame,
                  let target = SnapGeometry.frame(for: zone.action, visibleFrame: screen.visibleFrame,
                                                  currentWindowFrame: current,
                                                  portrait: screen.frame.height > screen.frame.width) else { continue }
            choice.window.setFrame(target)
            guard let readBack = choice.window.frame, SnapGeometry.isClose(readBack, target) else { continue }
            memory.windows[zone.action] = RememberedWindow(window: choice.window)
            filled.append((choice.window, zone.action))
        }
        zoneMemory[display] = memory
        for (window, action) in filled {
            suppressNextAssist = true
            SnapEvents.didSnap(window: window, action: action, screen: screen)
            suppressNextAssist = false
        }
        zoneMemory[display] = memory
    }

    private func showNextZone() {
        guard enabled, Permissions.accessibilityGranted,
              let screen = activeScreen, let layout = activeLayout else {
            hidePanel()
            return
        }
        pruneGoneDisplays()
        let display = Display(screen)
        guard var memory = zoneMemory[display], memory.layout == layout else {
            hidePanel()
            return
        }
        _ = prune(&memory, on: display)
        zoneMemory[display] = memory
        let filledActions = Set(memory.windows.keys)
        guard let zone = layout.zones.first(where: { !filledActions.contains($0.action) }),
              let frame = SnapGeometry.frame(for: zone.action, visibleFrame: screen.visibleFrame,
                                               currentWindowFrame: activeWindow?.frame ?? .zero,
                                               portrait: screen.frame.height > screen.frame.width) else {
            hidePanel()
            return
        }
        let excluded = Set(memory.windows.values.map(\.window)).union(pickedWindows)
        let choices = SnapWindowInventory.choices(on: screen, excluding: excluded)
        guard !choices.isEmpty else {
            hidePanel()
            return
        }
        activeAction = zone.action
        let panel = self.panel ?? SnapAssistPanel { [weak self] choice in self?.pick(choice) }
        self.panel = panel
        panel.show(frame: frame, choices: choices)
        thumbnailTask?.cancel()
        let thumbnailProvider = self.thumbnailProvider
        thumbnailTask = Task { @MainActor [weak self] in
            let images = await thumbnailProvider(choices.map(\.id))
            guard !Task.isCancelled, let self, self.activeAction == zone.action else { return }
            self.panel?.setImages(images)
        }
    }

    private func pruneGoneDisplays() {
        let displays = Set(NSScreen.screens.map(Display.init))
        zoneMemory = zoneMemory.filter { displays.contains($0.key) }
    }

    private func prune(_ memory: inout ZoneMemory, on display: Display) -> Bool {
        let savedWindows = memory.windows
        for action in Array(memory.windows.keys) {
            guard let member = memory.windows[action], let frame = member.window.frame,
                  !member.window.isMinimized,
                  let processIdentifier = member.window.processIdentifier,
                  let application = NSRunningApplication(processIdentifier: processIdentifier), !application.isHidden,
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
                  Display(screen) == display,
                  let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                                   currentWindowFrame: frame,
                                                   portrait: screen.frame.height > screen.frame.width),
                  SnapGeometry.isClose(frame, target) else {
                memory.windows.removeValue(forKey: action)
                continue
            }
            guard let present = SnapWindowInventory.isOnCurrentSpaceIfReadable(member.window, on: screen) else {
                memory.windows = savedWindows
                return false
            }
            if !present { memory.windows.removeValue(forKey: action) }
        }
        return true
    }
}

struct SnapWindowChoice: Identifiable {
    let id: CGWindowID
    let window: AXWindow
    let application: NSRunningApplication
    let title: String
}

enum SnapWindowInventory {
    private struct VisibleWindow {
        let id: CGWindowID
        let pid: pid_t
        let title: String?
        let frame: CGRect
    }

    private struct AXWindowSnapshot {
        let window: AXWindow
        let frame: CGRect
        let title: String?
    }

    static func choices(on screen: NSScreen, excluding excluded: Set<AXWindow>) -> [SnapWindowChoice] {
        let applications = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isHidden }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let currentWindows = visibleWindows(on: screen) else { return [] }
        let visible = currentWindows.filter { applications[$0.pid] != nil }

        var axWindows: [pid_t: [AXWindowSnapshot]] = [:]
        var used = Set<AXWindow>()
        var result: [SnapWindowChoice] = []
        for candidate in visible {
            guard let application = applications[candidate.pid] else { continue }
            let windows = axWindows[candidate.pid] ?? AXWindow.standardWindows(of: application).compactMap { window in
                guard let frame = window.frame else { return nil }
                return AXWindowSnapshot(window: window, frame: frame, title: window.title)
            }
            axWindows[candidate.pid] = windows
            let available = windows.filter { !excluded.contains($0.window) && !used.contains($0.window) }
            let match = available.first {
                candidate.title != nil && $0.title == candidate.title &&
                    SnapGeometry.isClose($0.frame, candidate.frame, tolerance: 8)
            } ?? available.first { SnapGeometry.isClose($0.frame, candidate.frame, tolerance: 8) }
            guard let match else { continue }
            used.insert(match.window)
            let title = match.title ?? application.localizedName ?? "Untitled Window"
            result.append(SnapWindowChoice(id: candidate.id, window: match.window, application: application, title: title))
        }
        return result
    }

    static func isOnCurrentSpace(_ window: AXWindow, on screen: NSScreen) -> Bool {
        isOnCurrentSpaceIfReadable(window, on: screen) ?? false
    }

    static func isOnCurrentSpaceIfReadable(_ window: AXWindow, on screen: NSScreen) -> Bool? {
        guard let pid = window.processIdentifier, let frame = window.frame else { return false }
        let title = window.title
        guard let visible = visibleWindows(on: screen) else { return nil }
        return visible.contains {
            $0.pid == pid && SnapGeometry.isClose($0.frame, frame, tolerance: 8) &&
                (title == nil || $0.title == nil || title == $0.title)
        }
    }

    private static func visibleWindows(on screen: NSScreen) -> [VisibleWindow]? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return windows
            .compactMap(visibleWindow)
            .filter { screen.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    private static func visibleWindow(_ info: [String: Any]) -> VisibleWindow? {
        guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        let rawTitle = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VisibleWindow(id: id, pid: pid, title: rawTitle?.isEmpty == false ? rawTitle : nil,
                             frame: cgFrame.axFlipped)
    }
}

private final class SnapAssistPanel: NSPanel {
    private let onPick: (SnapWindowChoice) -> Void
    private var choices: [SnapWindowChoice] = []
    private var images: [CGWindowID: CGImage] = [:]
    private var assistView: AcceptingFirstMouseHostingView<SnapAssistView>?

    init(onPick: @escaping (SnapWindowChoice) -> Void) {
        self.onPick = onPick
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        isFloatingPanel = true
        level = .floating
        animationBehavior = .none
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }

    func show(frame: CGRect, choices: [SnapWindowChoice]) {
        self.choices = choices
        images = [:]
        let assistView = AcceptingFirstMouseHostingView(rootView: SnapAssistView(choices: choices, images: images, onPick: onPick))
        self.assistView = assistView
        contentView = assistView
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func setImages(_ images: [CGWindowID: CGImage]) {
        self.images = images
        assistView?.rootView = SnapAssistView(choices: choices, images: images, onPick: onPick)
    }

    func hide() { orderOut(nil) }
}

private final class AcceptingFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SnapAssistView: View {
    let choices: [SnapWindowChoice]
    let images: [CGWindowID: CGImage]
    let onPick: (SnapWindowChoice) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let count = max(choices.count, 1)
            let width = max(size.width - 20, 1)
            let height = max(size.height - 20, 1)
            let columns = min(count, max(1, Int(ceil(sqrt(Double(count) * Double(width / height))))))
            let rows = (count + columns - 1) / columns
            let cellHeight = max(70, (height - CGFloat(rows - 1) * 8) / CGFloat(rows))
            let imageHeight = max(24, cellHeight - 58)
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.16)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    ForEach(choices) { choice in
                        Button { onPick(choice) } label: {
                            VStack(spacing: 6) {
                                Group {
                                    if let image = images[choice.id] {
                                        Image(nsImage: NSImage(cgImage: image, size: .zero))
                                            .resizable().scaledToFit()
                                    } else {
                                        appIcon(for: choice)
                                            .frame(width: min(72, imageHeight * 0.55), height: min(72, imageHeight * 0.55))
                                    }
                                }
                                .frame(maxWidth: .infinity).frame(height: imageHeight)
                                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                                HStack(spacing: 6) {
                                    appIcon(for: choice).frame(width: 20, height: 20)
                                    Text(choice.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 32)
                            }
                            .padding(7).frame(maxWidth: .infinity).frame(height: cellHeight)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func appIcon(for choice: SnapWindowChoice) -> some View {
        if let icon = choice.application.icon {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: "app.fill").resizable().scaledToFit()
        }
    }
}
