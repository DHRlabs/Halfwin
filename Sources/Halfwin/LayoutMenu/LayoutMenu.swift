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
        dwellDelay = defaults.object(forKey: dwellKey) as? Double ?? Self.defaultDwellDelay
    }
}

/// A single tile in the layout menu. Most map straight to a `SnapAction`;
/// `restore` and the two-zone `bigLeftStack` don't fit that enum, so they're
/// handled locally.
enum LayoutPreset: Equatable {
    case leftHalf, rightHalf, center, restore, maximize
    case bigLeftStack
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

    private static let triggerHalfWidth: CGFloat = 100
    private static let triggerHeight: CGFloat = 4
    private static let dismissGrace: CGFloat = 24

    init(settings: LayoutMenuSettings) {
        self.settings = settings
        settings.$enabled
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshPermission() } }
            .store(in: &cancellables)
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
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.handle($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
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
            hidePanel()
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
            guard cursor.y >= frame.maxY - Self.triggerHeight else { return false }
            return abs(cursor.x - frame.midX) <= Self.triggerHalfWidth
        }
    }

    private func isNearPanelOrTrigger(_ cursor: CGPoint) -> Bool {
        let grown = panel.frame.insetBy(dx: -Self.dismissGrace, dy: -Self.dismissGrace)
        if grown.contains(cursor) { return true }
        // The strip between the panel and the trigger zone it dropped from.
        guard let frame = activeScreen?.frame else { return false }
        guard cursor.x >= frame.minX, cursor.x <= frame.maxX, cursor.y >= frame.maxY - Self.triggerHeight else { return false }
        return abs(cursor.x - frame.midX) <= Self.triggerHalfWidth
    }

    private func showPanel(on screen: NSScreen) {
        cancelDwell()
        targetWindow = AXWindow.frontmostFocusedWindow()
        activeScreen = screen
        panel.show(on: screen)
    }

    private func hidePanel() {
        panel.hide()
        activeScreen = nil
        targetWindow = nil
    }

    private func pick(_ preset: LayoutPreset) {
        defer { hidePanel() }
        guard let screen = activeScreen, let window = targetWindow, let currentFrame = window.frame else { return }
        let portrait = screen.frame.height > screen.frame.width
        let visibleFrame = screen.visibleFrame

        if preset == .restore {
            guard let info = lastMoved[window] else { return } // nothing known: no-op
            window.setFrame(info.preMove)
            lastMoved.removeValue(forKey: window)
            return
        }

        guard let action = snapAction(for: preset) else { return }
        guard let target = SnapGeometry.frame(for: action, visibleFrame: visibleFrame,
                                              currentWindowFrame: currentFrame, portrait: portrait) else { return }
        apply(target, to: window, currentFrame: currentFrame)
    }

    /// `bigLeftStack` is one thumbnail with three separately clickable zones;
    /// its own callback path (`pickZone`) supplies the actual `SnapAction`.
    private func snapAction(for preset: LayoutPreset) -> SnapAction? {
        switch preset {
        case .leftHalf: return .leftHalf
        case .rightHalf: return .rightHalf
        case .center: return .center
        case .maximize: return .maximize
        case .restore, .bigLeftStack: return nil
        }
    }

    /// Called for the three zones inside the big-left-stack thumbnail.
    fileprivate func pickStackZone(_ action: SnapAction) {
        defer { hidePanel() }
        guard let screen = activeScreen, let window = targetWindow, let currentFrame = window.frame else { return }
        let portrait = screen.frame.height > screen.frame.width
        guard let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                              currentWindowFrame: currentFrame, portrait: portrait) else { return }
        apply(target, to: window, currentFrame: currentFrame)
    }

    /// Same "was this drop actually applied" bookkeeping as `SnapManager`:
    /// remembers the pre-move frame only when the write is confirmed, and
    /// carries the original pre-move frame forward across repeated picks.
    private func apply(_ target: CGRect, to window: AXWindow, currentFrame: CGRect) {
        let preMove: CGRect
        if let info = lastMoved[window], isClose(currentFrame, info.target) {
            preMove = info.preMove
        } else {
            preMove = currentFrame
        }
        window.setFrame(target)
        if let readBack = window.frame, isClose(readBack, target) {
            lastMoved[window] = (target: target, preMove: preMove)
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
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = LayoutMenuView(onPick: onPick, onPickZone: onPickZone)
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { false }

    func show(on screen: NSScreen) {
        let frame = screen.frame
        let origin = CGPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 6)
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
