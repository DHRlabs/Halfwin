import AppKit

/// The translucent preview shown over a snap target while dragging. A small,
/// static stand-in for Rectangle's `FootprintWindow.swift` (MIT): no blur,
/// no animation, no accessibility-motion handling — just a rounded,
/// non-activating panel that ignores the mouse and follows every Space.
final class FootprintWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 10
        box.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.3)
        contentView = box
    }

    override var canBecomeKey: Bool { false }

    func show(in frame: CGRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}
