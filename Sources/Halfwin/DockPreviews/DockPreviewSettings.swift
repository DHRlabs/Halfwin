import Combine
import SwiftUI

final class DockPreviewSettings: ObservableObject {
    static let shared = DockPreviewSettings()

    private let defaults = UserDefaults.standard
    private let hoverDelayKey = "Halfwin.dockPreviewHoverDelay"
    private let previewSizeKey = "Halfwin.dockPreviewSize"
    private let peekOnHoverKey = "Halfwin.dockPreviewPeekOnHover"

    static let defaultHoverDelay = 0.0
    static let defaultPreviewSize = 1.0
    static let defaultPeekOnHover = true

    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: hoverDelayKey) }
    }

    @Published var previewSize: Double {
        didSet { defaults.set(previewSize, forKey: previewSizeKey) }
    }

    @Published var peekOnHover: Bool {
        didSet { defaults.set(peekOnHover, forKey: peekOnHoverKey) }
    }

    private init() {
        let savedDelay = defaults.object(forKey: hoverDelayKey) as? Double ?? Self.defaultHoverDelay
        let savedSize = defaults.object(forKey: previewSizeKey) as? Double ?? Self.defaultPreviewSize
        let savedPeekOnHover = defaults.object(forKey: peekOnHoverKey) as? Bool ?? Self.defaultPeekOnHover
        hoverDelay = min(max(savedDelay, 0), 0.5)
        previewSize = min(max(savedSize, 1), 3)
        peekOnHover = savedPeekOnHover
    }
}
