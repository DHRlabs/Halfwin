import AppKit

enum SnapOrigin {
    case layoutMenu, other
}

/// Shared notification for successful Halfwin snaps. Called on the app's event loop.
enum SnapEvents {
    nonisolated(unsafe) static var handler: ((AXWindow, SnapAction, NSScreen, SnapOrigin) -> Void)?

    static func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen,
                        origin: SnapOrigin = .other, frame: CGRect? = nil) {
        SnapWindowRegistry.shared.commitSnap(window: window, action: action, screen: screen, frame: frame)
        handler?(window, action, screen, origin)
    }
}
