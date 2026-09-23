import AppKit

private final class FeatureSwitchMenuRow: NSView {
    private static let width: CGFloat = 280
    private static let height: CGFloat = 22
    private static let titleInset: CGFloat = 22
    private static let switchSize = NSSize(width: 26, height: 15)

    private weak var featureSwitch: FeatureSwitch?
    private let title: String
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(title: String, featureSwitch: FeatureSwitch) {
        self.title = title
        self.featureSwitch = featureSwitch
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        super.updateTrackingAreas()
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        self.trackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        _ = toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(rect: bounds).fill()
        }

        let isOn = featureSwitch?.isOn ?? false
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: isHovered ? NSColor.white : NSColor.labelColor
        ]
        let titleSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: Self.titleInset, y: (bounds.height - titleSize.height) / 2),
            withAttributes: attributes
        )

        let track = NSRect(
            x: bounds.maxX - 16 - Self.switchSize.width,
            y: (bounds.height - Self.switchSize.height) / 2,
            width: Self.switchSize.width,
            height: Self.switchSize.height
        )
        (isOn ? NSColor.controlAccentColor : NSColor.systemGray).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()

        let knobSize: CGFloat = 11
        let knobX = isOn ? track.maxX - 2 - knobSize : track.minX + 2
        let knob = NSRect(x: knobX, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    func refresh() {
        setAccessibilityValue(NSNumber(value: featureSwitch?.isOn ?? false))
        needsDisplay = true
    }

    @discardableResult
    private func toggle() -> Bool {
        guard let featureSwitch else { return false }
        featureSwitch.isOn.toggle()
        needsDisplay = true
        return true
    }
}

/// One on/off switch for one Halfwin feature: saved in UserDefaults and shown
/// in the menu bar menu as a row with a switch, so every feature can be
/// turned on or off with a single flick.
final class FeatureSwitch: NSObject {
    let title: String
    private let key: String
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppliedValue: Bool?
    private weak var menuRow: FeatureSwitchMenuRow?
    /// Called on the main thread whenever the switch changes, including once
    /// from `start()` so the owner can apply the saved state at launch.
    var onChange: ((Bool) -> Void)?

    init(key: String, title: String, defaultOn: Bool) {
        self.key = "Halfwin.feature." + key
        self.title = title
        UserDefaults.standard.register(defaults: [self.key: defaultOn])
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isOn != self.lastAppliedValue else { return }
            self.apply(self.isOn)
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            let changed = isOn != newValue
            UserDefaults.standard.set(newValue, forKey: key)
            if changed { apply(newValue) }
        }
    }

    func start() {
        let value = isOn
        lastAppliedValue = value
        menuRow?.refresh()
        onChange?(value)
    }

    /// A menu row: the feature's name on the left, its switch on the right.
    func makeMenuItem() -> NSMenuItem {
        let row = FeatureSwitchMenuRow(title: title, featureSwitch: self)
        menuRow = row
        let item = NSMenuItem()
        item.view = row
        return item
    }

    private func apply(_ value: Bool) {
        guard lastAppliedValue != value else { return }
        lastAppliedValue = value
        menuRow?.refresh()
        onChange?(value)
    }

    #if DEBUG
    static func renderPreview(to url: URL) {
        let previewID = UUID().uuidString
        let switches = [
            FeatureSwitch(key: "menu-preview-\(previewID)-1", title: "Preview feature one", defaultOn: true),
            FeatureSwitch(key: "menu-preview-\(previewID)-2", title: "Preview feature two", defaultOn: false),
            FeatureSwitch(key: "menu-preview-\(previewID)-3", title: "Preview feature three", defaultOn: true)
        ]
        let rowHeight: CGFloat = 22
        let preview = NSBox(frame: NSRect(x: 0, y: 0, width: 280, height: rowHeight * 3))
        preview.boxType = .custom
        preview.borderWidth = 0
        preview.contentViewMargins = .zero
        preview.fillColor = NSColor(white: 0.16, alpha: 1)
        preview.appearance = NSAppearance(named: .darkAqua)
        for (index, featureSwitch) in switches.enumerated() {
            let row = FeatureSwitchMenuRow(title: featureSwitch.title, featureSwitch: featureSwitch)
            row.frame = NSRect(x: 0, y: rowHeight * CGFloat(2 - index), width: 280, height: rowHeight)
            preview.contentView?.addSubview(row)
        }

        guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else {
            NSLog("Halfwin: could not render menu preview")
            return
        }
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            NSLog("Halfwin: could not encode menu preview")
            return
        }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            NSLog("Halfwin: could not write menu preview: %@", error.localizedDescription)
        }
    }
    #endif
}
