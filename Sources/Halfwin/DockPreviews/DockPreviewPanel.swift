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

    /// `dockFrame`, `itemFrame`, and `visibleFrame` use AppKit's global screen coordinates.
    func show(
        items: [DockPreviewItem],
        edge: DockPreviewEdge,
        dockFrame: CGRect,
        itemFrame: CGRect,
        visibleFrame: CGRect,
        previewScale: CGFloat = 1,
        preservingImages: Bool = false
    ) {
        guard !items.isEmpty else {
            hide()
            return
        }

        let existingImages = state.images
        state.items = items
        let itemIDs = Set(items.map(\.id))
        state.images = preservingImages ? existingImages.filter { itemIDs.contains($0.key) } : [:]
        state.edge = edge

        let horizontalDock = edge == .bottom
        let layout = panelLayout(
            for: items.count,
            horizontalDock: horizontalDock,
            visibleFrame: visibleFrame,
            previewScale: previewScale
        )
        state.panelSize = layout.panelSize
        state.tileSize = layout.tileSize
        state.spacing = layout.spacing

        var origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: itemFrame.midX - layout.panelSize.width / 2, y: dockFrame.maxY + 8)
        case .left:
            origin = CGPoint(x: dockFrame.maxX + 8, y: itemFrame.midY - layout.panelSize.height / 2)
        case .right:
            origin = CGPoint(x: dockFrame.minX - layout.panelSize.width - 8, y: itemFrame.midY - layout.panelSize.height / 2)
        }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - layout.panelSize.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - layout.panelSize.height)

        panel.setFrame(CGRect(origin: origin, size: layout.panelSize), display: true)
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

    private func panelLayout(
        for count: Int,
        horizontalDock: Bool,
        visibleFrame: CGRect,
        previewScale: CGFloat
    ) -> (panelSize: CGSize, tileSize: CGSize, spacing: CGFloat) {
        let baseTileSize = horizontalDock ? CGSize(width: 176, height: 132) : CGSize(width: 220, height: 126)
        let requestedScale = min(max(previewScale, 1), 3)
        let idealTileSize = CGSize(width: baseTileSize.width * requestedScale, height: baseTileSize.height * requestedScale)
        let idealSpacing: CGFloat = 10 * requestedScale
        let tileCount = CGFloat(count)
        let contentSize = horizontalDock
            ? CGSize(width: tileCount * idealTileSize.width + (tileCount - 1) * idealSpacing, height: idealTileSize.height)
            : CGSize(width: idealTileSize.width, height: tileCount * idealTileSize.height + (tileCount - 1) * idealSpacing)
        let panelSize = CGSize(
            width: min(visibleFrame.width, contentSize.width + 16),
            height: min(visibleFrame.height, contentSize.height + 16)
        )
        let contentWidth = max(0, panelSize.width - 16)
        let contentHeight = max(0, panelSize.height - 16)
        let fitScale = min(1, min(contentWidth / contentSize.width, contentHeight / contentSize.height))
        return (
            panelSize,
            CGSize(width: idealTileSize.width * fitScale, height: idealTileSize.height * fitScale),
            idealSpacing * fitScale
        )
    }
}

@MainActor
private final class DockPreviewPanelState: ObservableObject {
    @Published var items: [DockPreviewItem] = []
    @Published var images: [Int: NSImage] = [:]
    @Published var edge: DockPreviewEdge = .bottom
    @Published var panelSize = CGSize.zero
    @Published var tileSize = CGSize.zero
    @Published var spacing: CGFloat = 10
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
                HStack(spacing: state.spacing) {
                    ForEach(state.items) { item in
                        tile(item).frame(width: state.tileSize.width, height: state.tileSize.height)
                    }
                }
            } else {
                VStack(spacing: state.spacing) {
                    ForEach(state.items) { item in
                        tile(item).frame(width: state.tileSize.width, height: state.tileSize.height)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: state.panelSize.width, height: state.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func tile(_ item: DockPreviewItem) -> some View {
        let baseWidth: CGFloat = horizontalDock ? 176 : 220
        let tileScale = state.tileSize.width / baseWidth
        let inset = min(7 * tileScale, min(state.tileSize.width, state.tileSize.height) * 0.05)
        let rowSpacing = min(6 * tileScale, state.tileSize.height * 0.05)
        let titleSize = min(12 * tileScale, state.tileSize.height * 0.095)
        let imageHeight = min(92 * tileScale, max(0, state.tileSize.height - inset * 2 - rowSpacing - titleSize * 1.2))
        let iconSize = min(42 * tileScale, min(state.tileSize.width, state.tileSize.height) * 0.45)
        return Button { onSelect(item.id) } label: {
            VStack(alignment: .leading, spacing: rowSpacing) {
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
                            .frame(width: iconSize, height: iconSize)
                    }
                }
                .frame(height: imageHeight)
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
                .font(.system(size: titleSize))
            }
            .padding(inset)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title.isEmpty ? "Window" : item.title)
    }
}
