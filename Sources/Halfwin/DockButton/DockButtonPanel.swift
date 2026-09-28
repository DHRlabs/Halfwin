import AppKit
import ApplicationServices

private enum DockButtonEdge: Equatable {
    case bottom
    case left
    case right
}

private struct DockButtonLocation {
    let frame: CGRect
    let screenFrame: CGRect
    let edge: DockButtonEdge

    var buttonFrame: CGRect {
        let target: CGFloat = 16
        let gap: CGFloat = 8
        switch edge {
        case .bottom:
            let fitsAtEnd = frame.maxX + gap + target <= screenFrame.maxX
            let rawX = fitsAtEnd ? frame.maxX + gap : frame.maxX - target
            let height = min(frame.height, screenFrame.height)
            let rawY = fitsAtEnd ? frame.minY : frame.maxY + gap
            let x = min(max(rawX, screenFrame.minX), screenFrame.maxX - target)
            let y = min(max(rawY, screenFrame.minY), screenFrame.maxY - height)
            return CGRect(x: x, y: y, width: target, height: height)
        case .left, .right:
            let width = min(frame.width, screenFrame.width)
            let x = min(max(frame.minX, screenFrame.minX), screenFrame.maxX - width)
            let y = min(max(frame.minY - gap - target, screenFrame.minY), screenFrame.maxY - target)
            return CGRect(x: x, y: y, width: width, height: target)
        }
    }
}

@MainActor
final class DockButtonManager {
    private let panel = DockButtonPanel()
    private let client: DockButtonClient
    private lazy var tracker = DockButtonDockTracker { [weak self] location in
        guard let self else { return }
        if let location { self.dockLocation = location }
        else if !self.panel.pointerIsInButtonArea { self.dockLocation = nil }
        self.refreshPanel()
    }
    private let toggleShowDesktop: () -> Bool?
    private let isShowDesktopActive: () -> Bool
    private var enabled = false
    private var trackerStarted = false
    private var toggled = false
    private var fallbackVisible = false
    private var dockLocation: DockButtonLocation?

    init(toggleShowDesktop: @escaping () -> Bool?, isShowDesktopActive: @escaping () -> Bool) {
        self.toggleShowDesktop = toggleShowDesktop
        self.isShowDesktopActive = isShowDesktopActive
        client = DockButtonClient(invoke: toggleShowDesktop, isToggled: isShowDesktopActive)
        client.onFallbackVisibilityChange = { [weak self] visible in
            self?.fallbackVisible = visible
            self?.refreshPanel()
        }
        panel.onActivate = { [weak self] in
            guard let self, let state = self.toggleShowDesktop() else { return }
            self.setToggled(state)
        }
    }

    func start() {
        toggled = isShowDesktopActive()
        client.setToggled(toggled)
        client.start()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        client.setEnabled(enabled)
        if enabled, !trackerStarted {
            tracker.start()
            trackerStarted = true
        } else if !enabled, trackerStarted {
            tracker.stop()
            trackerStarted = false
            dockLocation = nil
            fallbackVisible = false
        }
        refreshPanel()
    }

    func setToggled(_ toggled: Bool) {
        self.toggled = toggled
        client.setToggled(toggled)
        refreshPanel()
    }

    func stop() {
        client.stop()
        if trackerStarted { tracker.stop() }
        trackerStarted = false
        panel.orderOut(nil)
        dockLocation = nil
    }

    private func refreshPanel() {
        guard enabled, fallbackVisible, let dockLocation else {
            panel.orderOut(nil)
            return
        }
        panel.show(at: dockLocation.buttonFrame, edge: dockLocation.edge, toggled: toggled)
    }
}

@MainActor
private final class DockButtonDockTracker {
    private let onLocation: (DockButtonLocation?) -> Void
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var promptedForAccessibility = false

    init(onLocation: @escaping (DockButtonLocation?) -> Void) {
        self.onLocation = onLocation
    }

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        onLocation(nil)
    }

    private func poll() {
        guard AXIsProcessTrusted() else {
            onLocation(nil)
            if !promptedForAccessibility {
                promptedForAccessibility = true
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated }) else {
            onLocation(nil)
            return
        }

        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let children: [AXUIElement] = attribute(application, kAXChildrenAttribute),
              let list = children.first(where: { child in
                  AXUIElementSetMessagingTimeout(child, 0.1)
                  return AXWindow.role(of: child) == kAXListRole
              }) else {
            onLocation(nil)
            return
        }
        AXUIElementSetMessagingTimeout(list, 0.1)
        guard
              let frame = AXWindow.frame(of: list), frame.width > 0, frame.height > 0,
              let orientation: String = attribute(list, kAXOrientationAttribute),
              let (screen, overlap) = NSScreen.screens.compactMap({ screen -> (NSScreen, CGRect)? in
                  let overlap = frame.intersection(screen.frame)
                  return overlap.isNull || overlap.width <= 0 || overlap.height <= 0 ? nil : (screen, overlap)
              }).max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height })
        else {
            onLocation(nil)
            return
        }

        guard orientation == kAXHorizontalOrientationValue as String
                || orientation == kAXVerticalOrientationValue as String else {
            onLocation(nil)
            return
        }
        let edge = dockEdge(for: frame, screen: screen.frame, orientation: orientation)
        let visibleFraction = edge == .bottom ? overlap.width / frame.width : overlap.height / frame.height
        let visibleThickness = edge == .bottom ? overlap.height / frame.height : overlap.width / frame.width
        guard visibleFraction >= 0.75, visibleThickness >= 0.75 else {
            onLocation(nil)
            return
        }
        onLocation(DockButtonLocation(frame: frame, screenFrame: screen.frame, edge: edge))
    }

    private func dockEdge(for frame: CGRect, screen: CGRect, orientation: String) -> DockButtonEdge {
        // Match DockPreviewManager's horizontal/nearest-side orientation rule.
        if orientation == kAXHorizontalOrientationValue as String { return .bottom }
        guard orientation == kAXVerticalOrientationValue as String else { return .bottom }
        let leftDistance = abs(frame.minX - screen.minX)
        let rightDistance = abs(screen.maxX - frame.maxX)
        return leftDistance <= rightDistance ? .left : .right
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

@MainActor
private final class DockButtonPanel: NSPanel {
    private let button = DockButtonView()
    var onActivate: (() -> Void)? {
        didSet { button.onActivate = onActivate }
    }

    var pointerIsInButtonArea: Bool { isVisible && frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = button
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        orderOut(nil)
    }

    required init?(coder: NSCoder) { nil }

    func show(at frame: CGRect, edge: DockButtonEdge, toggled: Bool) {
        button.update(edge: edge, toggled: toggled)
        if self.frame != frame { setFrame(frame, display: true) }
        if !isVisible { orderFrontRegardless() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DockButtonView: NSView {
    var onActivate: (() -> Void)?
    private var edge = DockButtonEdge.bottom
    private var toggled = false
    private var isHovered = false
    private let visibleStripThickness: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(DockButtonProtocol.label)
    }

    required init?(coder: NSCoder) { nil }

    func update(edge: DockButtonEdge, toggled: Bool) {
        self.edge = edge
        self.toggled = toggled
        let tooltip = toggled ? "Restore windows" : DockButtonProtocol.label
        toolTip = tooltip
        setAccessibilityHelp(tooltip)
        setAccessibilityValue(NSNumber(value: toggled))
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || toggled {
            NSColor.controlAccentColor.withAlphaComponent(isHovered ? 0.24 : 0.12).setFill()
            NSBezierPath(rect: bounds).fill()
        }
        let strip = edge == .bottom
            ? NSRect(x: bounds.maxX - visibleStripThickness, y: bounds.minY,
                     width: visibleStripThickness, height: bounds.height)
            : NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: visibleStripThickness)
        NSColor.separatorColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(rect: strip).fill()
        let line = NSBezierPath()
        line.lineWidth = 1
        if edge == .bottom {
            line.move(to: NSPoint(x: strip.minX + 0.5, y: bounds.minY))
            line.line(to: NSPoint(x: strip.minX + 0.5, y: bounds.maxY))
        } else {
            line.move(to: NSPoint(x: bounds.minX, y: strip.maxY - 0.5))
            line.line(to: NSPoint(x: bounds.maxX, y: strip.maxY - 0.5))
        }
        NSColor.separatorColor.setStroke()
        line.stroke()
    }
}
