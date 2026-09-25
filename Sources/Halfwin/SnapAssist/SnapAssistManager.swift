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
        let frame: CGRect
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

    private var panel: SnapAssistPanel?

    init() {
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

    func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen) {
        let layout = remember(window: window, action: action, screen: screen)
        guard !suppressNextAssist else { return }
        guard enabled, Permissions.accessibilityGranted, let layout else {
            hidePanel()
            return
        }
        activeScreen = screen
        activeWindow = window
        activeLayout = layout
        pickedWindows = [window]
        lastSnappedProcessIdentifier = window.processIdentifier
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
        let display = Display(screen)
        var memory = zoneMemory[display]
        if memory?.layout != layout {
            memory = ZoneMemory(layout: layout, windows: [:])
        } else if var current = memory {
            prune(&current, on: display)
            memory = current
        }
        guard var memory else { return layout }
        if let previous = memory.windows[action], previous.window != window {
            previous.window.setMinimized(true)
        }
        if !window.isMinimized, let frame = window.frame {
            memory.windows[action] = RememberedWindow(window: window, frame: frame)
        }
        zoneMemory[display] = memory
        return layout
    }

    private func showNextZone() {
        guard enabled, Permissions.accessibilityGranted,
              let screen = activeScreen, let layout = activeLayout else {
            hidePanel()
            return
        }
        let display = Display(screen)
        guard var memory = zoneMemory[display], memory.layout == layout else {
            hidePanel()
            return
        }
        prune(&memory, on: display)
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
    }

    private func prune(_ memory: inout ZoneMemory, on display: Display) {
        for action in Array(memory.windows.keys) {
            guard let member = memory.windows[action], let frame = member.window.frame,
                  !member.window.isMinimized,
                  SnapGeometry.isClose(frame, member.frame),
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
                  Display(screen) == display else {
                memory.windows.removeValue(forKey: action)
                continue
            }
        }
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
                .filter { $0.activationPolicy == .regular }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let visible = visibleWindows(on: screen).filter { applications[$0.pid] != nil }

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
        guard let pid = window.processIdentifier, let frame = window.frame else { return false }
        let title = window.title
        return visibleWindows(on: screen).contains {
            $0.pid == pid && SnapGeometry.isClose($0.frame, frame, tolerance: 8) &&
                (title == nil || $0.title == nil || title == $0.title)
        }
    }

    private static func visibleWindows(on screen: NSScreen) -> [VisibleWindow] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
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

    init(onPick: @escaping (SnapWindowChoice) -> Void) {
        self.onPick = onPick
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }

    func show(frame: CGRect, choices: [SnapWindowChoice]) {
        contentView = AcceptingFirstMouseHostingView(rootView: SnapAssistView(choices: choices, onPick: onPick))
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

private final class AcceptingFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SnapAssistView: View {
    var choices: [SnapWindowChoice] = []
    let onPick: (SnapWindowChoice) -> Void

    var body: some View {
        ScrollView {
            if choices.isEmpty {
                Text("No other windows").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 190), spacing: 8)], spacing: 8) {
                    ForEach(choices) { choice in
                        Button { onPick(choice) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                if let icon = choice.application.icon {
                                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                                }
                                Text(choice.title).font(.system(size: 12)).lineLimit(2)
                                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial)
    }
}
