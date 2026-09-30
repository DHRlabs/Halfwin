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
    case noValue = 1
    case attributeUnsupported = 2
    case failure = 3
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
        /^    private static func roleResult/ { capture = 1 }
        /^    static func subrole/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$root/Sources/Halfwin/Snapping/AXWindow.swift"
    awk '
        /^    private static func attributeValue/ { capture = 1 }
        capture {
            sub(/^    /, "")
            print
            opens = gsub(/\{/, "{")
            closes = gsub(/\}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$root/Sources/Halfwin/Snapping/AXWindow.swift"
    cat <<'SWIFT'
}

func makeElement(_ id: String, role: String) -> AXUIElement {
    let element = AXUIElement(id)
    fixture.attributes[id, default: [:]][kAXRoleAttribute] = role as NSString
    return element
}

func reset(_ hit: AXUIElement) {
    fixture.hit = hit
    fixture.hitError = .success
    fixture.attributes = [:]
    fixture.errors = [:]
    fixture.attributes[hit.id] = [kAXRoleAttribute: "AXGroup" as NSString]
}

func runHitTest() -> ((element: AXUIElement, window: AXWindow)?, String?) {
    var trace: String?
    let result = AXWindow.hitTest(at: CGPoint(x: 12, y: 34)) { trace = $0 }
    return (result, trace)
}

let direct = makeElement("direct", role: kAXWindowRole)
reset(direct)
fixture.attributes[direct.id]?[kAXRoleAttribute] = kAXWindowRole as NSString
let directResult = runHitTest()
assert(directResult.0?.element === direct && directResult.0?.window.element === direct)
assert(directResult.1?.contains("stop=hitWindow") == true)

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
fixture.errors[deepHit.id, default: [:]][kAXWindowAttribute] = .attributeUnsupported
let oldPathResult = runHitTest()
assert(oldPathResult.0 == nil && oldPathResult.1?.contains("parentReads=8") == true)
assert(oldPathResult.1?.contains("stop=depthLimit") == true)

fixture.attributes[deepHit.id, default: [:]][kAXWindowAttribute] = deepOwner
let deepResult = runHitTest()
assert(deepResult.0?.element === deepHit && deepResult.0?.window.element === deepOwner)
assert(deepResult.1?.contains("stop=windowAttribute") == true)
assert(deepResult.1?.contains("windowRole=AXWindow/e0") == true)

let fallbackHit = makeElement("fallback-hit", role: "AXGroup")
reset(fallbackHit)
let fallbackOwner = makeElement("fallback-owner", role: kAXWindowRole)
fixture.attributes[fallbackHit.id, default: [:]][kAXParentAttribute] = fallbackOwner
fixture.errors[fallbackHit.id, default: [:]][kAXWindowAttribute] = .attributeUnsupported
let fallbackResult = runHitTest()
assert(fallbackResult.0?.element === fallbackHit && fallbackResult.0?.window.element === fallbackOwner)
assert(fallbackResult.1?.contains("stop=windowAncestor") == true)
assert(fallbackResult.1?.contains("windowAttributeError=2") == true)

print("AXWindow hit-test assertions passed")
SWIFT
} > "$scratch/main.swift"

swiftc "$scratch/main.swift" -o "$scratch/check-ax-window-hit-test"
"$scratch/check-ax-window-hit-test"
