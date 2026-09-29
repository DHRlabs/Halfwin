#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/Sources/Halfwin/DockPreviews/DockPreviewManager.swift"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

{
    cat <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct DockPreviewItem: Identifiable {
    let id: Int
    let title: String
}

struct AXWindow {
    let element: AXUIElement
}

@MainActor
final class CloseFixtureManager {
    private let processID: pid_t
    private let app: NSRunningApplication
    private var observedWindowElements: [Int: AXUIElement] = [:]
    private var minimizeObserver: AXObserver?
    private var minimizeObserverPID: pid_t?
    private var previewCache: [pid_t: CachedPreview] = [:]
    private var windows: [Int: AXWindow] = [:]
    private var closeButtons: [Int: AXUIElement]
    private var activeApp: NSRunningApplication?
    private var isShowing = true
    private var captureTask: Task<Void, Never>?
    private var generation = 1
    private var presentedIDs: [Int] = []
    private var closeButtonPresses: [Int] = []
    private var notificationRequests: [String] = []
    private var refreshed = 0
    private var peekClears = 0

SWIFT
    awk '
        /^    private struct CachedPreview \{/ { capture = 1; depth = 0 }
        capture {
            line = $0
            sub(/^    /, "", line)
            temporary = line
            opens = gsub(/\{/, "", temporary)
            closes = gsub(/\}/, "", temporary)
            print line
            depth += opens - closes
            if (depth == 0) capture = 0
        }
    ' "$source"
    cat <<'SWIFT'

    init(app: NSRunningApplication, observer: AXObserver?, closeButtons: [Int: AXUIElement]) {
        self.app = app
        self.processID = app.processIdentifier
        self.minimizeObserver = observer
        self.minimizeObserverPID = app.processIdentifier
        self.closeButtons = closeButtons
        self.activeApp = app
    }

    func installPreview(items: [DockPreviewItem], windows: [Int: AXWindow]) {
        previewCache[processID] = CachedPreview(
            items: items,
            windows: windows,
            screenshotIDs: Dictionary(uniqueKeysWithValues: windows.keys.map { ($0, CGWindowID($0)) })
        )
        self.windows = windows
        presentedIDs = items.map(\.id)
    }

    func trackFixtureWindow(_ window: AXWindow) {
        guard let minimizeObserver else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for window in [window] {
SWIFT
    awk '
        /^    private func observeWindowMinimization/ { inObserver = 1 }
        inObserver && /let id = Int\(truncatingIfNeeded: CFHash\(window.element\)\)/ { capture = 1 }
        capture {
            line = $0
            sub(/^            /, "", line)
            print line
            if (line ~ /observedWindowElements\[id\] = window\.element/) exit
        }
        /^    private func stopWindowMinimizationObserver/ { inObserver = 0 }
    ' "$source"
    cat <<'SWIFT'
        }
    }

SWIFT
    awk '
        /^    func windowElementDestroyed/ { capture = 1 }
        /^    func dockElementDestroyed/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$source"
    awk '
        /^    private func closeWindow/ { capture = 1; sub(/private func closeWindow/, "func requestFixtureClose") }
        /^    private func selectWindow/ { capture = 0 }
        capture { sub(/^    /, ""); print }
    ' "$source"
    cat <<'SWIFT'

    func AXObserverAddNotification(
        _ observer: AXObserver,
        _ element: AXUIElement,
        _ notification: CFString,
        _ refcon: UnsafeMutableRawPointer?
    ) -> AXError {
        notificationRequests.append(notification as String)
        if notification as String == kAXWindowMiniaturizedNotification as String { return .notificationUnsupported }
        if notification as String == kAXUIElementDestroyedNotification as String { return .success }
        return .failure
    }

    @discardableResult
    func AXObserverRemoveNotification(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString) -> AXError {
        .success
    }

    @discardableResult
    func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError { .success }

    func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError {
        guard action as String == kAXPressAction as String else { return .failure }
        closeButtonPresses.append(Int(truncatingIfNeeded: CFHash(element)))
        return .success
    }

    func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        guard name == kAXCloseButtonAttribute as String,
              let button = closeButtons[Int(truncatingIfNeeded: CFHash(element))] else { return nil }
        return button as? T
    }

    func clearPeek() { peekClears += 1 }

    private func hidePreview() { isShowing = false; presentedIDs = [] }

    private func present(_ preview: CachedPreview, preservingImages: Bool) {
        presentedIDs = preview.items.map(\.id)
    }

    private func captureThumbnails(_ screenshotIDs: [Int: CGWindowID], generation: Int) {}

    private func refreshPreviewCacheLater(for app: NSRunningApplication) { refreshed += 1 }

    func result() -> (cached: [Int], visible: [Int], pressed: [Int], refreshed: Int, peekClears: Int) {
        let cached = previewCache[processID]!
        return (cached.items.map(\.id), presentedIDs, closeButtonPresses, refreshed, peekClears)
    }

    func trackedIDs() -> Set<Int> { Set(observedWindowElements.keys) }
    func requestedNotifications() -> [String] { notificationRequests }
}

@MainActor
@main
struct DockPreviewCloseCheck {
    static func main() {
        let apps = NSWorkspace.shared.runningApplications
        precondition(apps.count >= 2, "Two running applications are required for fixtures")
        let app = apps[0]
        let otherApp = apps.first { $0.processIdentifier != app.processIdentifier }!
        let firstElement = AXUIElementCreateApplication(app.processIdentifier)
        let secondElement = AXUIElementCreateApplication(otherApp.processIdentifier)
        let firstID = Int(truncatingIfNeeded: CFHash(firstElement))
        let secondID = Int(truncatingIfNeeded: CFHash(secondElement))
        precondition(firstID != secondID, "Fixture elements must have distinct IDs")

        let callback: AXObserverCallback = { _, _, _, _ in }
        var observer: AXObserver?
        precondition(AXObserverCreate(app.processIdentifier, callback, &observer) == .success)
        let manager = CloseFixtureManager(
            app: app,
            observer: observer,
            closeButtons: [firstID: firstElement, secondID: secondElement]
        )
        manager.installPreview(
            items: [DockPreviewItem(id: firstID, title: "A"), DockPreviewItem(id: secondID, title: "B")],
            windows: [firstID: AXWindow(element: firstElement), secondID: AXWindow(element: secondElement)]
        )

        manager.requestFixtureClose(secondID)
        let afterClose = manager.result()
        assert(afterClose.pressed == [secondID])
        assert(afterClose.cached == [firstID, secondID])
        assert(afterClose.visible == [firstID, secondID])
        assert(afterClose.refreshed == 1 && afterClose.peekClears == 1)

        manager.trackFixtureWindow(AXWindow(element: secondElement))
        assert(manager.requestedNotifications() == [
            kAXWindowMiniaturizedNotification as String,
            kAXUIElementDestroyedNotification as String
        ])
        assert(manager.trackedIDs() == [secondID], "Destroy subscription must track a window when mini is unsupported")

        manager.windowElementDestroyed(secondElement)
        let afterDestroy = manager.result()
        assert(afterDestroy.cached == [firstID])
        assert(afterDestroy.visible == [firstID])
        assert(afterDestroy.refreshed == 2)
        assert(manager.trackedIDs().isEmpty)

        print("Dock preview close assertions passed")
    }
}
SWIFT
} > "$scratch/main.swift"

swiftc -parse-as-library "$scratch/main.swift" -o "$scratch/check-dock-preview-close"
"$scratch/check-dock-preview-close"
