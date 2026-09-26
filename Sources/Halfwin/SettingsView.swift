import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: SnapSettings
    @ObservedObject var layoutMenuSettings: LayoutMenuSettings
    @ObservedObject var dockPreviewSettings: DockPreviewSettings
    @ObservedObject var autoTileSettings: AutoTileSettings
    @ObservedObject var macTweaks: MacTweaks
    @State private var alwaysFloatAppIDsText: String?
    @FocusState private var alwaysFloatAppIDsFocused: Bool

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
            Section("Mac tweaks") {
                ForEach(MacTweakGroup.allCases) { group in
                    GroupBox(group.rawValue) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(MacTweak.all.filter { $0.group == group }) { tweak in
                                Toggle(tweak.title, isOn: Binding(
                                    get: { macTweaks.isEnabled(tweak.id) },
                                    set: { macTweaks.setEnabled($0, for: tweak.id) }
                                ))
                            }
                            if group == .animations {
                                Text("Apps pick up these changes when they reopen.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if group == .finder, macTweaks.finderAutomationDenied,
                                      macTweaks.isEnabled(.listView) {
                                Text("Automation access was denied; existing Finder folders may keep their saved views.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if group == .desktop {
                                Button("Reduce Motion…", action: macTweaks.openReduceMotionSettings)
                                Text("macOS only lets you change Reduce Motion in System Settings.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .onAppear { macTweaks.retryFinderAutomation() }
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
            Section("Auto-tile") {
                Picker("Layout", selection: $autoTileSettings.layout) {
                    ForEach(AutoTileLayout.allCases) { layout in Text(layout.rawValue).tag(layout) }
                }
                Stepper(value: $autoTileSettings.columnWidth, in: 0.35...1.0, step: 0.05) {
                    Text("Column width: \(Int((autoTileSettings.columnWidth * 100).rounded()))%")
                }
                Stepper(value: $autoTileSettings.gap, in: 0...24, step: 1) {
                    Text("Gap: \(Int(autoTileSettings.gap)) pt")
                }
                Picker("Keyboard modifier", selection: $autoTileSettings.modifier) {
                    ForEach(AutoTileModifier.allCases) { modifier in Text(modifier.rawValue).tag(modifier) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Always-float app bundle IDs")
                    TextEditor(text: Binding(
                        get: { alwaysFloatAppIDsText ?? autoTileSettings.alwaysFloatAppIDs.joined(separator: "\n") },
                        set: { alwaysFloatAppIDsText = $0 }
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 76)
                    .focused($alwaysFloatAppIDsFocused)
                    .onChange(of: alwaysFloatAppIDsFocused) { _, focused in
                        if !focused { saveAlwaysFloatAppIDs() }
                    }
                    Button("Save IDs", action: saveAlwaysFloatAppIDs)
                }
            }
            Section("Dock previews") {
                Toggle("Peek at windows on hover", isOn: $dockPreviewSettings.peekOnHover)
                Stepper(value: $dockPreviewSettings.hoverDelay, in: 0.0...0.5, step: 0.05) {
                    Text("Hover delay: \(dockPreviewSettings.hoverDelay, specifier: "%.2f")s")
                }
                Stepper(value: $dockPreviewSettings.previewSize, in: 1.0...3.0, step: 0.25) {
                    Text("Preview size: \(Int(dockPreviewSettings.previewSize * 100))%")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 690)
    }

    private func binding(for position: SnapPosition) -> Binding<SnapAction> {
        Binding(
            get: { settings.action(for: position) },
            set: { settings.map[position] = $0 }
        )
    }

    private func saveAlwaysFloatAppIDs() {
        let text = alwaysFloatAppIDsText ?? autoTileSettings.alwaysFloatAppIDs.joined(separator: "\n")
        autoTileSettings.alwaysFloatAppIDs = text.components(separatedBy: .newlines)
        alwaysFloatAppIDsText = autoTileSettings.alwaysFloatAppIDs.joined(separator: "\n")
    }
}

/// Hosts `SettingsView` in a plain `NSWindow`, opened from the menu (Cmd-,).
final class SettingsWindowController: NSWindowController {
    convenience init(settings: SnapSettings, layoutMenuSettings: LayoutMenuSettings,
                     dockPreviewSettings: DockPreviewSettings, autoTileSettings: AutoTileSettings,
                     macTweaks: MacTweaks) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 690),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Halfwin Settings"
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                layoutMenuSettings: layoutMenuSettings,
                dockPreviewSettings: dockPreviewSettings,
                autoTileSettings: autoTileSettings,
                macTweaks: macTweaks
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
