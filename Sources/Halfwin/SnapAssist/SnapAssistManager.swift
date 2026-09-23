import AppKit
import SwiftUI

final class SnapAssistManager {
    private var enabled = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var activeScreen: NSScreen?
    private var activeAction: SnapAction?
    private var suppressNextAssist = false

    private var panel: SnapAssistPanel?

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refreshPermission()
    }

    func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen) {
        guard enabled, Permissions.accessibilityGranted, !suppressNextAssist,
              let otherAction = SnapGeometry.oppositeHalf(for: action),
              let frame = SnapGeometry.frame(for: otherAction, visibleFrame: screen.visibleFrame,
                                              currentWindowFrame: window.frame ?? .zero,
                                              portrait: screen.frame.height > screen.frame.width) else { return }
        let choices = SnapWindowInventory.choices(on: screen, excluding: window)
        activeScreen = screen
        activeAction = otherAction
        let panel = self.panel ?? SnapAssistPanel { [weak self] choice in self?.pick(choice) }
        self.panel = panel
        panel.show(frame: frame, choices: choices)
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
        panel?.hide()
        activeScreen = nil
        activeAction = nil
    }

    private func handle(_ event: NSEvent) {
        guard Permissions.accessibilityGranted else {
            refreshPermission()
            return
        }
        guard let panel, panel.isVisible else { return }
        if event.type == .keyDown, event.keyCode == 53 {
            panel.hide()
            activeScreen = nil
            activeAction = nil
        } else if event.type == .leftMouseDown, !panel.frame.contains(NSEvent.mouseLocation) {
            panel.hide()
            activeScreen = nil
            activeAction = nil
        }
    }

    private func pick(_ choice: SnapWindowChoice) {
        guard let screen = activeScreen, let action = activeAction else {
            panel?.hide()
            return
        }
        panel?.hide()
        activeScreen = nil
        activeAction = nil
        guard Permissions.accessibilityGranted else { return }
        guard let currentFrame = choice.window.frame,
              let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                               currentWindowFrame: currentFrame,
                                               portrait: screen.frame.height > screen.frame.width) else { return }
        choice.application.activate(options: [])
        choice.window.raise()
        choice.window.setFrame(target)
        guard let readBack = choice.window.frame, SnapGeometry.isClose(readBack, target) else { return }
        choice.window.raise()
        suppressNextAssist = true
        SnapEvents.didSnap(window: choice.window, action: action, screen: screen)
        suppressNextAssist = false
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

    static func choices(on screen: NSScreen, excluding excluded: AXWindow) -> [SnapWindowChoice] {
        let applications = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let visible = visibleWindows(on: screen).filter { applications[$0.pid] != nil }

        var axWindows: [pid_t: [AXWindow]] = [:]
        var used = Set<AXWindow>()
        var result: [SnapWindowChoice] = []
        for candidate in visible {
            guard let application = applications[candidate.pid] else { continue }
            let windows = axWindows[candidate.pid] ?? AXWindow.standardWindows(of: application)
            axWindows[candidate.pid] = windows
            guard let match = windows.first(where: { window in
                guard window != excluded, !used.contains(window),
                      let frame = window.frame, SnapGeometry.isClose(frame, candidate.frame, tolerance: 8) else { return false }
                if let cgTitle = candidate.title, let axTitle = window.title { return cgTitle == axTitle }
                return true
            }) else { continue }
            used.insert(match)
            let title = match.title ?? application.localizedName ?? "Untitled Window"
            result.append(SnapWindowChoice(id: candidate.id, window: match, application: application, title: title))
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
            .filter { $0.frame.intersects(screen.visibleFrame) }
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
        contentView = AcceptingFirstMouseHostingView(rootView: SnapAssistView(onPick: onPick))
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
