import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: SnapSettings
    @ObservedObject var layoutMenuSettings: LayoutMenuSettings
    @ObservedObject var dockPreviewSettings: DockPreviewSettings

    var body: some View {
        Form {
            Section("Snapping") {
                Toggle("Snap windows when dragged to an edge", isOn: $settings.dragSnappingEnabled)
                ForEach(SnapPosition.allCases, id: \.self) { position in
                    Picker(position.displayName, selection: binding(for: position)) {
                        ForEach(SnapAction.allCases.filter { $0 != .lastThirdTop && $0 != .lastThirdBottom }, id: \.self) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                }
                Button("Restore Lance's Defaults") {
                    settings.restoreLanceDefaults()
                }
            }
            Section("Layout menu") {
                Toggle("Show a layout menu when hovering the top of a display", isOn: $layoutMenuSettings.enabled)
                Stepper(value: $layoutMenuSettings.dwellDelay, in: 0.1...1.5, step: 0.05) {
                    Text("Dwell delay: \(layoutMenuSettings.dwellDelay, specifier: "%.2f")s")
                }
                Stepper(value: $layoutMenuSettings.hotZoneWidth, in: 200...1200, step: 50) {
                    Text("Top hot zone width: \(Int(layoutMenuSettings.hotZoneWidth)) pt")
                }
                Stepper(value: $layoutMenuSettings.commandCenterSideFraction, in: 0.15...0.35, step: 0.01) {
                    Text("Command Center side width: \(Int((layoutMenuSettings.commandCenterSideFraction * 100).rounded()))%")
                }
            }
            Section("Dock previews") {
                Stepper(value: $dockPreviewSettings.hoverDelay, in: 0.0...0.5, step: 0.05) {
                    Text("Hover delay: \(dockPreviewSettings.hoverDelay, specifier: "%.2f")s")
                }
                Stepper(value: $dockPreviewSettings.previewSize, in: 1.0...3.0, step: 0.25) {
                    Text("Preview size: \(Int(dockPreviewSettings.previewSize * 100))%")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 570)
    }

    private func binding(for position: SnapPosition) -> Binding<SnapAction> {
        Binding(
            get: { settings.action(for: position) },
            set: { settings.map[position] = $0 }
        )
    }
}

/// Hosts `SettingsView` in a plain `NSWindow`, opened from the menu (Cmd-,).
final class SettingsWindowController: NSWindowController {
    convenience init(settings: SnapSettings, layoutMenuSettings: LayoutMenuSettings, dockPreviewSettings: DockPreviewSettings) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 570),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Halfwin Settings"
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                layoutMenuSettings: layoutMenuSettings,
                dockPreviewSettings: dockPreviewSettings
            )
        )
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
