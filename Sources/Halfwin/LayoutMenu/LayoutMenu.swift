import AppKit
import SwiftUI
import Combine

/// Persists the layout-menu settings. Same shape as `SnapSettings`:
/// UserDefaults-backed and changeable in Settings.
final class LayoutMenuSettings: ObservableObject {
    static let shared = LayoutMenuSettings()

    private let defaults = UserDefaults.standard
    private let enabledKey = "Halfwin.layoutMenuEnabled"
    private let dwellKey = "Halfwin.layoutMenuDwellDelay"
    private let hotZoneWidthKey = "Halfwin.layoutMenuHotZoneWidth"
    private let sizePercentKey = "Halfwin.layoutMenuSizePercent"

    static let defaultDwellDelay: Double = 0.35
    static let defaultHotZoneWidth: CGFloat = 400
    static let defaultSizePercent: Double = 100

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: enabledKey) }
    }

    @Published var dwellDelay: Double {
        didSet { defaults.set(dwellDelay, forKey: dwellKey) }
    }

    @Published var hotZoneWidth: CGFloat {
        didSet {
            let value = Self.clampedHotZoneWidth(hotZoneWidth)
            if value != hotZoneWidth { hotZoneWidth = value }
            defaults.set(Double(value), forKey: hotZoneWidthKey)
        }
    }

    @Published var sizePercent: Double {
        didSet {
            let value = Self.clampedSizePercent(sizePercent)
            if value != sizePercent { sizePercent = value }
            defaults.set(value, forKey: sizePercentKey)
        }
    }

    @Published var commandCenterSideFraction = SnapGeometry.commandCenterSideFraction {
        didSet { SnapGeometry.commandCenterSideFraction = commandCenterSideFraction }
    }

    private init() {
        enabled = defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
        let saved = defaults.object(forKey: dwellKey) as? Double ?? Self.defaultDwellDelay
        dwellDelay = min(max(saved, 0.1), 1.5)
        let savedHotZoneWidth = CGFloat(defaults.object(forKey: hotZoneWidthKey) as? Double ?? Double(Self.defaultHotZoneWidth))
        hotZoneWidth = Self.clampedHotZoneWidth(savedHotZoneWidth)
        sizePercent = Self.clampedSizePercent(defaults.object(forKey: sizePercentKey) as? Double ?? Self.defaultSizePercent)
    }

    private static func clampedHotZoneWidth(_ value: CGFloat) -> CGFloat {
        min(max(value.isFinite ? value : defaultHotZoneWidth, 200), 1200)
    }

    private static func clampedSizePercent(_ value: Double) -> Double {
        let rounded = ((value.isFinite ? value : defaultSizePercent) / 25).rounded() * 25
        return min(max(rounded, 75), 200)
    }
}

/// A single tile in the layout menu. Most map straight to a `SnapAction`;
/// `restore` doesn't fit that enum (it replays a remembered frame instead of
/// computing one), so it's handled locally. Multi-zone tiles carry their
/// `SnapAction` in the `.layout` case.
enum LayoutPreset: Equatable {
    case leftHalf, rightHalf, center, restore, maximize
}

enum LayoutDropZone: Equatable {
    case preset(LayoutPreset)
    case layout(SnapAction)
}

private struct LayoutMenuZone: Identifiable {
    let name: String
    let dropZone: LayoutDropZone
    let rect: CGRect

    var id: String { name }
}

private enum LayoutMenuTile: Identifiable {
    case preset(title: String, preset: LayoutPreset, rect: CGRect)
    case layout(SnapMultiWindowLayout)

    var id: String { title }

    var title: String {
        switch self {
        case .preset(let title, _, _): return title
        case .layout(.leftStack): return "Big Left + Stack"
        case .layout(let layout): return layout.title
        }
    }

    func zones(portrait: Bool) -> [LayoutMenuZone] {
        switch self {
        case .preset(let title, let preset, let rect):
            return [LayoutMenuZone(name: title, dropZone: .preset(preset), rect: rect)]
        case .layout(let layout):
            return layout.zones(portrait: portrait).map {
                LayoutMenuZone(name: $0.action.displayName, dropZone: .layout($0.action), rect: $0.rect)
            }
        }
    }
}

private enum LayoutMenuTiles {
    static var all: [LayoutMenuTile] {
        let halves = SnapMultiWindowLayout.halves.zones
        return [
            .preset(title: "Left Half", preset: .leftHalf, rect: halves[0].rect),
            .preset(title: "Right Half", preset: .rightHalf, rect: halves[1].rect),
            .preset(title: "Center", preset: .center, rect: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)),
            .preset(title: "Normal", preset: .restore, rect: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)),
            .preset(title: "Maximize", preset: .maximize, rect: CGRect(x: 0, y: 0, width: 1, height: 1)),
            .layout(.leftStack), .layout(.thirds), .layout(.commandCenter),
        ]
    }
}

private final class LayoutMenuDropState: ObservableObject {
    @Published var highlightedZone: LayoutDropZone?
    @Published var isDropMode = false
    @Published var isPortrait = false
    @Published var showCount = 0
    @Published var hoveredZone: LayoutDropZone?
    @Published var preview = LayoutMenuPreview.empty
    @Published var scale: CGFloat = 1
}

private struct LayoutMenuPreview {
    let targetIcon: NSImage?
    let fillMode: SnapAssistFillMode
    let rememberedWindows: [String: [SnapAction: AXWindow]]
    let choices: [String: [SnapWindowChoice]]

    static let empty = LayoutMenuPreview(targetIcon: nil, fillMode: .mostRecent,
                                         rememberedWindows: [:], choices: [:])
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
    private let dropState = LayoutMenuDropState()
    private lazy var panel = LayoutMenuPanel(
        dropState: dropState,
        settings: settings,
        previewIcons: { [weak self] in self?.makePreview() ?? .empty },
        onPick: { [weak self] preset in self?.pick(preset) },
        onPickZone: { [weak self] action in self?.pickLayoutZone(action) }
    )

    /// The display currently armed (dwelling or shown) for.
    private var armedScreen: NSScreen?
    /// The screen and window the panel is currently showing for.
    private var activeScreen: NSScreen?
    private var targetWindow: AXWindow?
    private(set) var isDropBarVisible = false
    private var dropStartFrame: CGRect?

    /// Pre-move frame per window, the same shape as `SnapManager.snappedInfo`:
    /// remembers what to restore to, dropped once the window has moved away
    /// from where this menu last put it.
    nonisolated(unsafe) private static var lastMoved: [AXWindow: (target: CGRect, preMove: CGRect)] = [:]

    /// True right after Escape or a pick dismisses the panel while the
    /// pointer is still inside the trigger strip: suppresses re-arming the
    /// dwell timer until the pointer actually leaves, so the panel doesn't
    /// pop right back up.
    private var suppressRearmUntilLeave = false

    private static let triggerHeight: CGFloat = 4

    var hotZoneWidth: CGFloat { settings.hotZoneWidth }

    init(settings: LayoutMenuSettings) {
        self.settings = settings
        settings.$enabled
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshPermission() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshPermission()
            guard self.panel.isVisible,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != self.targetWindow?.processIdentifier else { return }
            self.hidePanel()
        }
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
        if isDropBarVisible { return } // The drag monitor owns drop-bar tracking.
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
            return abs(cursor.x - frame.midX) <= settings.hotZoneWidth / 2
        }
    }

    /// True anywhere from the trigger strip at the top of `activeScreen` down
    /// to the panel's bottom edge, within a band at least as wide as the
    /// trigger strip and at least as wide as the panel — so moving from the
    /// strip into the panel (which sits below any notch) never dismisses it,
    /// and a stacked display below/above never reads as "near".
    private func isNearPanelOrTrigger(_ cursor: CGPoint) -> Bool {
        guard let frame = activeScreen?.frame else { return false }
        let halfWidth = max(settings.hotZoneWidth / 2, panel.frame.width / 2)
        guard cursor.x >= frame.midX - halfWidth, cursor.x <= frame.midX + halfWidth else { return false }
        return cursor.y >= panel.frame.minY && cursor.y <= frame.maxY
    }

    private func showPanel(on screen: NSScreen) {
        cancelDwell()
        guard Permissions.accessibilityGranted else { return }
        pruneUnreadableRestoreInfo()
        targetWindow = AXWindow.focusedWindow()
        activeScreen = screen
        isDropBarVisible = false
        dropStartFrame = nil
        dropState.isDropMode = false
        dropState.showCount += 1
        dropState.highlightedZone = nil
        panel.show(on: screen)
    }

    func showDropBar(on screen: NSScreen, for window: AXWindow, startFrame: CGRect) {
        cancelDwell()
        guard Permissions.accessibilityGranted else { return }
        pruneUnreadableRestoreInfo()
        targetWindow = window
        activeScreen = screen
        isDropBarVisible = true
        dropStartFrame = startFrame
        dropState.isDropMode = true
        dropState.showCount += 1
        dropState.highlightedZone = nil
        panel.show(on: screen, ignoringMouseEvents: true)
    }

    func hideDropBar() {
        guard isDropBarVisible else { return }
        hidePanel(suppressRearm: true)
    }

    func dropZone(at point: CGPoint) -> LayoutDropZone? {
        guard isDropBarVisible else { return nil }
        return panel.dropZone(at: point)
    }

    func highlight(_ zone: LayoutDropZone?) {
        guard isDropBarVisible, dropState.highlightedZone != zone else { return }
        dropState.highlightedZone = zone
    }

    func isDropBarNear(_ point: CGPoint) -> Bool {
        isDropBarVisible && panel.frame.insetBy(dx: -60, dy: -60).contains(point)
    }

    func dropPreviewFrame(for zone: LayoutDropZone, currentWindowFrame: CGRect) -> CGRect? {
        guard isDropBarVisible, let screen = activeScreen, let window = targetWindow,
              let startFrame = dropStartFrame else { return nil }
        return targetFrame(for: zone, window: window, currentFrame: currentWindowFrame,
                           restoreFrame: startFrame, screen: screen)
    }

    @discardableResult
    func applyDrop(_ zone: LayoutDropZone) -> CGRect? {
        defer { hideDropBar() }
        guard isDropBarVisible, let screen = activeScreen, let window = targetWindow,
              let currentFrame = window.frame, let startFrame = dropStartFrame else { return nil }
        if case .preset(.restore) = zone {
            return restore(window: window, currentFrame: startFrame)
        }
        guard let action = action(for: zone),
              let target = targetFrame(for: zone, window: window, currentFrame: currentFrame,
                                       restoreFrame: startFrame, screen: screen) else { return nil }
        let preMove = Self.lastMoved[window].flatMap {
            SnapGeometry.isClose(startFrame, $0.target) ? $0.preMove : nil
        } ?? startFrame
        return apply(target, to: window, currentFrame: currentFrame, preMove: preMove,
                     action: action, screen: screen)
    }

    private func targetFrame(for zone: LayoutDropZone, window: AXWindow, currentFrame: CGRect,
                             restoreFrame: CGRect, screen: NSScreen) -> CGRect? {
        if case .preset(.restore) = zone {
            guard let info = Self.lastMoved[window], SnapGeometry.isClose(restoreFrame, info.target) else { return nil }
            return info.preMove
        }
        guard let action = action(for: zone) else { return nil }
        return SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                  currentWindowFrame: currentFrame, portrait: screen.frame.height > screen.frame.width)
    }

    private func action(for zone: LayoutDropZone) -> SnapAction? {
        switch zone {
        case .preset(let preset): return snapAction(for: preset)
        case .layout(let action): return action
        }
    }

    private func hidePanel(suppressRearm: Bool = false) {
        isDropBarVisible = false
        dropStartFrame = nil
        dropState.isDropMode = false
        dropState.highlightedZone = nil
        panel.hide()
        activeScreen = nil
        targetWindow = nil
        suppressRearmUntilLeave = suppressRearm
    }

    /// Windows this menu can no longer read (closed, or the AX call timed
    /// out) have nothing to restore to; drop them so the table doesn't grow
    /// forever. Mirrors `SnapManager.pruneUnreadableSnapInfo`.
    private func pruneUnreadableRestoreInfo() {
        for window in Self.lastMoved.keys where window.frame == nil {
            Self.lastMoved.removeValue(forKey: window)
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
        apply(target, to: window, currentFrame: currentFrame, action: action, screen: screen)
    }

    /// `restore` doesn't produce a `SnapAction`; multi-zone thumbnails map
    /// their picked zones directly to one.
    private func snapAction(for preset: LayoutPreset) -> SnapAction? {
        switch preset {
        case .leftHalf: return SnapMultiWindowLayout.halves.zones[0].action
        case .rightHalf: return SnapMultiWindowLayout.halves.zones[1].action
        case .center: return .center
        case .maximize: return .maximize
        case .restore: return nil
        }
    }

    /// Called for a zone inside a multi-zone thumbnail.
    fileprivate func pickLayoutZone(_ action: SnapAction) {
        defer { hidePanel(suppressRearm: true) }
        guard let screen = activeScreen, let window = targetWindow, let currentFrame = window.frame else { return }
        let portrait = screen.frame.height > screen.frame.width
        guard let target = SnapGeometry.frame(for: action, visibleFrame: screen.visibleFrame,
                                              currentWindowFrame: currentFrame, portrait: portrait) else { return }
        apply(target, to: window, currentFrame: currentFrame, action: action, screen: screen)
    }

    /// Only sound if the window is still where this menu last put it — drop
    /// the entry (no-op) otherwise, so "Normal" never yanks a window the
    /// user has since moved or resized by hand.
    @discardableResult
    private func restore(window: AXWindow, currentFrame: CGRect) -> CGRect? {
        guard let info = Self.lastMoved[window], SnapGeometry.isClose(currentFrame, info.target) else { return nil }
        window.setFrame(info.preMove)
        guard let readBack = window.frame, SnapGeometry.isClose(readBack, info.preMove) else { return nil }
        Self.lastMoved.removeValue(forKey: window)
        return readBack
    }

    /// Remembers the pre-move frame for "Normal", keyed off the frame
    /// actually read back after the move (not the intended target — AX
    /// writes can settle a point or two off, or be clamped by the app's own
    /// min size) so a later restore-eligibility check compares against
    /// reality. Carries the original pre-move frame forward across repeated
    /// picks, the same way `SnapManager.snappedInfo` does.
    @discardableResult
    private func apply(_ target: CGRect, to window: AXWindow, currentFrame: CGRect,
                       preMove explicitPreMove: CGRect? = nil,
                       action: SnapAction, screen: NSScreen) -> CGRect? {
        let preMove: CGRect
        if let explicitPreMove {
            preMove = explicitPreMove
        } else if let info = Self.lastMoved[window], SnapGeometry.isClose(currentFrame, info.target) {
            preMove = info.preMove
        } else {
            preMove = currentFrame
        }
        window.setFrame(target)
        if let readBack = window.frame {
            Self.lastMoved[window] = (target: readBack, preMove: preMove)
            if SnapGeometry.isClose(readBack, target) {
                SnapEvents.didSnap(window: window, action: action, screen: screen, origin: .layoutMenu)
            }
            return readBack
        }
        return nil
    }

    static func rememberMove(window: AXWindow, target: CGRect, currentFrame: CGRect) {
        let preMove = lastMoved[window].flatMap {
            SnapGeometry.isClose(currentFrame, $0.target) ? $0.preMove : nil
        } ?? currentFrame
        lastMoved[window] = (target: target, preMove: preMove)
    }

    private func makePreview() -> LayoutMenuPreview {
        guard let screen = activeScreen else { return .empty }
        let targetIcon = targetWindow?.processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
        let fillMode = SnapAssistSettings.shared.fillEmptySpots
        var remembered: [String: [SnapAction: AXWindow]] = [:]
        var choices: [String: [SnapWindowChoice]] = [:]

        for layout in SnapMultiWindowLayout.allCases where layout != .halves {
            let windows = SnapAssistManager.rememberedWindows(for: layout, on: screen)
                .filter { $0.value != targetWindow }
            remembered[layout.title] = windows

            guard fillMode == .mostRecent else { continue }
            let needed = layout.zones.map { selected in
                layout.zones.filter { $0.action != selected.action && windows[$0.action] == nil }.count
            }.max() ?? 0
            guard needed > 0 else { continue }
            let excluded = Set(windows.values).union(targetWindow.map { [$0] } ?? [])
            choices[layout.title] = SnapWindowInventory.choices(on: screen, excluding: excluded, limit: needed)
        }
        return LayoutMenuPreview(targetIcon: targetIcon, fillMode: fillMode,
                                 rememberedWindows: remembered, choices: choices)
    }

}

/// Borderless non-activating panel holding the layout thumbnails, dropped
/// just below the menu bar on the triggering display. Non-activating so the
/// frontmost app (whose window the picks affect) never loses focus.
private final class LayoutMenuPanel: NSPanel {
    fileprivate static let columns = 4
    fileprivate static let tileWidth: CGFloat = 120
    fileprivate static let tileHeight: CGFloat = 75
    fileprivate static let tileSpacing: CGFloat = 14
    fileprivate static let padding: CGFloat = 16
    fileprivate static let size = CGSize(
        width: CGFloat(columns) * tileWidth + CGFloat(columns - 1) * tileSpacing + padding * 2,
        height: CGFloat(2) * tileHeight + tileSpacing + padding * 2
    )
    private let dropState: LayoutMenuDropState
    private let settings: LayoutMenuSettings
    private let previewIcons: () -> LayoutMenuPreview
    private var sizeCancellable: AnyCancellable?
    private var activeScreen: NSScreen?

    init(dropState: LayoutMenuDropState, settings: LayoutMenuSettings,
         previewIcons: @escaping () -> LayoutMenuPreview, onPick: @escaping (LayoutPreset) -> Void,
         onPickZone: @escaping (SnapAction) -> Void) {
        self.settings = settings
        self.previewIcons = previewIcons
        self.dropState = dropState
        super.init(contentRect: CGRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        animationBehavior = .none
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = LayoutMenuView(dropState: dropState, onPick: onPick, onPickZone: onPickZone)
        contentView = NSHostingView(rootView: view)
        sizeCancellable = settings.$sizePercent.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeIfVisible() }
        }
    }

    override var canBecomeKey: Bool { false }

    func show(on screen: NSScreen, ignoringMouseEvents: Bool = false) {
        // Below the menu bar (and any notch), not under it: `visibleFrame`
        // already excludes that area, unlike `frame`.
        activeScreen = screen
        dropState.isPortrait = screen.frame.height > screen.frame.width
        dropState.hoveredZone = nil
        dropState.preview = .empty
        resize(on: screen)
        self.ignoresMouseEvents = ignoringMouseEvents
        orderFrontRegardless()
        let showCount = dropState.showCount
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.dropState.showCount == showCount else { return }
            self.dropState.preview = self.previewIcons()
        }
    }

    func dropZone(at point: CGPoint) -> LayoutDropZone? {
        guard frame.contains(point) else { return nil }
        let scale = dropState.scale
        for (index, tile) in LayoutMenuTiles.all.enumerated() {
            let tileFrame = Self.tileFrame(index: index, panelFrame: frame, scale: scale)
            guard tileFrame.contains(point) else { continue }
            let localPoint = CGPoint(x: point.x - tileFrame.minX, y: tileFrame.maxY - point.y)
            let tileSize = CGSize(width: Self.tileWidth * scale, height: Self.tileHeight * scale)
            return tile.zones(portrait: dropState.isPortrait).first { zone in
                Self.contains(localPoint, in: Self.zoneFrame(zone, tileSize: tileSize, scale: scale), radius: 6 * scale)
            }?.dropZone
        }
        return nil
    }

    func hide() {
        orderOut(nil)
        ignoresMouseEvents = false
        activeScreen = nil
        dropState.hoveredZone = nil
    }

    private func resizeIfVisible() {
        guard isVisible, let activeScreen else { return }
        resize(on: activeScreen)
    }

    private func resize(on screen: NSScreen) {
        let requestedScale = CGFloat(settings.sizePercent / 100)
        let scale = min(requestedScale,
                        (screen.frame.width - 32) / Self.size.width,
                        (screen.visibleFrame.height - 12) / Self.size.height)
        dropState.scale = max(0.01, scale)
        let size = CGSize(width: Self.size.width * dropState.scale, height: Self.size.height * dropState.scale)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 6)
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    fileprivate static func tileFrame(index: Int, panelFrame: CGRect, scale: CGFloat) -> CGRect {
        let column = index % columns
        let row = index / columns
        return CGRect(x: panelFrame.minX + (padding + CGFloat(column) * (tileWidth + tileSpacing)) * scale,
                      y: panelFrame.maxY - (padding + CGFloat(row + 1) * tileHeight + CGFloat(row) * tileSpacing) * scale,
                      width: tileWidth * scale, height: tileHeight * scale)
    }

    fileprivate static func zoneFrame(_ zone: LayoutMenuZone, tileSize: CGSize, scale: CGFloat) -> CGRect {
        let screen = CGRect(x: 5 * scale, y: 5 * scale,
                            width: tileSize.width - 10 * scale, height: tileSize.height - 10 * scale)
        return CGRect(x: screen.minX + zone.rect.minX * screen.width,
                      y: screen.minY + (1 - zone.rect.maxY) * screen.height,
                      width: zone.rect.width * screen.width, height: zone.rect.height * screen.height)
            .insetBy(dx: 2.5 * scale, dy: 2.5 * scale)
    }

    fileprivate static func contains(_ point: CGPoint, in rect: CGRect, radius: CGFloat) -> Bool {
        guard rect.contains(point) else { return false }
        let cornerX = point.x < rect.minX + radius ? rect.minX + radius :
            (point.x > rect.maxX - radius ? rect.maxX - radius : point.x)
        let cornerY = point.y < rect.minY + radius ? rect.minY + radius :
            (point.y > rect.maxY - radius ? rect.maxY - radius : point.y)
        return hypot(point.x - cornerX, point.y - cornerY) <= radius
    }
}

/// SwiftUI content of the panel: a two-row grid of screen-shaped layouts.
private struct LayoutMenuView: View {
    @ObservedObject var dropState: LayoutMenuDropState
    let onPick: (LayoutPreset) -> Void
    let onPickZone: (SnapAction) -> Void

    var body: some View {
        let scale = dropState.scale
        let tileSize = CGSize(width: LayoutMenuPanel.tileWidth * scale, height: LayoutMenuPanel.tileHeight * scale)
        let columns = Array(repeating: GridItem(.fixed(tileSize.width), spacing: LayoutMenuPanel.tileSpacing * scale),
                            count: LayoutMenuPanel.columns)
        LazyVGrid(columns: columns, spacing: LayoutMenuPanel.tileSpacing * scale) {
            ForEach(LayoutMenuTiles.all) { tile in
                LayoutTileView(tile: tile, dropState: dropState, onPick: onPick, onPickZone: onPickZone)
            }
        }
        .padding(LayoutMenuPanel.padding * scale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16 * scale))
        .frame(width: LayoutMenuPanel.size.width * scale, height: LayoutMenuPanel.size.height * scale)
        .id(dropState.showCount)
    }
}

/// A screen thumbnail whose hit areas use the same rounded zone frames as the panel.
private struct LayoutTileView: View {
    let tile: LayoutMenuTile
    @ObservedObject var dropState: LayoutMenuDropState
    let onPick: (LayoutPreset) -> Void
    let onPickZone: (SnapAction) -> Void

    var body: some View {
        let scale = dropState.scale
        let size = CGSize(width: LayoutMenuPanel.tileWidth * scale, height: LayoutMenuPanel.tileHeight * scale)
        let zones = tile.zones(portrait: dropState.isPortrait)
        let selectedZone = dropState.isDropMode ? dropState.highlightedZone : dropState.hoveredZone
        let activeIndex = zones.firstIndex { $0.dropZone == selectedZone }

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7 * scale)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: size.width - 10 * scale, height: size.height - 10 * scale)
                .offset(x: 5 * scale, y: 5 * scale)
            ForEach(zones.indices, id: \.self) { index in
                zoneView(zones[index], index: index, activeIndex: activeIndex,
                         selectedZone: selectedZone, size: size, scale: scale)
            }
            RoundedRectangle(cornerRadius: 7 * scale)
                .stroke(Color.secondary.opacity(0.55), lineWidth: max(0.7, scale))
                .frame(width: size.width - 10 * scale, height: size.height - 10 * scale)
                .offset(x: 5 * scale, y: 5 * scale)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .help(tile.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tile.title)
    }

    private func zoneView(_ zone: LayoutMenuZone, index: Int, activeIndex: Int?,
                          selectedZone: LayoutDropZone?, size: CGSize, scale: CGFloat) -> some View {
        let rect = LayoutMenuPanel.zoneFrame(zone, tileSize: size, scale: scale)
        let radius = 6 * scale
        let fill = activeIndex.map { selectedIndex in
            index == selectedIndex ? Color.accentColor : Color.accentColor.opacity(0.28)
        } ?? Color.secondary.opacity(0.2)
        let icon = previewIcon(for: zone, selectedZone: selectedZone)
        let label = zonesLabel(zone)

        return RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .frame(width: rect.width, height: rect.height)
            .overlay {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: max(0, min(28 * scale, rect.width - 4 * scale)),
                               height: max(0, min(28 * scale, rect.height - 4 * scale)))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { hovering in
                guard !dropState.isDropMode else { return }
                if hovering {
                    dropState.hoveredZone = zone.dropZone
                } else if dropState.hoveredZone == zone.dropZone {
                    dropState.hoveredZone = nil
                }
            }
            .onTapGesture {
                switch zone.dropZone {
                case .preset(let preset): onPick(preset)
                case .layout(let action): onPickZone(action)
                }
            }
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func previewIcon(for zone: LayoutMenuZone, selectedZone: LayoutDropZone?) -> NSImage? {
        guard let targetIcon = dropState.preview.targetIcon, let selectedZone else { return nil }
        if case .preset = zone.dropZone { return selectedZone == zone.dropZone ? targetIcon : nil }
        guard case .layout(let layout) = tile,
              case .layout(let selectedAction) = selectedZone,
              case .layout(let action) = zone.dropZone else { return nil }
        if action == selectedAction { return targetIcon }
        guard dropState.preview.fillMode == .mostRecent else { return nil }

        let remembered = dropState.preview.rememberedWindows[layout.title] ?? [:]
        if let window = remembered[action], let pid = window.processIdentifier {
            return NSRunningApplication(processIdentifier: pid)?.icon
        }
        let occupied = Set(remembered.keys).union([selectedAction])
        var choices = (dropState.preview.choices[layout.title] ?? []).makeIterator()
        for candidateZone in layout.zones where !occupied.contains(candidateZone.action) {
            guard let choice = choices.next() else { break }
            if candidateZone.action == action { return choice.application.icon }
        }
        return nil
    }

    private func zonesLabel(_ zone: LayoutMenuZone) -> String {
        tile.zones(portrait: dropState.isPortrait).count == 1 ? tile.title : "\(tile.title), \(zone.name)"
    }
}
