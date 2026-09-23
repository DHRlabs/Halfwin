import AppKit
import SwiftUI

enum DockPreviewEdge: Equatable {
    case bottom
    case left
    case right
}

struct DockPreviewItem: Identifiable {
    let id: Int
    let title: String
    let appIcon: NSImage
    let minimized: Bool
}

@MainActor
final class DockPreviewPanel {
    var onSelect: ((Int) -> Void)?
    var frame: CGRect { panel.frame }

    private let panel: NSPanel
    private let state = DockPreviewPanelState()

    init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DockPreviewTilesView(state: state) { [weak self] id in
            self?.onSelect?(id)
        })
    }

    /// `dockFrame`, `itemFrame`, and `screenFrame` use AppKit's global screen coordinates.
    func show(items: [DockPreviewItem], edge: DockPreviewEdge, dockFrame: CGRect, itemFrame: CGRect, screenFrame: CGRect) {
        guard !items.isEmpty else {
            hide()
            return
        }

        state.items = items
        state.images.removeAll(keepingCapacity: true)
        state.edge = edge

        let horizontalDock = edge == .bottom
        let size = panelSize(for: items.count, horizontalDock: horizontalDock, screenFrame: screenFrame)
        state.viewportSize = CGSize(width: max(0, size.width - 16), height: max(0, size.height - 16))

        var origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: itemFrame.midX - size.width / 2, y: dockFrame.maxY + 8)
        case .left:
            origin = CGPoint(x: dockFrame.maxX + 8, y: itemFrame.midY - size.height / 2)
        case .right:
            origin = CGPoint(x: dockFrame.minX - size.width - 8, y: itemFrame.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - size.width)
        origin.y = min(max(origin.y, screenFrame.minY), screenFrame.maxY - size.height)

        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func setImage(_ image: NSImage, for id: Int) {
        guard state.items.contains(where: { $0.id == id }) else { return }
        state.images[id] = image
    }

    func hide() {
        panel.orderOut(nil)
        state.items.removeAll(keepingCapacity: true)
        state.images.removeAll(keepingCapacity: true)
    }

    private func panelSize(for count: Int, horizontalDock: Bool, screenFrame: CGRect) -> CGSize {
        if horizontalDock {
            return CGSize(
                width: min(screenFrame.width, min(640, CGFloat(count) * 186 + 16)),
                height: min(screenFrame.height, 160)
            )
        }
        return CGSize(
            width: min(screenFrame.width, 244),
            height: min(screenFrame.height, min(600, CGFloat(count) * 136 + 16))
        )
    }
}

@MainActor
private final class DockPreviewPanelState: ObservableObject {
    @Published var items: [DockPreviewItem] = []
    @Published var images: [Int: NSImage] = [:]
    @Published var edge: DockPreviewEdge = .bottom
    @Published var viewportSize = CGSize.zero
}

@MainActor
private struct DockPreviewTilesView: View {
    @ObservedObject var state: DockPreviewPanelState
    let onSelect: (Int) -> Void

    private var horizontalDock: Bool {
        state.edge == .bottom
    }

    var body: some View {
        Group {
            if horizontalDock {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(state.items) { item in
                            tile(item).frame(width: 176, height: 132)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        ForEach(state.items) { item in
                            tile(item).frame(width: 220, height: 126)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(8)
        .frame(width: state.viewportSize.width, height: state.viewportSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func tile(_ item: DockPreviewItem) -> some View {
        Button { onSelect(item.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                    if let image = state.images[item.id] {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        Image(nsImage: item.appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 42, height: 42)
                    }
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 5) {
                    Text(item.title.isEmpty ? "Window" : item.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.minimized {
                        Text("Minimized")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
            }
            .padding(7)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title.isEmpty ? "Window" : item.title)
    }
}
