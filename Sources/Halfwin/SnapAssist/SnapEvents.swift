import AppKit

enum SnapOrigin {
    case layoutMenu, glue, commandArrow, other
}

/// Shared notification for successful Halfwin snaps. Called on the app's event loop.
enum SnapEvents {
    /// Posted when the Command key comes up after Command-arrow presses, so
    /// Snap Assist can open for the last snap in that run.
    static let commandArrowDidFinish = Notification.Name("Halfwin.commandArrowDidFinish")
    /// Posted before each Command-arrow press takes effect, so Snap Assist
    /// drops the prompt an earlier press queued when this one does not snap.
    static let commandArrowDidCancel = Notification.Name("Halfwin.commandArrowDidCancel")

    nonisolated(unsafe) static var handler: ((AXWindow, SnapAction, NSScreen, SnapOrigin) -> Void)?

    static func commandArrowFinished() {
        NotificationCenter.default.post(name: commandArrowDidFinish, object: nil)
    }

    static func commandArrowCancelled() {
        NotificationCenter.default.post(name: commandArrowDidCancel, object: nil)
    }

    static func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen,
                        origin: SnapOrigin = .other, frame: CGRect? = nil,
                        layout: SnapMultiWindowLayout? = nil) {
        SnapWindowRegistry.shared.commitSnap(window: window, action: action, screen: screen,
                                             frame: frame, origin: origin, layout: layout)
        handler?(window, action, screen, origin)
    }
}
