import AppKit
import ApplicationServices
import CoreGraphics

final class KeyboardExtras {
    private let clipboardSwitch = FeatureSwitch(key: "clipboardHistory", title: "Clipboard history", defaultOn: true)
    private let cutPasteSwitch = FeatureSwitch(key: "finderCutPaste", title: "Cut and paste files", defaultOn: true)
    private let finderEnterSwitch = FeatureSwitch(key: "finderEnter", title: "Enter opens files", defaultOn: true)
    private let lastWindowSwitch = FeatureSwitch(key: "quitLastWindow", title: "Close last window quits app", defaultOn: true)
    private let clipboardHistory = ClipboardHistory()

    private var clipboardEnabled = false
    private var cutPasteEnabled = false
    private var finderEnterEnabled = false
    private var lastWindowEnabled = false
    private var permissionTimer: Timer?
    private var pasteboardTimer: Timer?
    private var observedPasteboardChangeCount: Int?
    private var suppressedHistoryChangeCount: Int?
    private var clipboardRunning = false
    private var cutState: CutState?
    private var pendingFinderPasteID: UUID?
    private var pastePress: PastePress?
    private var pendingExtraPasteKeyUps = 0
    private var queuedPasteTargets: [NSRunningApplication?] = []
    private var swallowedKeyUps = Set<CGKeyCode>()
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?

    private struct CutState {
        let expectedURLs: Set<URL>
        let changeCountAtCut: Int
        let startedAt: TimeInterval
        var awaitingFileCopy = true
    }

    private struct PastePress {
        let id: UUID
        let startedAt: TimeInterval
        let application: NSRunningApplication?
        var pickerShown = false
        var releasedAt: TimeInterval?
        var finderPasteDecisionPending = false
    }

    private static let syntheticEventMarker: Int64 = 0x48414C4657494E
    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<KeyboardExtras>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handle(type, event)
    }

    init() {
        clipboardSwitch.onChange = { [weak self] enabled in
            self?.clipboardEnabled = enabled
            self?.refreshPermission()
        }
        cutPasteSwitch.onChange = { [weak self] enabled in
            self?.cutPasteEnabled = enabled
            if !enabled {
                guard let self else { return }
                let cutState = self.cutState
                let pasteboardIsUnchanged = cutState.map {
                    $0.awaitingFileCopy
                        && NSPasteboard.general.changeCount == $0.changeCountAtCut
                } ?? false
                self.cutState = nil
                if pasteboardIsUnchanged {
                    self.resolvePendingFinderPasteWithoutClipboardChange()
                } else {
                    self.resolvePendingFinderPaste(matched: false)
                }
            }
            self?.refreshPermission()
        }
        finderEnterSwitch.onChange = { [weak self] enabled in
            self?.finderEnterEnabled = enabled
            self?.refreshPermission()
        }
        lastWindowSwitch.onChange = { [weak self] enabled in
            self?.lastWindowEnabled = enabled
            self?.refreshPermission()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPermission() }
    }

    func addMenuItems(to menu: NSMenu) {
        let heading = NSMenuItem(title: "Keyboard and Finder", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(clipboardSwitch.makeMenuItem())
        menu.addItem(cutPasteSwitch.makeMenuItem())
        menu.addItem(finderEnterSwitch.makeMenuItem())
        menu.addItem(lastWindowSwitch.makeMenuItem())
    }

    func start() {
        clipboardSwitch.start()
        cutPasteSwitch.start()
        finderEnterSwitch.start()
        lastWindowSwitch.start()
        refreshPermission()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopRuntime()
    }

    func refreshPermission() {
        let enabled = clipboardEnabled || cutPasteEnabled || finderEnterEnabled || lastWindowEnabled
        guard enabled else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            stopRuntime()
            return
        }
        if Permissions.accessibilityGranted {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.refreshPermission()
            }
        }
        guard Permissions.accessibilityGranted else {
            stopRuntime()
            return
        }
        startRuntime()
    }

    private func startRuntime() {
        guard startEventTap() else {
            stopRuntime()
            return
        }
        if clipboardEnabled && !clipboardRunning {
            clipboardHistory.start()
            clipboardRunning = true
        } else if !clipboardEnabled && clipboardRunning {
            clipboardHistory.stop()
            clipboardRunning = false
        }
        if clipboardEnabled || cutPasteEnabled {
            if pasteboardTimer == nil {
                observedPasteboardChangeCount = NSPasteboard.general.changeCount
                pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.checkPasteboard()
                }
            }
        } else {
            pasteboardTimer?.invalidate()
            pasteboardTimer = nil
            observedPasteboardChangeCount = nil
        }
    }

    private func stopRuntime() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        observedPasteboardChangeCount = nil
        suppressedHistoryChangeCount = nil
        cutState = nil
        pendingFinderPasteID = nil
        pastePress = nil
        pendingExtraPasteKeyUps = 0
        queuedPasteTargets.removeAll()
        if clipboardRunning { clipboardHistory.stop() }
        clipboardRunning = false
    }

    private func startEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: Self.eventTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Halfwin: Keyboard and Finder shortcuts could not start because macOS refused the event tap.")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            NSLog("Halfwin: Keyboard and Finder shortcuts could not start because the event tap source failed.")
            return false
        }
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedKeyUps.removeAll()
            pendingExtraPasteKeyUps = 0
            pastePress = nil
            pendingFinderPasteID = nil
            queuedPasteTargets.removeAll()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown {
            if lastWindowEnabled, let application = applicationClosingUnderPointer() {
                checkForLastWindow(of: application)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            if keyCode == 9, pendingExtraPasteKeyUps > 0 {
                pendingExtraPasteKeyUps -= 1
                swallowedKeyUps.remove(keyCode)
                return nil
            }
            if keyCode == 9, var press = pastePress {
                swallowedKeyUps.remove(keyCode)
                if pendingFinderPasteID == press.id {
                    let releasedAt = ProcessInfo.processInfo.systemUptime
                    press.releasedAt = releasedAt
                    pastePress = press
                    if !press.finderPasteDecisionPending, cutState?.awaitingFileCopy == false {
                        if releasedAt - press.startedAt >= 0.45 {
                            showFinderHistoryOrMovePaste(for: press.id)
                        } else {
                            resolvePendingFinderPaste(matched: true)
                        }
                    }
                    return nil
                }
                pastePress = nil
                if !press.pickerShown {
                    replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                        self?.replayQueuedPastes()
                    }
                }
                return nil
            }
            if swallowedKeyUps.remove(keyCode) != nil { return nil }
            return Unmanaged.passUnretained(event)
        }

        if clipboardHistory.isPickerVisible {
            switch keyCode {
            case 123, 126: clipboardHistory.moveSelection(-1)
            case 124, 125: clipboardHistory.moveSelection(1)
            case 36, 76: clipboardHistory.chooseSelection()
            case 53: clipboardHistory.cancelPicker()
            default: return Unmanaged.passUnretained(event)
            }
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            if swallowedKeyUps.contains(keyCode) || (pastePress != nil && keyCode == 9) { return nil }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let application = NSWorkspace.shared.frontmostApplication

        if keyCode == 9, isPlainCommand(flags), pendingFinderPasteID != nil {
            queuedPasteTargets.append(application)
            pendingExtraPasteKeyUps += 1
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        if cutPasteEnabled, keyCode == 9, isPlainCommand(flags), isFinder(application) {
            checkPasteboard()
            if let application, cutState != nil {
                var press = makePastePress(for: application)
                press.finderPasteDecisionPending = true
                pastePress = press
                pendingFinderPasteID = press.id
                swallowedKeyUps.insert(keyCode)
                DispatchQueue.main.async { [weak self] in self?.handleFinderPaste(for: press.id) }
                return nil
            }
        }
        if cutPasteEnabled, keyCode == 7, isPlainCommand(flags), let application, isFinder(application) {
            let changeCountAtCut = NSPasteboard.general.changeCount
            swallowedKeyUps.insert(keyCode)
            DispatchQueue.main.async { [weak self] in
                self?.handleFinderCut(in: application, changeCountAtCut: changeCountAtCut)
            }
            return nil
        }
        if finderEnterEnabled, (keyCode == 36 || keyCode == 76), isUnmodified(flags),
           let application, isFinder(application) {
            swallowedKeyUps.insert(keyCode)
            DispatchQueue.main.async { [weak self] in
                self?.handleFinderEnter(in: application, keyCode: keyCode)
            }
            return nil
        }
        if lastWindowEnabled, keyCode == 13, isPlainCommand(flags),
           let application, shouldMonitor(application) {
            swallowedKeyUps.insert(keyCode)
            DispatchQueue.main.async { [weak self] in self?.handleLastWindowShortcut(in: application) }
            return nil
        }
        if clipboardEnabled, keyCode == 9, isPlainCommand(flags) {
            let press = makePastePress(for: application)
            swallowedKeyUps.insert(keyCode)
            showPickerAfterHold(for: press.id)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func makePastePress(for application: NSRunningApplication?) -> PastePress {
        let press = PastePress(id: UUID(), startedAt: ProcessInfo.processInfo.systemUptime,
                               application: application)
        pastePress = press
        return press
    }

    private func handleFinderPaste(for id: UUID) {
        guard var press = pastePress, press.id == id, let application = press.application else { return }
        let textFieldFocused = finderTextFieldIsFocused(in: application)
        press.finderPasteDecisionPending = false
        pastePress = press
        guard !textFieldFocused, let cutState else {
            pendingFinderPasteID = nil
            if clipboardEnabled {
                if let releasedAt = press.releasedAt, releasedAt - press.startedAt < 0.45 {
                    pastePress = nil
                    replayPaste(to: application, flags: .maskCommand) { [weak self] in
                        self?.replayQueuedPastes()
                    }
                } else {
                    showPickerAfterHold(for: id)
                }
            } else if press.releasedAt != nil {
                pastePress = nil
                replayPaste(to: application, flags: .maskCommand) { [weak self] in
                    self?.replayQueuedPastes()
                }
            }
            return
        }
        if !cutState.awaitingFileCopy {
            if clipboardEnabled {
                if let releasedAt = press.releasedAt, releasedAt - press.startedAt < 0.45 {
                    resolvePendingFinderPaste(matched: true)
                } else {
                    showPickerAfterHold(for: id)
                }
            } else {
                resolvePendingFinderPaste(matched: true)
            }
        } else {
            showPickerAfterHold(for: id)
        }
    }

    private func showFinderHistoryOrMovePaste(for id: UUID) {
        guard pastePress?.id == id else { return }
        if clipboardEnabled, !clipboardHistory.entries.isEmpty {
            cutState = nil
            pendingFinderPasteID = nil
            showClipboardPicker(for: id)
        } else {
            resolvePendingFinderPaste(matched: true)
        }
    }

    private func handleFinderCut(in application: NSRunningApplication, changeCountAtCut: Int) {
        guard !application.isTerminated else { return }
        guard cutPasteEnabled else {
            replayKeyCombo(to: application, keyCode: 7, flags: .maskCommand)
            return
        }
        checkPasteboard()
        if let urls = selectedFinderFileURLs(in: application), !urls.isEmpty {
            cutState = CutState(expectedURLs: Set(urls.map(\.standardizedFileURL)),
                                changeCountAtCut: changeCountAtCut,
                                startedAt: ProcessInfo.processInfo.systemUptime)
            postKeyCombo(8, flags: .maskCommand)
        } else {
            replayKeyCombo(to: application, keyCode: 7, flags: .maskCommand)
        }
    }

    private func handleFinderEnter(in application: NSRunningApplication, keyCode: CGKeyCode) {
        guard !application.isTerminated else { return }
        if finderEnterEnabled, selectedFinderFileURLs(in: application) != nil {
            replayKeyCombo(to: application, keyCode: 31, flags: .maskCommand)
        } else {
            replayKeyCombo(to: application, keyCode: keyCode, flags: [])
        }
    }

    private func handleLastWindowShortcut(in application: NSRunningApplication) {
        guard !application.isTerminated else { return }
        guard lastWindowEnabled, shouldMonitor(application),
              let recordedCount = windowCount(for: application), recordedCount > 0 else {
            replayKeyCombo(to: application, keyCode: 13, flags: .maskCommand)
            return
        }
        replayKeyCombo(to: application, keyCode: 13, flags: .maskCommand) { [weak self] in
            self?.scheduleLastWindowCheck(of: application, recordedCount: recordedCount)
        }
    }

    private func showPickerAfterHold(for id: UUID) {
        guard let press = pastePress, press.id == id else { return }
        let remaining = max(0, press.startedAt + 0.45 - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.pastePress?.id == id else { return }
            if self.pendingFinderPasteID == id {
                self.checkPasteboard()
                guard self.pendingFinderPasteID == id else { return }
                if let press = self.pastePress, let releasedAt = press.releasedAt,
                   releasedAt - press.startedAt < 0.45 {
                    return
                }
                self.resolvePendingFinderPaste(matched: false)
            } else {
                self.showClipboardPicker(for: id)
            }
        }
    }

    private func resolvePendingFinderPaste(matched: Bool) {
        guard let id = pendingFinderPasteID, let press = pastePress, press.id == id else {
            pendingFinderPasteID = nil
            return
        }
        let moveFiles = matched || (cutState?.awaitingFileCopy == false && clipboardHistory.entries.isEmpty)
        pendingFinderPasteID = nil
        cutState = nil
        if moveFiles {
            pastePress = nil
            replayKeyCombo(to: press.application, keyCode: 9, flags: [.maskCommand, .maskAlternate]) { [weak self] in
                self?.replayQueuedPastes()
            }
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - press.startedAt
        if let releasedAt = press.releasedAt, releasedAt - press.startedAt < 0.45 {
            pastePress = nil
            replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                self?.replayQueuedPastes()
            }
        } else if elapsed >= 0.45 {
            showClipboardPicker(for: id)
        } else if clipboardEnabled {
            showPickerAfterHold(for: id)
        }
    }

    private func showClipboardPicker(for id: UUID) {
        guard var press = pastePress, press.id == id else { return }
        guard clipboardEnabled else {
            if press.releasedAt != nil {
                pastePress = nil
                replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                    self?.replayQueuedPastes()
                }
            }
            return
        }
        let targetApplication = press.application
        let shown = clipboardHistory.showPicker(at: NSEvent.mouseLocation, onChoose: { [weak self] entry in
            guard let self else { return }
            self.pendingFinderPasteID = nil
            self.pastePress = nil
            entry.write(to: .general)
            self.suppressedHistoryChangeCount = NSPasteboard.general.changeCount
            self.replayPaste(to: targetApplication, flags: .maskCommand) {
                self.replayQueuedPastes()
            }
        }, onCancel: { [weak self] in
            guard let self else { return }
            self.pendingFinderPasteID = nil
            self.pastePress = nil
            self.restore(targetApplication)
            self.replayQueuedPastes()
        })
        press.pickerShown = shown
        pastePress = press
        if !shown && press.releasedAt != nil {
            pastePress = nil
            replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                self?.replayQueuedPastes()
            }
        }
    }

    private func resolvePendingFinderPasteWithoutClipboardChange() {
        cutState = nil
        guard let id = pendingFinderPasteID, let press = pastePress, press.id == id else {
            pendingFinderPasteID = nil
            queuedPasteTargets.removeAll()
            return
        }
        pendingFinderPasteID = nil
        let wasHeld = press.releasedAt == nil
        if let releasedAt = press.releasedAt, releasedAt - press.startedAt < 0.45 {
            pastePress = nil
            replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                self?.replayQueuedPastes()
            }
            return
        }
        if clipboardEnabled {
            if wasHeld, ProcessInfo.processInfo.systemUptime - press.startedAt < 0.45 {
                showPickerAfterHold(for: id)
            } else {
                showClipboardPicker(for: id)
            }
        } else if press.releasedAt != nil {
            pastePress = nil
            replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                self?.replayQueuedPastes()
            }
        }
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard let previous = observedPasteboardChangeCount else {
            observedPasteboardChangeCount = changeCount
            return
        }
        guard changeCount != previous else {
            if let cutState, cutState.awaitingFileCopy,
               ProcessInfo.processInfo.systemUptime - cutState.startedAt > 2 {
                self.cutState = nil
                resolvePendingFinderPasteWithoutClipboardChange()
            }
            return
        }
        observedPasteboardChangeCount = changeCount
        if let cutState {
            let isExpectedCopy = cutState.awaitingFileCopy
                && changeCount == cutState.changeCountAtCut &+ 1
                && ProcessInfo.processInfo.systemUptime - cutState.startedAt <= 2
                && fileURLs(on: pasteboard) == cutState.expectedURLs
            if isExpectedCopy {
                self.cutState?.awaitingFileCopy = false
                if let id = pendingFinderPasteID, let press = pastePress, press.id == id,
                   !press.finderPasteDecisionPending {
                    let heldLongEnough = (press.releasedAt ?? ProcessInfo.processInfo.systemUptime)
                        - press.startedAt >= 0.45
                    if clipboardEnabled, heldLongEnough {
                        showFinderHistoryOrMovePaste(for: id)
                    } else if !clipboardEnabled || press.releasedAt != nil {
                        resolvePendingFinderPaste(matched: true)
                    }
                }
            } else {
                self.cutState = nil
                resolvePendingFinderPaste(matched: false)
            }
        }
        if suppressedHistoryChangeCount == changeCount {
            suppressedHistoryChangeCount = nil
        } else if clipboardEnabled {
            clipboardHistory.capture(from: pasteboard)
        }
    }

    private func checkForLastWindow(of application: NSRunningApplication) {
        guard shouldMonitor(application), let recordedCount = windowCount(for: application), recordedCount > 0 else { return }
        scheduleLastWindowCheck(of: application, recordedCount: recordedCount)
    }

    private func scheduleLastWindowCheck(of application: NSRunningApplication, recordedCount: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, recordedCount > 0, !application.isTerminated,
                  self.lastWindowEnabled, self.windowCount(for: application) == 0 else { return }
            application.terminate()
        }
    }

    private func shouldMonitor(_ application: NSRunningApplication) -> Bool {
        application.activationPolicy == .regular
            && application.processIdentifier != NSRunningApplication.current.processIdentifier
            && application.bundleIdentifier != "com.apple.finder"
            && application.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private func windowCount(for application: NSRunningApplication) -> Int? {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        let windows: [AXUIElement]? = attribute(element, kAXWindowsAttribute as String)
        return windows?.count
    }

    private func applicationClosingUnderPointer() -> NSRunningApplication? {
        let point = NSEvent.mouseLocation
        guard let window = AXWindow.windowUnderCursor(at: point),
              let closeButton: AXUIElement = attribute(window.element, kAXCloseButtonAttribute as String) else { return nil }
        AXUIElementSetMessagingTimeout(closeButton, 0.1)
        guard let frame = AXWindow(element: closeButton).frame, frame.contains(point) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window.element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func selectedFinderFileURLs(in application: NSRunningApplication) -> [URL]? {
        guard let focused = focusedElement(in: application), !isTextField(focused) else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var selectedElements: [AXUIElement] = []
        for root in [focused, appElement] {
            var current: AXUIElement? = root
            for _ in 0..<12 {
                guard let item = current else { break }
                AXUIElementSetMessagingTimeout(item, 0.15)
                if let selected: NSNumber = attribute(item, kAXSelectedAttribute as String), selected.boolValue {
                    selectedElements.append(item)
                }
                if let children: [AXUIElement] = attribute(item, kAXSelectedChildrenAttribute as String) {
                    selectedElements.append(contentsOf: children)
                }
                current = attribute(item, kAXParentAttribute as String)
            }
        }
        guard !selectedElements.isEmpty else { return nil }
        var urls = Set<URL>()
        for element in selectedElements {
            guard let url = fileURL(of: element), url.isFileURL else { return nil }
            urls.insert(url.standardizedFileURL)
        }
        return urls.isEmpty ? nil : Array(urls)
    }

    private func finderTextFieldIsFocused(in application: NSRunningApplication?) -> Bool {
        guard let application, let focused = focusedElement(in: application) else { return false }
        return isTextField(focused)
    }

    private func isTextField(_ element: AXUIElement) -> Bool {
        guard let role = role(of: element) else { return false }
        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
    }

    private func focusedElement(in application: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        return attribute(appElement, kAXFocusedUIElementAttribute as String)
    }

    private func fileURL(of element: AXUIElement) -> URL? {
        let value: AnyObject? = attribute(element, kAXURLAttribute as String)
        return (value as? URL) ?? (value as? NSURL).map { $0 as URL }
    }

    private func fileURLs(on pasteboard: NSPasteboard) -> Set<URL>? {
        let fileURLType = NSPasteboard.PasteboardType("public.file-url")
        if pasteboard.types?.contains(fileURLType) == true,
           let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL],
           !objects.isEmpty {
            let urls = objects.map { $0 as URL }
            guard urls.allSatisfy(\.isFileURL) else { return nil }
            return Set(urls.map(\.standardizedFileURL))
        }
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String],
           !paths.isEmpty, paths.allSatisfy({ ($0 as NSString).isAbsolutePath }) {
            return Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL })
        }
        return nil
    }

    private func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute as String)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func isFinder(_ application: NSRunningApplication?) -> Bool {
        application?.bundleIdentifier == "com.apple.finder"
    }

    private func isPlainCommand(_ flags: CGEventFlags) -> Bool {
        let ignored: CGEventFlags = [.maskSecondaryFn, .maskAlphaShift, .maskNumericPad]
        return flags.subtracting(ignored) == .maskCommand
    }

    private func isUnmodified(_ flags: CGEventFlags) -> Bool {
        let ignored: CGEventFlags = [.maskSecondaryFn, .maskAlphaShift, .maskNumericPad]
        return flags.subtracting(ignored).isEmpty
    }

    private func restore(_ application: NSRunningApplication?) {
        application?.activate(options: [.activateAllWindows])
    }

    private func replayQueuedPastes() {
        let targets = queuedPasteTargets
        queuedPasteTargets.removeAll()
        replayQueuedPastes(targets, at: 0)
    }

    private func replayQueuedPastes(_ targets: [NSRunningApplication?], at index: Int) {
        guard targets.indices.contains(index) else { return }
        replayPaste(to: targets[index], flags: .maskCommand) { [weak self] in
            self?.replayQueuedPastes(targets, at: index + 1)
        }
    }

    private func replayPaste(to application: NSRunningApplication?, flags: CGEventFlags,
                             completion: (() -> Void)? = nil) {
        replayKeyCombo(to: application, keyCode: 9, flags: flags, completion: completion)
    }

    private func replayKeyCombo(to application: NSRunningApplication?, keyCode: CGKeyCode, flags: CGEventFlags,
                                completion: (() -> Void)? = nil) {
        guard let application else {
            postKeyCombo(keyCode, flags: flags)
            completion?()
            return
        }
        guard !application.isTerminated else {
            completion?()
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier else {
            postKeyCombo(keyCode, flags: flags)
            completion?()
            return
        }
        restore(application)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard !application.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                completion?()
                return
            }
            self.postKeyCombo(keyCode, flags: flags)
            completion?()
        }
    }

    private func postKeyCombo(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
