import AppKit
import Carbon.HIToolbox
import CoreGraphics

private let sideButtonShortcutBundleIDs: Set<String> = [
    "com.apple.finder",
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "org.mozilla.firefox",
    "company.thebrowser.Browser",
    "com.tinyspeck.slackmacgap",
    "com.apple.systempreferences",
    "com.apple.AppStore",
    "com.apple.Music",
    "com.apple.Notes",
    "com.apple.helpviewer"
]

final class MouseFeatures {
    let windowsScrollDirection = FeatureSwitch(key: "mouse.windows-scroll-direction", title: "Windows scroll direction", defaultOn: true)
    let sideButtonsBackForward = FeatureSwitch(key: "mouse.side-buttons-back-forward", title: "Side buttons back/forward", defaultOn: true)

    private let eventTap = MouseEventTap()
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init() {
        windowsScrollDirection.onChange = { [weak self] _ in self?.refreshPermission() }
        sideButtonsBackForward.onChange = { [weak self] _ in self?.refreshPermission() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPermission() }
    }

    func start() {
        windowsScrollDirection.start()
        sideButtonsBackForward.start()
        refreshPermission()
    }

    func refreshPermission() {
        let accessibilityGranted = Permissions.accessibilityGranted
        if !accessibilityGranted && (windowsScrollDirection.isOn || sideButtonsBackForward.isOn) {
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.refreshPermission()
                }
            }
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
        eventTap.configure(
            scrollEnabled: windowsScrollDirection.isOn,
            sideButtonsEnabled: sideButtonsBackForward.isOn,
            accessibilityGranted: accessibilityGranted
        )
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        eventTap.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }
}

private final class MouseEventTap {
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<MouseEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type, event)
    }

    private let runLoopReady = DispatchSemaphore(value: 0)
    private lazy var thread: Thread = {
        let thread = Thread { [weak self] in self?.runEventLoop() }
        thread.name = "Halfwin Mouse Event Tap"
        return thread
    }()

    private var runLoop: CFRunLoop?
    private var runLoopPort: Port?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentMask: CGEventMask?
    private var scrollEnabled = false
    private var sideButtonsEnabled = false
    private var accessibilityGranted = false
    private var matchedButtons: Set<Int64> = []

    init() {
        thread.start()
        runLoopReady.wait()
    }

    func configure(scrollEnabled: Bool, sideButtonsEnabled: Bool, accessibilityGranted: Bool) {
        performOnEventThread { [weak self] in
            guard let self else { return }
            let permissionWasGranted = self.accessibilityGranted
            self.scrollEnabled = scrollEnabled
            self.sideButtonsEnabled = sideButtonsEnabled
            self.accessibilityGranted = accessibilityGranted
            if accessibilityGranted && !permissionWasGranted { self.stopTap() }
            self.reconcile()
        }
    }

    func stop() {
        performOnEventThread { [weak self] in
            guard let self else { return }
            self.accessibilityGranted = false
            self.matchedButtons.removeAll()
            self.stopTap()
            if let runLoop = self.runLoop { CFRunLoopStop(runLoop) }
        }
    }

    private func runEventLoop() {
        autoreleasepool {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            runLoopPort = port
            runLoop = CFRunLoopGetCurrent()
            runLoopReady.signal()
            CFRunLoopRun()
        }
    }

    private func performOnEventThread(_ action: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, action)
        CFRunLoopWakeUp(runLoop)
    }

    private func reconcile() {
        guard accessibilityGranted else {
            matchedButtons.removeAll()
            stopTap()
            return
        }
        let listenForButtons = sideButtonsEnabled || !matchedButtons.isEmpty
        guard scrollEnabled || listenForButtons else {
            stopTap()
            return
        }

        let mask = eventMask(scroll: scrollEnabled, buttons: listenForButtons)
        if let eventTap, currentMask == mask, CGEvent.tapIsEnabled(tap: eventTap) { return }
        // Deliberately stopped taps are removed, so a retained disabled tap needs recovery.
        stopTap()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }

        eventTap = tap
        runLoopSource = source
        currentMask = mask
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        currentMask = nil
    }

    private func eventMask(scroll: Bool, buttons: Bool) -> CGEventMask {
        var mask: CGEventMask = 0
        if scroll { mask |= CGEventMask(1) << CGEventType.scrollWheel.rawValue }
        if buttons {
            mask |= CGEventMask(1) << CGEventType.otherMouseDown.rawValue
            mask |= CGEventMask(1) << CGEventType.otherMouseUp.rawValue
        }
        return mask
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let permissionWasGranted = accessibilityGranted
            accessibilityGranted = Permissions.accessibilityGranted
            if !accessibilityGranted {
                matchedButtons.removeAll()
                stopTap()
            } else {
                if !permissionWasGranted { stopTap() }
                performOnEventThread { [weak self] in self?.reconcile() }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel, scrollEnabled,
           NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == true {
            reverseScrollDeltas(event)
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown || type == .otherMouseUp {
            return handleSideButton(type, event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func reverseScrollDeltas(_ event: CGEvent) {
        let line1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -line2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point2)
    }

    private func handleSideButton(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == 3 || button == 4 else { return Unmanaged.passUnretained(event) }

        if type == .otherMouseDown {
            guard sideButtonsEnabled,
                  let application = NSWorkspace.shared.frontmostApplication,
                  let bundleIdentifier = application.bundleIdentifier,
                  sideButtonShortcutBundleIDs.contains(bundleIdentifier) else {
                return Unmanaged.passUnretained(event)
            }
            if matchedButtons.contains(button) { return nil }
            guard postShortcut(for: button, to: application.processIdentifier) else {
                return Unmanaged.passUnretained(event)
            }
            matchedButtons.insert(button)
            return nil
        }

        guard matchedButtons.remove(button) != nil else { return Unmanaged.passUnretained(event) }
        if !sideButtonsEnabled && matchedButtons.isEmpty {
            performOnEventThread { [weak self] in self?.reconcile() }
        }
        return nil
    }

    private func postShortcut(for button: Int64, to processID: pid_t) -> Bool {
        let isBack = button == 3
        let keyCode = CGKeyCode(isBack ? kVK_ANSI_LeftBracket : kVK_ANSI_RightBracket)
        let unicode = Array((isBack ? "[" : "]").utf16)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        unicode.withUnsafeBufferPointer { characters in
            down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters.baseAddress)
            up.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters.baseAddress)
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }
}
