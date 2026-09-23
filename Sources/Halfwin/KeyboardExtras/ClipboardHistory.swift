import AppKit

struct ClipboardEntry: Equatable {
    enum Content: Equatable {
        case text(String)
        case url(URL)
    }

    let content: Content

    var preview: String {
        switch content {
        case let .text(text):
            return text.replacingOccurrences(of: "\n", with: " ")
        case let .url(url):
            return url.absoluteString
        }
    }

    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch content {
        case let .text(text):
            pasteboard.setString(text, forType: .string)
        case let .url(url):
            pasteboard.writeObjects([url as NSURL])
        }
    }
}

final class ClipboardHistory {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var isPickerVisible = false
    private var selectedIndex = 0
    private var picker: ClipboardHistoryPicker?
    private var onChoose: ((ClipboardEntry) -> Void)?
    private var onCancel: (() -> Void)?

    func start() {
        capture(from: .general)
    }

    func stop() {
        cancelPicker(restoreApplication: false)
        entries.removeAll(keepingCapacity: false)
        selectedIndex = 0
        picker?.onChoose = nil
        picker?.update(entries: [], selectedIndex: 0)
    }

    func capture(from pasteboard: NSPasteboard) {
        let types = pasteboard.types ?? []
        let markers: Set<String> = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType"
        ]
        guard !types.contains(where: { markers.contains($0.rawValue) }) else { return }

        let urlType = NSPasteboard.PasteboardType("public.url")
        if types.contains(urlType) {
            if let value = pasteboard.string(forType: urlType), let url = URL(string: value) {
                insert(ClipboardEntry(content: .url(url)))
                return
            }
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL],
               let url = urls.first {
                insert(ClipboardEntry(content: .url(url as URL)))
                return
            }
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            insert(ClipboardEntry(content: .text(text)))
        }
    }

    func showPicker(at point: CGPoint, onChoose: @escaping (ClipboardEntry) -> Void,
                    onCancel: @escaping () -> Void) -> Bool {
        guard !entries.isEmpty else { return false }
        selectedIndex = 0
        self.onChoose = onChoose
        self.onCancel = onCancel
        isPickerVisible = true
        let picker = self.picker ?? ClipboardHistoryPicker()
        self.picker = picker
        picker.onChoose = { [weak self] index in
            guard let self, self.entries.indices.contains(index) else { return }
            self.selectedIndex = index
            self.chooseSelection()
        }
        picker.show(entries: entries, selectedIndex: selectedIndex, at: point)
        return true
    }

    func moveSelection(_ offset: Int) {
        guard isPickerVisible, !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + entries.count) % entries.count
        picker?.update(entries: entries, selectedIndex: selectedIndex)
    }

    func chooseSelection() {
        guard isPickerVisible, entries.indices.contains(selectedIndex) else { return }
        let entry = entries[selectedIndex]
        let action = onChoose
        dismissPicker()
        action?(entry)
    }

    func cancelPicker(restoreApplication: Bool = true) {
        guard isPickerVisible else { return }
        let action = onCancel
        dismissPicker()
        if restoreApplication { action?() }
    }

    private func insert(_ entry: ClipboardEntry) {
        let selectedEntry = isPickerVisible && entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil
        guard entries.first != entry else { return }
        entries.insert(entry, at: 0)
        if entries.count > 20 { entries.removeLast(entries.count - 20) }
        guard isPickerVisible else { return }
        if let selectedEntry, let index = entries.firstIndex(of: selectedEntry) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, max(0, entries.count - 1))
        }
        picker?.update(entries: entries, selectedIndex: selectedIndex)
    }

    private func dismissPicker() {
        picker?.orderOut(nil)
        isPickerVisible = false
        onChoose = nil
        onCancel = nil
    }
}

private final class ClipboardHistoryPicker: NSPanel {
    private let scrollView = NSScrollView()
    private let rowsView = ClipboardRowsView()
    private var entries: [ClipboardEntry] = []
    private var rowButtons: [NSButton] = []
    var onChoose: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        let size = NSSize(width: 360, height: 356)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        contentView = root
        let heading = NSTextField(labelWithString: "Clipboard History")
        heading.font = .boldSystemFont(ofSize: 13)
        heading.frame = NSRect(x: 14, y: 326, width: 332, height: 20)
        root.addSubview(heading)

        scrollView.frame = NSRect(x: 12, y: 12, width: 336, height: 306)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        rowsView.frame = NSRect(x: 0, y: 0, width: 336, height: 1)
        scrollView.documentView = rowsView
        root.addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(entries: [ClipboardEntry], selectedIndex: Int, at point: CGPoint) {
        update(entries: entries, selectedIndex: selectedIndex)
        let visible = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let x = min(max(point.x, visible.minX), visible.maxX - frame.width)
        let y = min(max(point.y, visible.minY), visible.maxY - frame.height)
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
    }

    func update(entries: [ClipboardEntry], selectedIndex: Int) {
        let contentChanged = self.entries != entries || rowButtons.count != entries.count
        let previousScrollOrigin = scrollView.contentView.bounds.origin
        self.entries = entries
        if contentChanged {
            for view in rowsView.subviews { view.removeFromSuperview() }
            rowButtons.removeAll(keepingCapacity: true)
            let rowHeight: CGFloat = 30
            rowsView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width,
                                    height: max(scrollView.contentSize.height, rowHeight * CGFloat(entries.count)))
            for (index, entry) in entries.enumerated() {
                let button = NSButton(title: entry.preview, target: self, action: #selector(chooseRow(_:)))
                button.tag = index
                button.frame = NSRect(x: 0, y: rowHeight * CGFloat(index),
                                      width: rowsView.frame.width, height: rowHeight)
                button.alignment = .left
                button.setButtonType(.momentaryPushIn)
                button.isBordered = false
                button.cell?.lineBreakMode = .byTruncatingTail
                rowsView.addSubview(button)
                rowButtons.append(button)
            }
            scrollView.documentView = rowsView
            scrollView.contentView.scroll(to: previousScrollOrigin)
        }
        for (index, button) in rowButtons.enumerated() {
            button.contentTintColor = index == selectedIndex ? .controlAccentColor : .labelColor
        }
        if rowButtons.indices.contains(selectedIndex),
           !rowsView.visibleRect.contains(rowButtons[selectedIndex].frame) {
            rowsView.scrollToVisible(rowButtons[selectedIndex].frame)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func chooseRow(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        onChoose?(sender.tag)
    }
}

private final class ClipboardRowsView: NSView {
    override var isFlipped: Bool { true }
}
