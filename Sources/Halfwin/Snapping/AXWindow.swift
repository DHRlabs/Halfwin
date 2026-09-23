import AppKit
import ApplicationServices

/// Global-screen coordinate flip between AppKit (origin bottom-left of the
/// primary display) and Accessibility/CoreGraphics (origin top-left). The
/// formula is its own inverse, so the same property converts both ways.
/// Adapted from Rectangle's `screenFlipped` (Rectangle/Extensions, MIT).
private var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

extension CGPoint {
    var axFlipped: CGPoint { CGPoint(x: x, y: primaryScreenHeight - y) }
}

extension CGRect {
    var axFlipped: CGRect { CGRect(x: minX, y: primaryScreenHeight - maxY, width: width, height: height) }
}

/// A window reached through the Accessibility API. Adapted from Rectangle's
/// `AccessibilityElement.swift` (MIT), trimmed to the lookup and frame
/// read/write this app needs: no enhanced-UI dance, no window-id resolution.
struct AXWindow {
    let element: AXUIElement

    var title: String? {
        guard let title: String = Self.objectAttribute(element, kAXTitleAttribute) else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isMinimized: Bool {
        Self.objectAttribute(element, kAXMinimizedAttribute) ?? false
    }

    var processIdentifier: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    var frame: CGRect? {
        Self.frame(of: element)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let position: AXValue = objectAttribute(element, kAXPositionAttribute),
              let size: AXValue = objectAttribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions).axFlipped
    }

    /// Set size, then position, then size again: macOS clamps the size to
    /// whichever display the position lands on, so the final call wins.
    func setFrame(_ appKitFrame: CGRect) {
        let target = appKitFrame.axFlipped
        setSizeAttribute(kAXSizeAttribute, target.size)
        setPointAttribute(kAXPositionAttribute, target.origin)
        setSizeAttribute(kAXSizeAttribute, target.size)
    }

    /// The window under a point in AppKit screen coordinates, the way a
    /// title-bar drag would resolve it: the element there, or its ancestor
    /// window if the hit element is a child (title bar, close button, etc).
    static func windowUnderCursor(at appKitPoint: CGPoint) -> AXWindow? {
        hitTest(at: appKitPoint)?.window
    }

    /// The hit element and its containing window, for deciding which part of
    /// a window received a system-wide click.
    static func hitTest(at appKitPoint: CGPoint) -> (element: AXUIElement, window: AXWindow)? {
        let systemWide = AXUIElementCreateSystemWide()
        // Keep a stuck AX call from stalling the main thread indefinitely.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        let point = appKitPoint.axFlipped
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.1)
        if role(of: element) == kAXWindowRole { return (element, AXWindow(element: element)) }
        var current = element
        for _ in 0..<8 {
            guard let parent: AXUIElement = objectAttribute(current, kAXParentAttribute) else { break }
            if role(of: parent) == kAXWindowRole {
                AXUIElementSetMessagingTimeout(parent, 0.1)
                return (element, AXWindow(element: parent))
            }
            current = parent
        }
        return nil
    }

    /// The frontmost app's focused window for system-wide keyboard actions
    /// and menu-driven layout picks.
    static func focusedWindow() -> AXWindow? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindow(of: application)
    }

    static func focusedWindow(of app: NSRunningApplication) -> AXWindow? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        guard let window: AXUIElement = objectAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.1)
        guard role(of: window) == kAXWindowRole else { return nil }
        return AXWindow(element: window)
    }

    /// The standard windows reported for a regular app by the Accessibility API.
    static func standardWindows(of app: NSRunningApplication) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        guard let elements: [AXUIElement] = objectAttribute(appElement, kAXWindowsAttribute) else { return [] }
        return elements.compactMap { element in
            AXUIElementSetMessagingTimeout(element, 0.1)
            guard let role: String = objectAttribute(element, kAXRoleAttribute), role == kAXWindowRole,
                  let subrole: String = objectAttribute(element, kAXSubroleAttribute), subrole == kAXStandardWindowSubrole else { return nil }
            return AXWindow(element: element)
        }
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func restoreAndRaise(in app: NSRunningApplication) {
        AXUIElementSetMessagingTimeout(element, 0.1)
        let restored = !isMinimized || AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        let main = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        let frontmost = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        if !restored || !raised || !main || !frontmost {
            app.activate(options: .activateAllWindows)
        }
    }

    static func role(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func subrole(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func objectAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func setPointAttribute(_ name: String, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    private func setSizeAttribute(_ name: String, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }
}

extension AXWindow: Hashable {
    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
