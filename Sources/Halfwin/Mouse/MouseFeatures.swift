import AppKit
import Carbon.HIToolbox
import CoreGraphics
import IOKit.hid
import IOKit.hidsystem

final class MouseFeatures {
    let linearPointer = FeatureSwitch(key: "mouse.linear-pointer", title: "Linear pointer", defaultOn: true)
    let windowsScrollDirection = FeatureSwitch(key: "mouse.windows-scroll-direction", title: "Windows scroll direction", defaultOn: true)
    let sideButtonsBackForward = FeatureSwitch(key: "mouse.side-buttons-back-forward", title: "Side buttons back/forward", defaultOn: true)

    private let pointer = LinearPointerController()
    private let eventTap = MouseEventTap()
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init() {
        linearPointer.onChange = { [weak self] enabled in self?.pointer.setEnabled(enabled) }
        windowsScrollDirection.onChange = { [weak self] _ in self?.refreshPermission() }
        sideButtonsBackForward.onChange = { [weak self] _ in self?.refreshPermission() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPermission() }
    }

    func start() {
        linearPointer.start()
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
        pointer.setEnabled(false)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }
}

private final class LinearPointerController {
    private struct SavedProperty {
        let service: IOHIDServiceClient
        let value: CFTypeRef
    }

    private static let linearAccelerationKey = kIOHIDUseLinearScalingMouseAccelerationKey as CFString
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var savedProperties: [SavedProperty] = []
    private var isEnabled = false
    private var deviceTimer: Timer?

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            applyToConnectedMice()
            // ponytail: discovery can lag five seconds; use IOHID service notifications if faster hot-plug updates matter.
            deviceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.applyToConnectedMice()
            }
        } else {
            deviceTimer?.invalidate()
            deviceTimer = nil
            restoreProperties()
        }
    }

    private func applyToConnectedMice() {
        guard let services = IOHIDEventSystemClientCopyServices(client) else { return }
        for index in 0..<CFArrayGetCount(services) {
            guard let rawService = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = Unmanaged<IOHIDServiceClient>.fromOpaque(rawService).takeUnretainedValue()
            guard isExternalMouse(service), !savedProperties.contains(where: { CFEqual($0.service, service) }) else { continue }
            guard let previous = IOHIDServiceClientCopyProperty(service, Self.linearAccelerationKey),
                  IOHIDServiceClientSetProperty(service, Self.linearAccelerationKey, kCFBooleanTrue) else { continue }
            savedProperties.append(SavedProperty(service: service, value: previous))
        }
    }

    private func restoreProperties() {
        for saved in savedProperties {
            if !IOHIDServiceClientSetProperty(saved.service, Self.linearAccelerationKey, saved.value) {
                NSLog("Halfwin: could not restore a mouse acceleration property")
            }
        }
        savedProperties.removeAll()
    }

    private func isExternalMouse(_ service: IOHIDServiceClient) -> Bool {
        guard let usagePage = IOHIDServiceClientCopyProperty(service, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber,
              let usage = IOHIDServiceClientCopyProperty(service, kIOHIDPrimaryUsageKey as CFString) as? NSNumber,
              let builtIn = IOHIDServiceClientCopyProperty(service, kIOHIDBuiltInKey as CFString) as? NSNumber else { return false }
        return usagePage.uint32Value == UInt32(kHIDPage_GenericDesktop) &&
            usage.uint32Value == UInt32(kHIDUsage_GD_Mouse) && !builtIn.boolValue &&
            IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
    }
}

private final class MouseEventTap {
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<MouseEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type, event)
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentMask: CGEventMask?
    private var scrollEnabled = false
    private var sideButtonsEnabled = false
    private var accessibilityGranted = false
    private var matchedButtons: [Int64: pid_t] = [:]

    func configure(scrollEnabled: Bool, sideButtonsEnabled: Bool, accessibilityGranted: Bool) {
        self.scrollEnabled = scrollEnabled
        self.sideButtonsEnabled = sideButtonsEnabled
        self.accessibilityGranted = accessibilityGranted
        reconcile()
    }

    func stop() {
        accessibilityGranted = false
        matchedButtons.removeAll()
        stopTap()
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
        guard eventTap == nil || currentMask != mask else { return }
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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
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
            accessibilityGranted = Permissions.accessibilityGranted
            if !accessibilityGranted { matchedButtons.removeAll(); stopTap() }
            else if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel, scrollEnabled, UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection") {
            reverseScrollDeltas(event)
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown || type == .otherMouseUp {
            return handleSideButton(type, event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func reverseScrollDeltas(_ event: CGEvent) {
        for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                      .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
            event.setIntegerValueField(field, value: -event.getIntegerValueField(field))
        }
        for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
            event.setDoubleValueField(field, value: -event.getDoubleValueField(field))
        }
    }

    private func handleSideButton(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == 3 || button == 4 else { return Unmanaged.passUnretained(event) }

        if type == .otherMouseDown {
            guard sideButtonsEnabled else { return Unmanaged.passUnretained(event) }
            if matchedButtons[button] != nil { return nil }
            guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  postShortcut(for: button, to: processID) else { return Unmanaged.passUnretained(event) }
            matchedButtons[button] = processID
            return nil
        }

        guard matchedButtons.removeValue(forKey: button) != nil else { return Unmanaged.passUnretained(event) }
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
        return nil
    }

    private func postShortcut(for button: Int64, to processID: pid_t) -> Bool {
        let keyCode = CGKeyCode(button == 3 ? kVK_ANSI_LeftBracket : kVK_ANSI_RightBracket)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }
}
