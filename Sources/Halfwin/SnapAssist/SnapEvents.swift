import AppKit

/// Shared notification for successful Halfwin snaps. Called on the app's event loop.
enum SnapEvents {
    nonisolated(unsafe) static var handler: ((AXWindow, SnapAction, NSScreen) -> Void)?

    static func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen) {
        handler?(window, action, screen)
    }
}
