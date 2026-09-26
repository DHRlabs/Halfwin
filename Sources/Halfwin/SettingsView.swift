import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: SnapSettings
    @ObservedObject var snapAssistSettings: SnapAssistSettings
    @ObservedObject var layoutMenuSettings: LayoutMenuSettings
    @ObservedObject var dockPreviewSettings: DockPreviewSettings
    @ObservedObject var autoTileSettings: AutoTileSettings
    @ObservedObject var notificationCount: NotificationCountManager
    @ObservedObject var macTweaks: MacTweaks
    @AppStorage(ShowDesktopStyle.defaultsKey) private var showDesktopStyle: ShowDesktopStyle = .pushWindowsAside
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
            Section("Snap Assist") {
                Picker("Fill empty spots", selection: $snapAssistSettings.fillEmptySpots) {
                    ForEach(SnapAssistFillMode.allCases) { mode in Text(mode.title).tag(mode) }
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
                Stepper(value: $layoutMenuSettings.sizePercent, in: 75...200, step: 25) {
                    Text("Layout menu size: \(Int(layoutMenuSettings.sizePercent))%")
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
            Section("Notifications") {
                Text("1. Leave Do Not Disturb on with no allowed apps to keep banners quiet.")
                Button("Open Focus Settings") { openSystemSettings("com.apple.Focus-Settings.extension") }
                Text("2. Turn off Desktop banners per app and choose By Application grouping.")
                Button("Open Notifications Settings") { openSystemSettings("com.apple.Notifications-Settings.extension") }
                if !notificationCount.hasAccessibility {
                    Text("Accessibility access is required to read Dock badge counts.")
                    Button("Open Accessibility Settings", action: Permissions.requestAccessibility)
                } else if !notificationCount.isEnabled {
                    Text("Turn on Notification count in Halfwin's menu to list Dock badges.")
                } else {
                    Text("Current waiting count: \(notificationCount.total)")
                    if notificationCount.apps.isEmpty {
                        Text("No app Dock badges are visible right now.").foregroundStyle(.secondary)
                    }
                    ForEach(notificationCount.apps) { app in
                        Toggle(isOn: Binding(
                            get: { notificationCount.isIncluded(app.id) },
                            set: { notificationCount.setIncluded($0, for: app.id) }
                        )) {
                            HStack {
                                Text(app.name)
                                Spacer()
                                Text("\(app.count)").foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Section("Show desktop") {
                Picker("Show desktop style", selection: $showDesktopStyle) {
                    ForEach(ShowDesktopStyle.allCases) { style in Text(style.title).tag(style) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 740)
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

    private func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}

/// Hosts `SettingsView` in a plain `NSWindow`, opened from the menu (Cmd-,).
final class SettingsWindowController: NSWindowController {
    convenience init(settings: SnapSettings, snapAssistSettings: SnapAssistSettings,
                     layoutMenuSettings: LayoutMenuSettings,
                     dockPreviewSettings: DockPreviewSettings, autoTileSettings: AutoTileSettings,
                     notificationCount: NotificationCountManager, macTweaks: MacTweaks) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 740),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Halfwin Settings"
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                snapAssistSettings: snapAssistSettings,
                layoutMenuSettings: layoutMenuSettings,
                dockPreviewSettings: dockPreviewSettings,
                autoTileSettings: autoTileSettings,
                notificationCount: notificationCount,
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
