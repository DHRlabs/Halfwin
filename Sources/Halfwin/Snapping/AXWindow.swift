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

    var frame: CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute),
              let size = sizeAttribute(kAXSizeAttribute) else { return nil }
        return CGRect(origin: position, size: size).axFlipped
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
        let systemWide = AXUIElementCreateSystemWide()
        // Keep a stuck AX call from stalling the main thread indefinitely.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        let point = appKitPoint.axFlipped
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        if role(of: element) == kAXWindowRole {
            AXUIElementSetMessagingTimeout(element, 0.1)
            return AXWindow(element: element)
        }
        var current = element
        for _ in 0..<8 {
            guard let parent: AXUIElement = objectAttribute(current, kAXParentAttribute) else { break }
            if role(of: parent) == kAXWindowRole {
                AXUIElementSetMessagingTimeout(parent, 0.1)
                return AXWindow(element: parent)
            }
            current = parent
        }
        return nil
    }

    /// The focused window of the frontmost app, the way a menu-driven layout
    /// pick resolves its target instead of a title-bar drag.
    static func frontmostFocusedWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        guard let focused: AXUIElement = objectAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.1)
        return AXWindow(element: focused)
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func objectAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func pointAttribute(_ name: String) -> CGPoint? {
        guard let axValue: AXValue = Self.objectAttribute(element, name) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ name: String) -> CGSize? {
        guard let axValue: AXValue = Self.objectAttribute(element, name) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
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
