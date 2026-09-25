import AppKit
import SwiftUI

@MainActor
final class DockWindowPeek {
    private let panel: NSPanel
    private let state = DockWindowPeekState()

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
        // isFloatingPanel resets level, so set it before level.
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DockWindowPeekView(state: state))
    }

    func show(frame: CGRect, on screen: CGRect, image: CGImage?, minimized: Bool) {
        state.screenFrame = screen
        state.windowFrame = frame
        state.image = image.map { NSImage(cgImage: $0, size: .zero) }
        state.minimized = minimized
        panel.setFrame(screen, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        state.image = nil
        state.minimized = false
    }

    func setImage(_ image: CGImage) {
        state.image = NSImage(cgImage: image, size: .zero)
    }
}

@MainActor
private final class DockWindowPeekState: ObservableObject {
    @Published var screenFrame = CGRect.zero
    @Published var windowFrame = CGRect.zero
    @Published var image: NSImage?
    @Published var minimized = false
}

@MainActor
private struct DockWindowPeekView: View {
    @ObservedObject var state: DockWindowPeekState

    private var imageOrigin: CGPoint {
        CGPoint(
            x: state.windowFrame.minX - state.screenFrame.minX,
            y: state.screenFrame.maxY - state.windowFrame.maxY
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.4)
            if let image = state.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: state.windowFrame.width, height: state.windowFrame.height)
                    .clipped()
                    .offset(x: imageOrigin.x, y: imageOrigin.y)
            }
            if state.minimized {
                Label("Minimized", systemImage: "minus.rectangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.8), in: Capsule())
                    .offset(x: imageOrigin.x + 8, y: imageOrigin.y + 8)
            }
        }
        .frame(width: state.screenFrame.width, height: state.screenFrame.height, alignment: .topLeading)
        .clipped()
    }
}
