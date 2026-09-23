import AppKit
import SwiftUI
import Combine

/// Persists the layout-menu on/off switch and dwell delay. Same shape as
/// `SnapSettings`: UserDefaults-backed, Lance's own default (on, 0.35s),
/// changeable in Settings.
final class LayoutMenuSettings: ObservableObject {
    static let shared = LayoutMenuSettings()

    private let defaults = UserDefaults.standard
    private let enabledKey = "Halfwin.layoutMenuEnabled"
    private let dwellKey = "Halfwin.layoutMenuDwellDelay"

    static let defaultDwellDelay: Double = 0.35

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: enabledKey) }
    }

    @Published var dwellDelay: Double {
        didSet { defaults.set(dwellDelay, forKey: dwellKey) }
    }

    private init() {
        enabled = defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
        let saved = defaults.object(forKey: dwellKey) as? Double ?? Self.defaultDwellDelay
        dwellDelay = min(max(saved, 0.1), 1.5)
    }
}

/// A single tile in the layout menu. Most map straight to a `SnapAction`;
/// `restore` doesn't fit that enum (it replays a remembered frame instead of
/// computing one), so it's handled locally. The big-left-stack thumbnail's
/// three zones bypass this enum entirely and post a `SnapAction` directly.
enum LayoutPreset: Equatable {
    case leftHalf, rightHalf, center, restore, maximize
}

/// Windows 11-style layout menu: hover the top-center of a display, pick a
/// preset from a small dropdown of thumbnails. Read Loop/DockDoor only to
/// confirm which system APIs exist (trigger zone, non-activating panel);
/// this implementation and its geometry are Halfwin's own.
final class LayoutMenuManager {
    private let settings: LayoutMenuSettings
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var dwellTimer: Timer?
    private var permissionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private lazy var panel = LayoutMenuPanel(
        onPick: { [weak self] preset in self?.pick(preset) },
        onPickZone: { [weak self] action in self?.pickStackZone(action) }
    )

    /// The display currently armed (dwelling or shown) for.
    private var armedScreen: NSScreen?
    /// The screen and window the panel is currently showing for.
    private var activeScreen: NSScreen?
    private var targetWindow: AXWindow?

    /// Pre-move frame per window, the same shape as `SnapManager.snappedInfo`:
    /// remembers what to restore to, dropped once the window has moved away
    /// from where this menu last put it.
    private var lastMoved: [AXWindow: (target: CGRect, preMove: CGRect)] = [:]

    /// True right after Escape or a pick dismisses the panel while the
    /// pointer is still inside the trigger strip: suppresses re-arming the
    /// dwell timer until the pointer actually leaves, so the panel doesn't
    /// pop right back up.
    private var suppressRearmUntilLeave = false

    private static let triggerHalfWidth: CGFloat = 100
    private static let triggerHeight: CGFloat = 4

    init(settings: LayoutMenuSettings) {
        self.settings = settings
        settings.$enabled
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshPermission() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPermission() }
    }

    /// Starts (or stops) the monitors to match Accessibility permission and
    /// the Settings toggle. Safe to call repeatedly.
    func refreshPermission() {
        if Permissions.accessibilityGranted {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.refreshPermission()
            }
        }
        if Permissions.accessibilityGranted && settings.enabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard globalMonitor == nil else { return }
        // .leftMouseDown only goes on the global mask: a local .leftMouseDown
        // fires (and would hide the panel) before AppKit delivers the
        // matching mouse-up as a SwiftUI tap on the panel's own tiles.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown]) {
            [weak self] in self?.handle($0)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancelDwell()
        hidePanel()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard event.keyCode == 53 else { return } // Escape
            cancelDwell()
            hidePanel(suppressRearm: true)
        case .leftMouseDown:
            // Drag snapping owns the top edge during drags.
            cancelDwell()
            hidePanel()
        case .mouseMoved:
            handleMouseMoved()
        default:
            break
        }
    }

    private func handleMouseMoved() {
        let cursor = NSEvent.mouseLocation

        if panel.isVisible {
            if isNearPanelOrTrigger(cursor) { return }
            hidePanel()
            return
        }

        if suppressRearmUntilLeave {
            if triggerScreen(for: cursor) != nil { return } // still inside the strip: keep waiting
            suppressRearmUntilLeave = false
        }

        guard let screen = triggerScreen(for: cursor) else {
            cancelDwell()
            return
        }
        guard armedScreen != screen else { return } // already dwelling for this screen
        cancelDwell()
        armedScreen = screen
        dwellTimer = Timer.scheduledTimer(withTimeInterval: settings.dwellDelay, repeats: false) { [weak self] _ in
            self?.showPanel(on: screen)
        }
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        armedScreen = nil
    }

    private func triggerScreen(for cursor: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let frame = screen.frame
            guard cursor.x >= frame.minX, cursor.x <= frame.maxX else { return false }
            guard cursor.y >= frame.maxY - Self.triggerHeight, cursor.y <= frame.maxY else { return false }
            return abs(cursor.x - frame.midX) <= Self.triggerHalfWidth
        }
    }

    /// True anywhere from the trigger strip at the top of `activeScreen` down
    /// to the panel's bottom edge, within a band at least as wide as the
    /// trigger strip and at least as wide as the panel — so moving from the
    /// strip into the panel (which sits below any notch) never dismisses it,
    /// and a stacked display below/above never reads as "near".
    private func isNearPanelOrTrigger(_ cursor: CGPoint) -> Bool {
        guard let frame = activeScreen?.frame else { return false }
        let halfWidth = max(Self.triggerHalfWidth, panel.frame.width / 2)
        guard cursor.x >= frame.midX - halfWidth, cursor.x <= frame.midX + halfWidth else { return false }
        return cursor.y >= panel.frame.minY && cursor.y <= frame.maxY
    }

    private func showPanel(on screen: NSScreen) {
        cancelDwell()
        guard Permissions.accessibilityGranted else { return }
        pruneUnreadableRestoreInfo()
        targetWindow = AXWindow.frontmostFocusedWindow()
        activeScreen = screen
        panel.show(on: screen)
    }

    private func hidePanel(suppressRearm: Bool = false) {
        panel.hide()
        activeScreen = nil
        targetWindow = nil
        suppressRearmUntilLeave = suppressRearm
    }

    /// Windows this menu can no longer read (closed, or the AX call timed
    /// out) have nothing to restore to; drop them so the table doesn't grow
    /// forever. Mirrors `SnapManager.pruneUnreadableSnapInfo`.
    private func pruneUnreadableRestoreInfo() {
        for window in lastMoved.keys where window.frame == nil {
            lastMoved.removeValue(forKey: window)
        }
    }

    private func pick(_ preset: LayoutPreset) {
        defer { hidePanel(suppressRearm: true) }
        guard let screen = activeScreen, let window = targetWindow, let currentFrame = window.frame else { return }
        let portrait = screen.frame.height > screen.frame.width
        let visibleFrame = screen.visibleFrame

        if preset == .restore {
            restore(window: window, currentFrame: currentFrame)
            return
        }

        guard let action = snapAction(for: preset) else { return }
        guard let target = SnapGeometry.frame(for: action, visibleFrame: visibleFrame,
                                              currentWindowFrame: currentFrame, portrait: portrait) else { return }
        apply(target, to: window, currentFrame: currentFrame)
    }

    /// `restore` doesn't produce a `SnapAction`; the big-left-stack
    /// thumbnail's three zones bypass this mapping entirely via
    /// `pickStackZone`.
    private func snapAction(for preset: LayoutPreset) -> SnapAction? {
        switch preset {
        case .leftHalf: return .leftHalf
        case .rightHalf: return .rightHalf
        case .center: return .center
        case .maximize: return .maximize
        case .restore: return nil
        }
    }

    /// Called for the three zones inside the big-left-stack thumbnail.
    fileprivate func pickStackZone(_ action: SnapAction) {
        defer { hidePanel(suppressRearm: true) }
        guard let screen = activeScreen, let window = targetWindow, let currentFrame = window.frame else { return }
        let portrait = screen.frame.height > screen.frame.width
        guard let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                              currentWindowFrame: currentFrame, portrait: portrait) else { return }
        apply(target, to: window, currentFrame: currentFrame)
    }

    /// Only sound if the window is still where this menu last put it — drop
    /// the entry (no-op) otherwise, so "Normal" never yanks a window the
    /// user has since moved or resized by hand.
    private func restore(window: AXWindow, currentFrame: CGRect) {
        guard let info = lastMoved[window], isClose(currentFrame, info.target) else {
            lastMoved.removeValue(forKey: window)
            return
        }
        window.setFrame(info.preMove)
        lastMoved.removeValue(forKey: window)
    }

    /// Remembers the pre-move frame for "Normal", keyed off the frame
    /// actually read back after the move (not the intended target — AX
    /// writes can settle a point or two off, or be clamped by the app's own
    /// min size) so a later restore-eligibility check compares against
    /// reality. Carries the original pre-move frame forward across repeated
    /// picks, the same way `SnapManager.snappedInfo` does.
    private func apply(_ target: CGRect, to window: AXWindow, currentFrame: CGRect) {
        let preMove: CGRect
        if let info = lastMoved[window], isClose(currentFrame, info.target) {
            preMove = info.preMove
        } else {
            preMove = currentFrame
        }
        window.setFrame(target)
        if let readBack = window.frame {
            lastMoved[window] = (target: readBack, preMove: preMove)
        }
    }

    private func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Borderless non-activating panel holding the layout thumbnails, dropped
/// just below the menu bar on the triggering display. Non-activating so the
/// frontmost app (whose window the picks affect) never loses focus.
private final class LayoutMenuPanel: NSPanel {
    private static let size = CGSize(width: 360, height: 96)

    init(onPick: @escaping (LayoutPreset) -> Void, onPickZone: @escaping (SnapAction) -> Void) {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = LayoutMenuView(onPick: onPick, onPickZone: onPickZone)
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { false }

    func show(on screen: NSScreen) {
        // Below the menu bar (and any notch), not under it: `visibleFrame`
        // already excludes that area, unlike `frame`.
        let origin = CGPoint(x: screen.frame.midX - Self.size.width / 2, y: screen.visibleFrame.maxY - Self.size.height - 6)
        setFrame(CGRect(origin: origin, size: Self.size), display: true)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

/// SwiftUI content of the panel: a row of small screen-shaped thumbnails,
/// each highlighting its zone(s) on hover.
private struct LayoutMenuView: View {
    let onPick: (LayoutPreset) -> Void
    let onPickZone: (SnapAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            SingleTile(title: "Left Half", rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)) { onPick(.leftHalf) }
            SingleTile(title: "Right Half", rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)) { onPick(.rightHalf) }
            SingleTile(title: "Center", rect: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)) { onPick(.center) }
            SingleTile(title: "Normal", rect: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)) { onPick(.restore) }
            SingleTile(title: "Maximize", rect: CGRect(x: 0, y: 0, width: 1, height: 1)) { onPick(.maximize) }
            StackTile(onPickZone: onPickZone)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One thumbnail with a single clickable/highlightable zone, drawn as a
/// small proportional rectangle within the screen-shaped outline.
private struct SingleTile: View {
    let title: String
    let rect: CGRect // unit rect, 0...1 in each axis, AppKit-style origin bottom-left
    let action: () -> Void
    @State private var hovering = false

    private static let size = CGSize(width: 44, height: 30)

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.08)))
                Rectangle()
                    .fill(hovering ? Color.accentColor : Color.accentColor.opacity(0.55))
                    .frame(width: rect.width * Self.size.width, height: rect.height * Self.size.height)
                    .offset(x: rect.minX * Self.size.width, y: -rect.minY * Self.size.height)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// The sixth preset: one thumbnail, three independently clickable/hoverable
/// zones (big left two-thirds, right-third top half, right-third bottom half).
private struct StackTile: View {
    let onPickZone: (SnapAction) -> Void
    @State private var hovered: SnapAction?

    private static let size = CGSize(width: 44, height: 30)

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.08)))
                zone(.firstTwoThirds, unit: CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1))
                zone(.lastThirdTop, unit: CGRect(x: 2.0 / 3, y: 0.5, width: 1.0 / 3, height: 0.5))
                zone(.lastThirdBottom, unit: CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 0.5))
            }
            .frame(width: Self.size.width, height: Self.size.height)
            Text("Left + Stack").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func zone(_ action: SnapAction, unit: CGRect) -> some View {
        Rectangle()
            .fill(hovered == action ? Color.accentColor : Color.accentColor.opacity(0.55))
            .frame(width: unit.width * Self.size.width, height: unit.height * Self.size.height)
            .offset(x: unit.minX * Self.size.width, y: -unit.minY * Self.size.height)
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? action : (hovered == action ? nil : hovered) }
            .onTapGesture { onPickZone(action) }
    }
}
