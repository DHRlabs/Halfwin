import AppKit

/// One on/off switch for one Halfwin feature: saved in UserDefaults and shown
/// in the menu bar menu as a row with a switch, so every feature can be
/// turned on or off with a single flick.
final class FeatureSwitch: NSObject {
    let title: String
    private let key: String
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppliedValue: Bool?
    /// Called on the main thread whenever the switch changes, including once
    /// from `start()` so the owner can apply the saved state at launch.
    var onChange: ((Bool) -> Void)?

    private lazy var control: NSSwitch = {
        let control = NSSwitch()
        control.controlSize = .mini
        control.target = self
        control.action = #selector(flipped)
        return control
    }()

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
            control.state = newValue ? .on : .off
            if changed { apply(newValue) }
        }
    }

    func start() {
        let value = isOn
        lastAppliedValue = value
        control.state = value ? .on : .off
        onChange?(value)
    }

    /// A menu row: the feature's name on the left, its switch on the right.
    func makeMenuItem() -> NSMenuItem {
        let labelButton = NSButton(title: title, target: self, action: #selector(toggleFromLabel))
        labelButton.setAccessibilityElement(false)
        labelButton.isBordered = false
        labelButton.alignment = .left
        labelButton.font = .menuFont(ofSize: 0)
        control.state = isOn ? .on : .off
        control.setAccessibilityLabel(title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labelButton, spacer, control])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 2, right: 14)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        row.autoresizingMask = [.width]
        let item = NSMenuItem()
        item.view = row
        return item
    }

    private func apply(_ value: Bool) {
        guard lastAppliedValue != value else { return }
        lastAppliedValue = value
        control.state = value ? .on : .off
        onChange?(value)
    }

    @objc private func flipped() { isOn = control.state == .on }

    @objc private func toggleFromLabel() { isOn = !isOn }
}
