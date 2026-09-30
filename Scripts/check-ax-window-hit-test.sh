#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

{
    cat <<'SWIFT'
import Foundation

typealias CGFloat = Double
typealias CFString = String
typealias CFTypeID = UInt64

struct CGPoint {
    var x: CGFloat
    var y: CGFloat
    var axFlipped: CGPoint { self }
}

enum AXError: Int {
    case success = 0
    case attributeUnsupported = 2
}

let kAXRoleAttribute = "AXRole"
let kAXParentAttribute = "AXParent"
let kAXWindowAttribute = "AXWindow"
let kAXWindowRole = "AXWindow"

final class AXUIElement: Hashable {
    let id: String
    init(_ id: String) { self.id = id }
    static func == (lhs: AXUIElement, rhs: AXUIElement) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

final class Fixture {
    let systemWide = AXUIElement("system")
    var hit: AXUIElement?
    var hitError = AXError.success
    var attributes: [String: [String: AnyObject]] = [:]
    var errors: [String: [String: AXError]] = [:]
}

let fixture = Fixture()

func AXUIElementCreateSystemWide() -> AXUIElement { fixture.systemWide }
func AXUIElementGetTypeID() -> CFTypeID { 1 }
func CFGetTypeID(_ value: AnyObject) -> CFTypeID { value is AXUIElement ? AXUIElementGetTypeID() : 0 }
func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ timeout: Double) {}
func AXUIElementCopyElementAtPosition(_ system: AXUIElement, _ x: Float, _ y: Float,
                                      _ element: inout AXUIElement?) -> AXError {
    element = fixture.hit
    return fixture.hitError
}
func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ name: CFString,
                                   _ value: inout AnyObject?) -> AXError {
    if let attribute = fixture.attributes[element.id]?[name] {
        value = attribute
        return .success
    }
    return fixture.errors[element.id]?[name] ?? .attributeUnsupported
}

struct AXWindow {
    let element: AXUIElement
SWIFT
    awk '
        /^    static func hitTest\(/ { capture = 1 }
        /^    \/\/\/ The Accessibility element at a Quartz/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$root/Sources/Halfwin/Snapping/AXWindow.swift"
    awk '
        /^    static func role\(/ { capture = 1 }
        /^    static func subrole/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$root/Sources/Halfwin/Snapping/AXWindow.swift"
    awk '
        /^    private static func objectAttribute/ { capture = 1 }
        /^    private func setPointAttribute/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$root/Sources/Halfwin/Snapping/AXWindow.swift"
    cat <<'SWIFT'
}

func makeElement(_ id: String, role: String) -> AXUIElement {
    let element = AXUIElement(id)
    fixture.attributes[id, default: [:]][kAXRoleAttribute] = role as NSString
    return element
}

func reset(_ hit: AXUIElement, role: String = "AXGroup") {
    fixture.hit = hit
    fixture.hitError = .success
    fixture.attributes = [:]
    fixture.errors = [:]
    fixture.attributes[hit.id] = [kAXRoleAttribute: role as NSString]
}

func runHitTest() -> (element: AXUIElement, window: AXWindow)? {
    AXWindow.hitTest(at: CGPoint(x: 12, y: 34))
}

let direct = AXUIElement("direct")
reset(direct, role: kAXWindowRole)
let directResult = runHitTest()
assert(directResult?.element === direct && directResult?.window.element === direct)

let deepHit = AXUIElement("deep-hit")
reset(deepHit)
var previous = deepHit
for index in 1...12 {
    let group = makeElement("group-\(index)", role: "AXGroup")
    fixture.attributes[previous.id, default: [:]][kAXParentAttribute] = group
    previous = group
}
let deepOwner = makeElement("deep-owner", role: kAXWindowRole)
fixture.attributes[previous.id, default: [:]][kAXParentAttribute] = deepOwner
fixture.attributes[deepHit.id, default: [:]][kAXWindowAttribute] = deepOwner
let deepResult = runHitTest()
assert(deepResult?.element === deepHit && deepResult?.window.element === deepOwner)

let fallbackHit = AXUIElement("fallback-hit")
reset(fallbackHit)
let fallbackOwner = makeElement("fallback-owner", role: kAXWindowRole)
fixture.attributes[fallbackHit.id, default: [:]][kAXParentAttribute] = fallbackOwner
fixture.attributes[fallbackHit.id, default: [:]][kAXWindowAttribute] = "invalid value" as NSString
let fallbackResult = runHitTest()
assert(fallbackResult?.element === fallbackHit && fallbackResult?.window.element === fallbackOwner)

let unreachableHit = AXUIElement("unreachable-hit")
reset(unreachableHit)
previous = unreachableHit
for index in 1...12 {
    let group = makeElement("unreachable-group-\(index)", role: "AXGroup")
    fixture.attributes[previous.id, default: [:]][kAXParentAttribute] = group
    previous = group
}
let unreachableOwner = makeElement("unreachable-owner", role: kAXWindowRole)
fixture.attributes[previous.id, default: [:]][kAXParentAttribute] = unreachableOwner
let unreachableResult = runHitTest()
assert(unreachableResult?.window.element == nil)

print("AXWindow hit-test assertions passed")
SWIFT
} > "$scratch/main.swift"

swiftc "$scratch/main.swift" -o "$scratch/check-ax-window-hit-test"
"$scratch/check-ax-window-hit-test"
