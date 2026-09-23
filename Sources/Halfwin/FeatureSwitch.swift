import AppKit

/// One on/off switch for one Halfwin feature: saved in UserDefaults and shown
/// in the menu bar menu as a row with a switch, so every feature can be
/// turned on or off with a single flick.
final class FeatureSwitch: NSObject {
    let title: String
    private let key: String
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
    }

    var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            control.state = newValue ? .on : .off
            onChange?(newValue)
        }
    }

    func start() { onChange?(isOn) }

    /// A menu row: the feature's name on the left, its switch on the right.
    func makeMenuItem() -> NSMenuItem {
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        control.state = isOn ? .on : .off
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 2, right: 14)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let item = NSMenuItem()
        item.view = row
        return item
    }

    @objc private func flipped() { isOn = control.state == .on }
}
