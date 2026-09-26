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
    private var pasteboardPollingInterval: TimeInterval?
    private var observedPasteboardChangeCount: Int?
    private var suppressedHistoryChangeCount: Int?
    private var cachedQualifyingWindowCounts: [pid_t: Int]?
    private var clipboardRunning = false
    private var runtimeRunning = false
    var onCutPendingChange: ((Bool) -> Void)?
    var onFinderMovePaste: ((URL, [URL]) -> Void)?
    private var cutState: CutState? {
        didSet {
            onCutPendingChange?(cutState != nil)
            refreshPasteboardTimer()
        }
    }
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
    private static let rolloverEventMarker: Int64 = 0x48414C46524F4C
    private static let lastWindowExcludedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.dhrlabs.halfwin",
        "com.apple.Music",
        "com.apple.mail",
        "com.apple.MobileSMS",
        "com.apple.iCal",
        "com.apple.Notes",
        "com.apple.reminders",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.apple.Photos",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
        "com.apple.Terminal" // Terminal keeps sessions alive after its last window closes.
    ]
    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<KeyboardExtras>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handle(type, event)
    }

    init() {
#if DEBUG
        Self.selfCheck()
#endif
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
        ) { [weak self] _ in self?.applicationDidActivate() }
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
        runtimeRunning = true
        if clipboardEnabled && !clipboardRunning {
            clipboardHistory.start()
            clipboardRunning = true
        } else if !clipboardEnabled && clipboardRunning {
            clipboardHistory.stop()
            clipboardRunning = false
        }
        refreshPasteboardTimer()
        if lastWindowEnabled, cachedQualifyingWindowCounts == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.runtimeRunning, self.lastWindowEnabled else { return }
                _ = self.refreshCGWindowSnapshot()
            }
        }
    }

    private func stopRuntime() {
        runtimeRunning = false
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
        pasteboardPollingInterval = nil
        observedPasteboardChangeCount = nil
        suppressedHistoryChangeCount = nil
        cachedQualifyingWindowCounts = nil
        cutState = nil
        pendingFinderPasteID = nil
        pastePress = nil
        pendingExtraPasteKeyUps = 0
        queuedPasteTargets.removeAll()
        if clipboardRunning { clipboardHistory.stop() }
        clipboardRunning = false
    }

    private func refreshPasteboardTimer() {
        guard runtimeRunning, clipboardEnabled || cutPasteEnabled else {
            pasteboardTimer?.invalidate()
            pasteboardTimer = nil
            pasteboardPollingInterval = nil
            observedPasteboardChangeCount = nil
            return
        }
        let interval: TimeInterval = cutState?.awaitingFileCopy == true ? 0.05 : 0.5
        guard pasteboardTimer == nil || pasteboardPollingInterval != interval else { return }
        pasteboardTimer?.invalidate()
        if pasteboardTimer == nil { observedPasteboardChangeCount = NSPasteboard.general.changeCount }
        pasteboardPollingInterval = interval
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    private func applicationDidActivate() {
        refreshPermission()
        let frontmost = NSWorkspace.shared.frontmostApplication
        if clipboardHistory.isPickerVisible,
           pastePress?.application?.processIdentifier != frontmost?.processIdentifier {
            clipboardHistory.cancelPicker()
        }
        if let press = pastePress,
           press.application?.processIdentifier != frontmost?.processIdentifier {
            discardPendingPaste()
        }
        if !isFinder(frontmost) { cutState = nil }
    }

    private func startEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
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
        let eventMarker = event.getIntegerValueField(.eventSourceUserData)
        if eventMarker == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }
        let isRolloverRepost = eventMarker == Self.rolloverEventMarker
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let press = pastePress, !press.pickerShown,
               (press.releasedAt ?? ProcessInfo.processInfo.systemUptime) - press.startedAt < 0.45 {
                let queuedTargets = queuedPasteTargets
                replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                    self?.replayQueuedPastes(queuedTargets, at: 0)
                }
            }
            swallowedKeyUps.removeAll()
            pendingExtraPasteKeyUps = 0
            pastePress = nil
            pendingFinderPasteID = nil
            queuedPasteTargets.removeAll()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if clipboardHistory.isPickerVisible {
                clipboardHistory.dismissPickerIfOutside(NSEvent.mouseLocation)
            }
            if type == .leftMouseDown, lastWindowEnabled {
                let point = NSEvent.mouseLocation
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lastWindowEnabled,
                          !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }),
                          NSWorkspace.shared.frontmostApplication?.processIdentifier
                            != NSRunningApplication.current.processIdentifier else { return }
                    guard self.refreshCGWindowSnapshot() != nil,
                          let application = self.applicationClosingUnderPointer(at: point),
                          let recordedCount = self.windowCount(for: application), recordedCount > 0 else { return }
                    self.checkForLastWindow(of: application, recordedCount: recordedCount)
                }
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

        let flags = event.flags
        let application = NSWorkspace.shared.frontmostApplication
        if keyCode == 53, isFinder(application) { cancelFinderCut() }
        if keyCode == 9,
           flags.intersection(Self.shortcutModifierFlags) == [.maskCommand, .maskAlternate] {
            cancelFinderCut()
        }

        if clipboardHistory.isPickerVisible {
            if keyCode == 9, isPlainCommand(flags),
               event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
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

        if !isRolloverRepost, let press = pastePress, !press.pickerShown, keyCode != 9,
           ProcessInfo.processInfo.systemUptime - press.startedAt < 0.45 {
            if pendingFinderPasteID == press.id {
                if cutState?.awaitingFileCopy == true || press.finderPasteDecisionPending {
                    let queuedTargets = queuedPasteTargets
                    queuedPasteTargets.removeAll()
                    pendingFinderPasteID = nil
                    pastePress = nil
                    cutState = nil
                    replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                        self?.replayQueuedPastes(queuedTargets, at: 0) { [weak self] in
                            self?.repostKeyDown(event)
                        }
                    }
                } else {
                    resolvePendingFinderPaste(matched: cutState?.awaitingFileCopy == false)
                    repostKeyDown(event)
                }
                return nil
            }
            let queuedTargets = queuedPasteTargets
            queuedPasteTargets.removeAll()
            pendingFinderPasteID = nil
            pastePress = nil
            replayPaste(to: press.application, flags: .maskCommand) { [weak self] in
                self?.replayQueuedPastes(queuedTargets, at: 0) { [weak self] in
                    self?.repostKeyDown(event)
                }
            }
            return nil
        }

        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            if swallowedKeyUps.contains(keyCode) || (pastePress != nil && keyCode == 9) { return nil }
            return Unmanaged.passUnretained(event)
        }

        if keyCode == 9, isPlainCommand(flags), pendingFinderPasteID != nil {
            queuedPasteTargets.append(application)
            pendingExtraPasteKeyUps += 1
            swallowedKeyUps.insert(keyCode)
            return nil
        }

        if cutPasteEnabled, keyCode == 9, isPlainCommand(flags), isFinder(application) {
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
            swallowedKeyUps.insert(keyCode)
            DispatchQueue.main.async { [weak self] in
                self?.handleFinderCut(in: application)
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
           let application, shouldMonitor(application),
           let recordedCount = windowCount(for: application), recordedCount > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFrontmost(application), self.lastWindowEnabled else { return }
                self.checkForLastWindow(of: application, recordedCount: recordedCount)
            }
            return Unmanaged.passUnretained(event)
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
        guard let initialPress = pastePress, initialPress.id == id,
              let initialApplication = initialPress.application else { return }
        guard isFrontmost(initialApplication) else {
            discardPendingPaste()
            return
        }
        checkPasteboard()
        guard var press = pastePress, press.id == id, pendingFinderPasteID == id,
              let application = press.application, isFrontmost(application) else { return }
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

    private func handleFinderCut(in application: NSRunningApplication) {
        guard isFrontmost(application) else { return }
        guard cutPasteEnabled else {
            replayKeyCombo(to: application, keyCode: 7, flags: .maskCommand)
            return
        }
        checkPasteboard()
        if let urls = selectedFinderFileURLs(in: application), !urls.isEmpty {
            guard isFrontmost(application), cutPasteEnabled else { return }
            let changeCountBeforeCopy = NSPasteboard.general.changeCount
            cutState = CutState(expectedURLs: Set(urls.map(\.standardizedFileURL)),
                                changeCountAtCut: changeCountBeforeCopy,
                                startedAt: ProcessInfo.processInfo.systemUptime)
            postKeyCombo(8, flags: .maskCommand)
        } else {
            replayKeyCombo(to: application, keyCode: 7, flags: .maskCommand)
        }
    }

    private func handleFinderEnter(in application: NSRunningApplication, keyCode: CGKeyCode) {
        guard isFrontmost(application) else { return }
        if finderEnterEnabled, selectedFinderFileURLs(in: application) != nil {
            replayKeyCombo(to: application, keyCode: 31, flags: .maskCommand)
        } else {
            replayKeyCombo(to: application, keyCode: keyCode, flags: [])
        }
    }

    private func showPickerAfterHold(for id: UUID) {
        guard let press = pastePress, press.id == id else { return }
        let remaining = max(0, press.startedAt + 0.45 - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, let press = self.pastePress, press.id == id else { return }
            guard self.isFrontmost(press.application) else {
                self.discardPendingPaste()
                return
            }
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
        let sourceURLs = cutState?.expectedURLs
        pendingFinderPasteID = nil
        cutState = nil
        if moveFiles {
            pastePress = nil
            if let application = press.application,
               isFrontmost(application),
               let destination = CopyProgressWindow.finderDestination(in: application),
               let sourceURLs {
                onFinderMovePaste?(destination, sourceURLs.map {
                    destination.appendingPathComponent($0.lastPathComponent).standardizedFileURL
                })
            }
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
        guard isFrontmost(press.application) else {
            discardPendingPaste()
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

    private func cancelFinderCut() {
        guard cutState != nil else { return }
        cutState = nil
        if pendingFinderPasteID != nil {
            resolvePendingFinderPasteWithoutClipboardChange()
        }
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        if let cutState,
           ProcessInfo.processInfo.systemUptime - cutState.startedAt >= 60 {
            self.cutState = nil
            resolvePendingFinderPasteWithoutClipboardChange()
        }
        guard let previous = observedPasteboardChangeCount else {
            observedPasteboardChangeCount = changeCount
            return
        }
        guard changeCount != previous else { return }
        observedPasteboardChangeCount = changeCount
        let passwordManagerWasActive = clipboardHistory.consumePasswordManagerActivation()
        if let cutState {
            let isExpectedCopy = cutState.awaitingFileCopy
                && changeCount == cutState.changeCountAtCut &+ 1
                && ProcessInfo.processInfo.systemUptime - cutState.startedAt < 60
                && fileURLs(on: pasteboard) == cutState.expectedURLs
            if isExpectedCopy {
                var updatedCutState = cutState
                updatedCutState.awaitingFileCopy = false
                self.cutState = updatedCutState
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
        } else if clipboardEnabled, !passwordManagerWasActive {
            clipboardHistory.capture(from: pasteboard)
        }
    }

    private func checkForLastWindow(of application: NSRunningApplication, recordedCount: Int) {
        guard shouldMonitor(application), recordedCount > 0 else { return }
        scheduleLastWindowCheck(of: application)
    }

    private func scheduleLastWindowCheck(of application: NSRunningApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !application.isTerminated, self.lastWindowEnabled,
                  self.hasNoOpenWindows(of: application) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !application.isTerminated,
                      self.lastWindowEnabled,
                      self.hasNoOpenWindows(of: application) else { return }
                application.terminate()
            }
        }
    }

    private func shouldMonitor(_ application: NSRunningApplication) -> Bool {
        application.activationPolicy == .regular
            && application.processIdentifier != NSRunningApplication.current.processIdentifier
            && !Self.lastWindowExcludedBundleIdentifiers.contains(application.bundleIdentifier ?? "")
    }

    private func hasNoOpenWindows(of application: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        guard let windows: [AXUIElement] = attribute(appElement, kAXWindowsAttribute as String) else {
            return false
        }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.15)
            guard let windowRole = role(of: window) else { return false }
            if windowRole == kAXWindowRole as String { return false }
        }
        guard let counts = refreshCGWindowSnapshot() else { return false }
        // Closed windows retained by an app can block quitting; this fail-safe false negative is acceptable.
        return counts[application.processIdentifier, default: 0] == 0
    }

    private func refreshCGWindowSnapshot() -> [pid_t: Int]? {
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            cachedQualifyingWindowCounts = nil
            return nil
        }
        let counts = Self.qualifyingCGWindowCounts(windows)
        cachedQualifyingWindowCounts = counts
        return counts
    }

    private func windowCount(for application: NSRunningApplication) -> Int? {
        guard let cachedQualifyingWindowCounts else { return nil }
        return cachedQualifyingWindowCounts[application.processIdentifier, default: 0]
    }

    private static func qualifyingCGWindowCounts(_ windows: [[String: Any]]) -> [pid_t: Int] {
        windows.reduce(into: [:]) { counts, window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 100, frame.height >= 100,
                  !(frame.width == 500 && frame.height == 500) else { return }
            counts[pid_t(ownerPID), default: 0] += 1
        }
    }

    private static func qualifyingCGWindowCount(_ windows: [[String: Any]], pid: pid_t) -> Int {
        qualifyingCGWindowCounts(windows)[pid, default: 0]
    }

    private static func selfCheck() {
        let pid = pid_t(1234)
        func window(width: CGFloat, height: CGFloat) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: Int(pid),
                kCGWindowLayer as String: 0,
                kCGWindowAlpha as String: 1.0,
                kCGWindowBounds as String: CGRect(x: 0, y: 0, width: width, height: height).dictionaryRepresentation
            ]
        }
        let stubs = [
            window(width: 3440, height: 30),
            window(width: 1710, height: 34),
            window(width: 500, height: 500),
            window(width: 64, height: 64),
            window(width: 1, height: 1)
        ]
        let realWindow = window(width: 800, height: 600)
        let smallWindow = window(width: 100, height: 100)
        assert(qualifyingCGWindowCount(stubs, pid: pid) == 0)
        assert(qualifyingCGWindowCount([realWindow], pid: pid) == 1)
        assert(qualifyingCGWindowCount([smallWindow], pid: pid) == 1)
        assert(qualifyingCGWindowCount(stubs + [realWindow], pid: pid) == 1)
    }

    private func applicationClosingUnderPointer(at point: NSPoint) -> NSRunningApplication? {
        guard let window = AXWindow.windowUnderCursor(at: point),
              let pid = window.processIdentifier,
              pid != NSRunningApplication.current.processIdentifier,
              let closeButton: AXUIElement = attribute(window.element, kAXCloseButtonAttribute as String) else { return nil }
        AXUIElementSetMessagingTimeout(closeButton, 0.1)
        guard let frame = AXWindow(element: closeButton).frame, frame.contains(point) else { return nil }
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
        flags.intersection(Self.shortcutModifierFlags) == .maskCommand
    }

    private func isUnmodified(_ flags: CGEventFlags) -> Bool {
        flags.intersection(Self.shortcutModifierFlags).isEmpty
    }

    private func isFrontmost(_ application: NSRunningApplication?) -> Bool {
        guard let application, !application.isTerminated else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    private func discardPendingPaste() {
        pendingFinderPasteID = nil
        pastePress = nil
        queuedPasteTargets.removeAll()
    }

    private static let shortcutModifierFlags: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand
    ]

    private func replayQueuedPastes() {
        let targets = queuedPasteTargets
        queuedPasteTargets.removeAll()
        replayQueuedPastes(targets, at: 0)
    }

    private func replayQueuedPastes(_ targets: [NSRunningApplication?], at index: Int,
                                    completion: (() -> Void)? = nil) {
        guard targets.indices.contains(index) else {
            completion?()
            return
        }
        replayPaste(to: targets[index], flags: .maskCommand) { [weak self] in
            self?.replayQueuedPastes(targets, at: index + 1, completion: completion)
        }
    }

    private func replayPaste(to application: NSRunningApplication?, flags: CGEventFlags,
                             completion: (() -> Void)? = nil) {
        replayKeyCombo(to: application, keyCode: 9, flags: flags, completion: completion)
    }

    private func replayKeyCombo(to application: NSRunningApplication?, keyCode: CGKeyCode, flags: CGEventFlags,
                                completion: (() -> Void)? = nil) {
        if let application, isFrontmost(application) {
            postKeyCombo(keyCode, flags: flags)
        }
        completion?()
    }

    private func repostKeyDown(_ event: CGEvent) {
        guard let replayedEvent = event.copy() else { return }
        replayedEvent.setIntegerValueField(.eventSourceUserData, value: Self.rolloverEventMarker)
        replayedEvent.post(tap: .cghidEventTap)
    }

    private func postKeyCombo(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags.intersection(Self.shortcutModifierFlags)
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
