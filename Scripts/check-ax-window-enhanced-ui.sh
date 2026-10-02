#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

{
    cat <<'SWIFT'
import Foundation

typealias CFString = String
typealias pid_t = Int32

let kAXSizeAttribute = "AXSize"
let kAXPositionAttribute = "AXPosition"
let enhancedUIAttribute = "AXEnhancedUserInterface"
let kCFBooleanFalse: AnyObject = NSNumber(value: false)
let kCFBooleanTrue: AnyObject = NSNumber(value: true)

enum AXError: Int, CustomStringConvertible {
    case success = 0
    case failure = 1
    case attributeUnsupported = 2

    var description: String { "AXError(\(rawValue))" }
}

enum AXValueType {
    case cgPoint
    case cgSize
}

final class AXValue {
    let type: AXValueType
    let payload: Any

    init<T>(_ type: AXValueType, _ payload: T) {
        self.type = type
        self.payload = payload
    }

    var description: String {
        switch (type, payload) {
        case (.cgPoint, let point as CGPoint): "point:\(point.x),\(point.y)"
        case (.cgSize, let size as CGSize): "size:\(size.width),\(size.height)"
        default: "unknown"
        }
    }
}

final class AXUIElement {
    enum Kind { case application, window }
    let id: String
    let pid: pid_t
    let kind: Kind

    init(_ id: String, pid: pid_t = 41, kind: Kind = .window) {
        self.id = id
        self.pid = pid
        self.kind = kind
    }
}

enum Fixture {
    static var events: [String] = []
    static var flag = false
    static var readError: AXError = .success
    static var failedWindowAttribute: String?
}

func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement {
    AXUIElement("app-\(pid)", pid: pid, kind: .application)
}

func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ timeout: Double) {}

func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ name: CFString,
                                   _ value: inout AnyObject?) -> AXError {
    guard element.kind == .application, name == enhancedUIAttribute else { return .attributeUnsupported }
    Fixture.events.append("read-flag")
    guard Fixture.readError == .success else { return Fixture.readError }
    value = NSNumber(value: Fixture.flag)
    return .success
}

func AXUIElementSetAttributeValue(_ element: AXUIElement, _ name: CFString,
                                  _ value: AnyObject) -> AXError {
    if element.kind == .application, name == enhancedUIAttribute {
        guard let number = value as? NSNumber else { return .failure }
        let enabled = number.boolValue
        Fixture.events.append(enabled ? "restore-flag" : "disable-flag")
        Fixture.flag = enabled
        return .success
    }
    guard let axValue = value as? AXValue else { return .failure }
    Fixture.events.append("write:\(name):\(axValue.description)")
    return Fixture.failedWindowAttribute == name ? .failure : .success
}

func AXValueCreate<T>(_ type: AXValueType, _ value: inout T) -> AXValue? {
    AXValue(type, value)
}

func CFHash(_ element: AXUIElement) -> Int { element.id.hashValue }

enum Privacy { case `public` }

struct LogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) {}
        mutating func appendInterpolation<T>(_ value: T) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {}
    }
    init(stringLiteral value: String) {}
    init(stringInterpolation value: StringInterpolation) {}
}

struct Logger {
    init(subsystem: String, category: String) {}
    func notice(_ message: LogMessage) {}
}

extension CGRect {
    func axFlipped(primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: self.origin.x,
                               y: primaryScreenHeight - self.origin.y - self.size.height),
               size: self.size)
    }
}

struct AXWindow {
    private static let diagLogger = Logger(subsystem: "test", category: "diag")
    let element: AXUIElement
    var processIdentifier: pid_t? { element.pid }

    static func frameWithError(of element: AXUIElement) -> (frame: CGRect?, error: AXError) {
        (nil, .success)
    }
SWIFT
    awk '
        /^    func setFrame\(_ appKitFrame: CGRect, primaryScreenHeight:/ { capture = 1 }
        /^    \/\/\/ The window under a point/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$root/Sources/Halfwin/Snapping/AXWindow.swift"
    awk '
        /^    private func setPointAttribute/ { capture = 1 }
        capture && /^}/ { exit }
        capture { sub(/^    /, ""); print }
    ' "$root/Sources/Halfwin/Snapping/AXWindow.swift"
    cat <<'SWIFT'
}

let expectedWrites = [
    "write:AXSize:size:50.0,60.0",
    "write:AXPosition:point:30.0,900.0",
    "write:AXSize:size:50.0,60.0"
]

func run(_ flag: Bool, readError: AXError = .success, failAttribute: String? = nil) {
    Fixture.events = []
    Fixture.flag = flag
    Fixture.readError = readError
    Fixture.failedWindowAttribute = failAttribute
    let window = AXUIElement("window")
    AXWindow(element: window).setFrame(
        CGRect(origin: CGPoint(x: 30, y: 40), size: CGSize(width: 50, height: 60)),
        primaryScreenHeight: 1000
    )
}

run(true)
assert(Fixture.events == ["read-flag", "disable-flag"] + expectedWrites + ["restore-flag"],
       "enabled sequence changed: \(Fixture.events)")
assert(Fixture.flag, "enabled state was not restored")

run(false)
assert(Fixture.events == ["read-flag"] + expectedWrites, "false state was toggled or writes changed")
assert(!Fixture.flag, "false state changed")

run(false, readError: .attributeUnsupported)
assert(Fixture.events == ["read-flag"] + expectedWrites, "unsupported state blocked writes or toggled")

run(true, failAttribute: kAXPositionAttribute)
assert(Fixture.events == ["read-flag", "disable-flag"] + expectedWrites + ["restore-flag"],
       "write failure skipped later writes or restoration: \(Fixture.events)")
assert(Fixture.flag, "failed frame write left enhanced UI disabled")

print("AXWindow enhanced-UI frame-write assertions passed")
SWIFT
} > "$scratch/main.swift"

swiftc "$scratch/main.swift" -o "$scratch/check-ax-window-enhanced-ui"
"$scratch/check-ax-window-enhanced-ui"
