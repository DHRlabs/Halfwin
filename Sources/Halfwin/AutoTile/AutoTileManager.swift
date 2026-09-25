import AppKit
import ApplicationServices
import Combine

final class AutoTileManager {
    private struct Display: Hashable {
        let number: UInt32
        let frame: CGRect

        init(_ screen: NSScreen) {
            number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            frame = screen.frame
        }
    }

    private struct AppObservation {
        let observer: AXObserver
        let application: AXUIElement
        let source: CFRunLoopSource
        var windows = Set<AXWindow>()
    }

    private struct WindowIdentity: Hashable {
        let bundleID: String
        let title: String
    }

    private struct Parking {
        let originalFrame: CGRect
        let display: Display
        let identity: WindowIdentity?
    }

    private struct ExpectedFrame {
        let frames: [CGRect]
    }

    private struct AppliedFrame {
        let target: CGRect
        let actual: CGRect
    }

    private let settings: AutoTileSettings
    private var enabled = false
    private var observers: [pid_t: AppObservation] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var settingsCancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var reflowTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowedKeys = Set<Int64>()
    private var windowsByDisplay: [Display: [AXWindow]] = [:]
    private var mainWindowByDisplay: [Display: AXWindow] = [:]
    private var mainInitialized = Set<Display>()
    private var scrollStartByDisplay: [Display: Int] = [:]
    private var activeCountByDisplay: [Display: Int] = [:]
    private var arrivalOrder: [AXWindow: Int] = [:]
    private var focusOrder: [AXWindow: Int] = [:]
    private var lastFocusedWindow: AXWindow?
    private var observedFocusedWindow: AXWindow?
    private var focusRevealPending = false
    private var userFloated = Set<AXWindow>()
    private var handPlaced = Set<AXWindow>()
    private var parked: [AXWindow: Parking] = [:]
    private var identities: [AXWindow: WindowIdentity] = [:]
    private var originalSizes: [AXWindow: CGSize] = [:]
    private var savedFramesByIdentity: [WindowIdentity: CGRect] = [:]
    private var expectedFrames: [AXWindow: ExpectedFrame] = [:]
    private var appliedFrames: [AXWindow: AppliedFrame] = [:]
    private var nextOrder = 0

    init(settings: AutoTileSettings) {
        self.settings = settings
        settings.$layout.sink { [weak self] _ in self?.scheduleReflow() }.store(in: &settingsCancellables)
        settings.$columnWidth.sink { [weak self] _ in self?.scheduleReflow() }.store(in: &settingsCancellables)
        settings.$gap.sink { [weak self] _ in self?.scheduleReflow() }.store(in: &settingsCancellables)
        settings.$modifier.sink { [weak self] _ in self?.refreshKeyboardTap() }.store(in: &settingsCancellables)
        settings.$alwaysFloatAppIDs.sink { [weak self] _ in self?.scheduleReflow() }.store(in: &settingsCancellables)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else {
            refreshPermission()
            return
        }
        self.enabled = enabled
        refreshPermission()
    }

    func refreshPermission() {
        guard enabled else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            stopObserving()
            restoreParkedWindows()
            return
        }
        guard Permissions.accessibilityGranted else {
            restoreParkedWindows()
            stopObserving()
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.refreshPermission()
                }
            }
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        startObserving()
    }

    func stop() {
        enabled = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopObserving()
        restoreParkedWindows()
    }

    func didSnap(window: AXWindow, action: SnapAction, screen: NSScreen) {
        didManuallyPlace(window)
    }

    func didManuallyPlace(_ window: AXWindow) {
        handPlaced.insert(window)
        userFloated.remove(window)
        removeFromManagedWindows(window)
        parked.removeValue(forKey: window)
        if let frame = window.frame { originalSizes[window] = frame.size }
        expectedFrames.removeValue(forKey: window)
        appliedFrames.removeValue(forKey: window)
        if enabled { scheduleReflow() }
    }

    private func startObserving() {
        addWorkspaceObservers()
        refreshKeyboardTap()
        scheduleReflow()
    }

    private func stopObserving() {
        reflowTimer?.invalidate()
        reflowTimer = nil
        removeWorkspaceObservers()
        stopKeyboardTap()
        for pid in Array(observers.keys) { removeObservation(for: pid) }
    }

    private func addWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                if notification.name == NSWorkspace.activeSpaceDidChangeNotification { self.restoreParkedWindows() }
                if notification.name == NSWorkspace.didTerminateApplicationNotification,
                   let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self.rememberParkedFrames(for: app)
                }
                if notification.name == NSWorkspace.didActivateApplicationNotification,
                   let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let focused = AXWindow.focusedWindow(of: app) {
                    self.noteFocus(focused, followFocus: true)
                }
                self.scheduleReflow()
            })
        }
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.restoreParkedWindows()
            self?.scheduleReflow()
        })
    }

    private func removeWorkspaceObservers() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func scheduleReflow() {
        guard enabled, Permissions.accessibilityGranted else { return }
        reflowTimer?.invalidate()
        reflowTimer = Timer.scheduledTimer(withTimeInterval: 0.075, repeats: false) { [weak self] _ in
            self?.reflowTimer = nil
            self?.reflow()
        }
    }

    private func reflow() {
        guard enabled, Permissions.accessibilityGranted else { return }
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        var appByPID: [pid_t: NSRunningApplication] = [:]
        var liveWindows = Set<AXWindow>()
        var readableProcesses = Set<pid_t>()
        for app in applications {
            appByPID[app.processIdentifier] = app
            guard let windows = AXWindow.standardWindowsIfReadable(of: app) else { continue }
            readableProcesses.insert(app.processIdentifier)
            liveWindows.formUnion(windows)
            for window in windows {
                if arrivalOrder[window] == nil {
                    arrivalOrder[window] = nextOrder
                    nextOrder += 1
                }
                if let bundleID = app.bundleIdentifier, let title = window.title {
                    identities[window] = WindowIdentity(bundleID: bundleID, title: title)
                }
                if let frame = window.frame, originalSizes[window] == nil { originalSizes[window] = frame.size }
                recoverUnexpectedParking(window, app: app)
            }
            updateObservation(for: app, windows: windows)
        }
        for pid in Array(observers.keys) where appByPID[pid] == nil { removeObservation(for: pid) }

        var candidates: [Display: [AXWindow]] = [:]
        let floatApps = Set(settings.alwaysFloatAppIDs)
        for screen in NSScreen.screens {
            let display = Display(screen)
            for choice in SnapWindowInventory.choices(on: screen, excluding: []) {
                let window = choice.window
                guard !choice.application.isHidden, let frame = window.frame,
                      (originalSizes[window] ?? frame.size).width >= 200,
                      (originalSizes[window] ?? frame.size).height >= 200,
                      !floatApps.contains(choice.application.bundleIdentifier ?? ""),
                      !window.isMinimized, !isFullScreen(window), isResizable(window) else { continue }
                if originalSizes[window] == nil { originalSizes[window] = frame.size }
                liveWindows.insert(window)
                if arrivalOrder[window] == nil {
                    arrivalOrder[window] = nextOrder
                    nextOrder += 1
                }
                if !handPlaced.contains(window), !userFloated.contains(window) {
                    insertManaged(window, on: display)
                    candidates[display, default: []].append(window)
                }
            }
        }

        let frontmost = AXWindow.focusedWindow()
        if let frontmost { noteFocus(frontmost) }
        let followFocus = focusRevealPending
        focusRevealPending = false
        cleanupGoneWindows(liveWindows: liveWindows, apps: appByPID, readableProcesses: readableProcesses)
        for screen in NSScreen.screens {
            let display = Display(screen)
            var active = candidates[display] ?? []
            for window in windowsByDisplay[display] ?? [] where parked[window] != nil {
                guard let app = appByPID[window.processIdentifier ?? -1], !app.isHidden,
                      !window.isMinimized, !isFullScreen(window), isVisibleOnCurrentSpace(window) else { continue }
                if !active.contains(window) && !handPlaced.contains(window) && !userFloated.contains(window) {
                    active.append(window)
                }
            }
            active = (windowsByDisplay[display] ?? []).filter { active.contains($0) }
            if followFocus, let frontmost, active.contains(frontmost) {
                active = revealFocusedWindow(frontmost, among: active, on: display, screen: screen)
            }
            switch settings.layout {
            case .columns: tileColumns(active, on: display, screen: screen)
            case .bigLeftStack: tileBigLeft(active, on: display, screen: screen, preferred: frontmost)
            }
        }
        pruneDeadState(liveWindows, readableProcesses: readableProcesses, apps: appByPID)
    }

    private func updateObservation(for app: NSRunningApplication, windows: [AXWindow]) {
        let pid = app.processIdentifier
        if observers[pid] == nil {
            var created: AXObserver?
            guard AXObserverCreate(pid, autoTileAXCallback, &created) == .success,
                  let observer = created else { return }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.1)
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            observers[pid] = AppObservation(observer: observer, application: application, source: source)
            addNotification(kAXWindowCreatedNotification, to: application, observer: observer)
            addNotification(kAXFocusedWindowChangedNotification, to: application, observer: observer)
        }
        guard var observation = observers[pid] else { return }
        let current = Set(windows)
        for window in current.subtracting(observation.windows) {
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                         kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification] {
                addNotification(name, to: window.element, observer: observation.observer)
            }
        }
        for window in observation.windows.subtracting(current) {
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                         kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification] {
                AXObserverRemoveNotification(observation.observer, window.element, name as CFString)
            }
        }
        observation.windows = current
        observers[pid] = observation
    }

    private func addNotification(_ name: String, to element: AXUIElement, observer: AXObserver) {
        _ = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
    }

    fileprivate func accessibilityChanged(_ element: AXUIElement, notification: String) {
        guard enabled else { return }
        if notification == kAXMovedNotification as String || notification == kAXResizedNotification as String {
            let window = AXWindow(element: element)
            if isExpectedFrame(window) { return }
            guard !userFloated.contains(window), !handPlaced.contains(window) else { return }
            if notification == kAXResizedNotification as String, let frame = window.frame {
                originalSizes[window] = frame.size
            }
            handPlaced.insert(window)
            removeFromManagedWindows(window)
            parked.removeValue(forKey: window)
            expectedFrames.removeValue(forKey: window)
            appliedFrames.removeValue(forKey: window)
        } else if notification == kAXUIElementDestroyedNotification as String {
            let window = AXWindow(element: element)
            rememberParkedFrame(for: window)
            removeAllState(for: window)
        } else if notification == kAXFocusedWindowChangedNotification as String,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == AXWindow(element: element).processIdentifier }),
                  let focused = AXWindow.focusedWindow(of: app) {
            noteFocus(focused, followFocus: true)
        }
        scheduleReflow()
    }

    private func isExpectedFrame(_ window: AXWindow) -> Bool {
        guard let expected = expectedFrames[window] else { return false }
        guard let frame = window.frame else { return false }
        guard expected.frames.contains(where: { SnapGeometry.isClose(frame, $0, tolerance: 5) }) else {
            expectedFrames.removeValue(forKey: window)
            return false
        }
        return true
    }

    private func isFullScreen(_ window: AXWindow) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window.element, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func isResizable(_ window: AXWindow) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window.element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private func insertManaged(_ window: AXWindow, on display: Display) {
        for key in Array(windowsByDisplay.keys) where key != display {
            windowsByDisplay[key]?.removeAll { $0 == window }
            if mainWindowByDisplay[key] == window { mainWindowByDisplay.removeValue(forKey: key) }
        }
        guard !(windowsByDisplay[display] ?? []).contains(window) else { return }
        var windows = windowsByDisplay[display, default: []]
        if let order = arrivalOrder[window], let index = windows.firstIndex(where: { (arrivalOrder[$0] ?? Int.max) > order }) {
            windows.insert(window, at: index)
        } else {
            windows.append(window)
        }
        windowsByDisplay[display] = windows
    }

    private func removeFromManagedWindows(_ window: AXWindow) {
        for display in Array(windowsByDisplay.keys) {
            windowsByDisplay[display]?.removeAll { $0 == window }
            if mainWindowByDisplay[display] == window { mainWindowByDisplay.removeValue(forKey: display) }
        }
    }

    private func removeAllState(for window: AXWindow) {
        removeFromManagedWindows(window)
        arrivalOrder.removeValue(forKey: window)
        focusOrder.removeValue(forKey: window)
        if lastFocusedWindow == window { lastFocusedWindow = nil }
        identities.removeValue(forKey: window)
        originalSizes.removeValue(forKey: window)
        userFloated.remove(window)
        handPlaced.remove(window)
        expectedFrames.removeValue(forKey: window)
        appliedFrames.removeValue(forKey: window)
        parked.removeValue(forKey: window)
    }

    private func cleanupGoneWindows(liveWindows: Set<AXWindow>, apps: [pid_t: NSRunningApplication], readableProcesses: Set<pid_t>) {
        for window in windowsByDisplay.values.flatMap({ $0 }) {
            guard let pid = window.processIdentifier else { removeAllState(for: window); continue }
            if apps[pid] != nil && !readableProcesses.contains(pid) { continue }
            guard liveWindows.contains(window) else {
                rememberParkedFrame(for: window)
                removeAllState(for: window)
                continue
            }
            guard let app = apps[window.processIdentifier ?? -1] else { continue }
            if parked[window] != nil, settings.alwaysFloatAppIDs.contains(app.bundleIdentifier ?? "") {
                restoreParked(window)
                removeFromManagedWindows(window)
                continue
            }
            guard parked[window] == nil, !app.isHidden, !window.isMinimized else { continue }
            guard let frame = window.frame,
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
                  let bundleID = app.bundleIdentifier,
                  !settings.alwaysFloatAppIDs.contains(bundleID), !isFullScreen(window), isResizable(window) else {
                removeFromManagedWindows(window)
                continue
            }
            let originalSize = originalSizes[window] ?? frame.size
            guard originalSize.width >= 200, originalSize.height >= 200 else {
                removeFromManagedWindows(window)
                continue
            }
            if SnapWindowInventory.isOnCurrentSpaceIfReadable(window, on: screen) == false {
                removeFromManagedWindows(window)
            }
        }
        for window in Array(handPlaced) where isGone(window, apps: apps, readableProcesses: readableProcesses, liveWindows: liveWindows) {
            handPlaced.remove(window)
        }
        for window in Array(userFloated) where isGone(window, apps: apps, readableProcesses: readableProcesses, liveWindows: liveWindows) {
            userFloated.remove(window)
        }
    }

    private func isGone(_ window: AXWindow, apps: [pid_t: NSRunningApplication], readableProcesses: Set<pid_t>, liveWindows: Set<AXWindow>) -> Bool {
        guard let pid = window.processIdentifier else { return true }
        return apps[pid] == nil || readableProcesses.contains(pid) && !liveWindows.contains(window)
    }

    private func pruneDeadState(_ liveWindows: Set<AXWindow>, readableProcesses: Set<pid_t>, apps: [pid_t: NSRunningApplication]) {
        for window in Array(arrivalOrder.keys) where isGone(window, apps: apps, readableProcesses: readableProcesses, liveWindows: liveWindows) {
            removeAllState(for: window)
        }
        for display in Array(windowsByDisplay.keys) where windowsByDisplay[display]?.isEmpty == true {
            windowsByDisplay.removeValue(forKey: display)
            mainWindowByDisplay.removeValue(forKey: display)
            mainInitialized.remove(display)
            scrollStartByDisplay.removeValue(forKey: display)
            activeCountByDisplay.removeValue(forKey: display)
        }
    }

    private func noteFocus(_ window: AXWindow, followFocus: Bool = false) {
        focusOrder[window] = nextOrder
        nextOrder += 1
        if observedFocusedWindow != window || followFocus { focusRevealPending = true }
        observedFocusedWindow = window
        if window.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           AXWindow.subrole(of: window.element) == kAXStandardWindowSubrole {
            lastFocusedWindow = window
        }
    }

    private func orderedForBig(_ windows: [AXWindow], on display: Display, preferred: AXWindow?) -> [AXWindow] {
        guard !windows.isEmpty else { return [] }
        if let main = mainWindowByDisplay[display], windows.contains(main) {
            return [main] + windows.filter { $0 != main }
        }
        if let main = mainWindowByDisplay[display], (windowsByDisplay[display] ?? []).contains(main) {
            let temporary = windows[0]
            return [temporary] + windows.filter { $0 != temporary }
        }
        let main = mainInitialized.contains(display) ? windows[0] :
            preferred.flatMap { windows.contains($0) ? $0 : nil } ?? windows.max(by: {
                (focusOrder[$0] ?? -1) < (focusOrder[$1] ?? -1)
            }) ?? windows[0]
        mainWindowByDisplay[display] = main
        mainInitialized.insert(display)
        return [main] + windows.filter { $0 != main }
    }

    private func tileBigLeft(_ windows: [AXWindow], on display: Display, screen: NSScreen, preferred: AXWindow?) {
        guard !windows.isEmpty else { return }
        let gap = CGFloat(settings.gap)
        let area = screen.visibleFrame.insetBy(dx: gap, dy: gap)
        guard area.width >= 200, area.height >= 200 else { return }
        let ordered = orderedForBig(windows, on: display, preferred: preferred)
        let leftWidth = floor(max(0, area.width - gap) * 2 / 3)
        let rightWidth = area.width - leftWidth - gap
        let stackCapacity = leftWidth >= 200 && rightWidth >= 200
            ? Int(floor((area.height + gap) / (200 + gap))) : 0
        let visibleCount = min(ordered.count, 1 + stackCapacity)
        let targets: [CGRect]
        if visibleCount == 1 {
            targets = [area]
        } else {
            let stackHeight = (area.height - gap * CGFloat(visibleCount - 2)) / CGFloat(visibleCount - 1)
            targets = [
                CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
            ] + (1..<visibleCount).map { index in
                let slot = index - 1
                return CGRect(x: area.minX + leftWidth + gap,
                              y: area.maxY - CGFloat(slot + 1) * stackHeight - CGFloat(slot) * gap,
                              width: rightWidth, height: stackHeight)
            }
        }
        let extras = Array(ordered.dropFirst(visibleCount))
        let corner: ParkingCorner?
        if !extras.isEmpty {
            let size = CGSize(width: ordered.compactMap { $0.frame?.width }.max() ?? 0,
                              height: ordered.compactMap { $0.frame?.height }.max() ?? 0)
            corner = parkingCorner(on: screen, size: size)
            if corner == nil {
                tileEqualColumns(ordered, in: area, gap: gap)
                return
            }
        } else {
            corner = nil
        }
        for (window, target) in zip(ordered, targets) { place(window, at: target, clearParking: true) }
        if let corner { for window in extras { parkWindow(window, in: corner, display: display) } }
    }

    private func tileColumns(_ windows: [AXWindow], on display: Display, screen: NSScreen) {
        activeCountByDisplay[display] = windows.count
        guard !windows.isEmpty else { return }
        let gap = CGFloat(settings.gap)
        let area = screen.visibleFrame.insetBy(dx: gap, dy: gap)
        let capacity = columnCapacity(in: screen)
        guard capacity > 0, area.height >= 200 else { return }
        let width = max(0, (area.width - gap * CGFloat(capacity - 1)) * CGFloat(settings.columnWidth))
        let visibleCount = min(windows.count, capacity)
        let columnWidth = windows.count < capacity
            ? (area.width - gap * CGFloat(visibleCount - 1)) / CGFloat(visibleCount)
            : width
        let parkingSize = CGSize(width: windows.map { $0.frame?.width ?? 0 }.max() ?? 0,
                                 height: windows.map { $0.frame?.height ?? 0 }.max() ?? 0)
        let corner = parkingCorner(on: screen, size: parkingSize)
        if windows.count > capacity, corner == nil {
            scrollStartByDisplay[display] = 0
            tileEqualColumns(windows, in: area, gap: gap)
            return
        }
        let maxStart = max(0, windows.count - capacity)
        let start = min(max(scrollStartByDisplay[display, default: 0], 0), maxStart)
        scrollStartByDisplay[display] = start
        let end = min(start + capacity, windows.count)
        for index in windows.indices {
            let window = windows[index]
            if index >= start && index < end {
                let visibleIndex = index - start
                place(window, at: CGRect(x: area.minX + CGFloat(visibleIndex) * (columnWidth + gap), y: area.minY,
                                         width: columnWidth, height: area.height), clearParking: true)
            } else if let corner {
                parkWindow(window, in: corner, display: display)
            } else if parked[window] != nil {
                restoreParked(window)
            }
        }
    }

    private func tileEqualColumns(_ windows: [AXWindow], in area: CGRect, gap: CGFloat) {
        let count = CGFloat(windows.count)
        let width = max(0, (area.width - gap * (count - 1)) / count)
        for (index, window) in windows.enumerated() {
            place(window, at: CGRect(x: area.minX + CGFloat(index) * (width + gap), y: area.minY,
                                     width: width, height: area.height), clearParking: true)
        }
    }

    private enum ParkingCorner: Equatable { case bottomLeft, bottomRight, topLeft, topRight }

    private func parkingCorner(on screen: NSScreen, size: CGSize) -> ParkingCorner? {
        for corner in [ParkingCorner.bottomLeft, .bottomRight, .topLeft, .topRight] {
            let parkedFrame = parkingFrame(size: size, corner: corner, usableFrame: screen.visibleFrame)
            if !NSScreen.screens.contains(where: { $0 != screen && $0.frame.intersects(parkedFrame) }) { return corner }
        }
        return nil
    }

    private func parkWindow(_ window: AXWindow, in corner: ParkingCorner, display: Display) {
        guard let frame = window.frame else { return }
        if parked[window] == nil {
            parked[window] = Parking(originalFrame: frame, display: display, identity: identities[window])
        }
        let usableFrame = NSScreen.screens.first(where: { Display($0) == display })?.visibleFrame ?? display.frame
        place(window, at: parkingFrame(size: frame.size, corner: corner, usableFrame: usableFrame))
    }

    private func parkingFrame(size: CGSize, corner: ParkingCorner, usableFrame: CGRect) -> CGRect {
        let sliver: CGFloat = 18
        let x = corner == .bottomLeft || corner == .topLeft
            ? usableFrame.minX - size.width + sliver : usableFrame.maxX - sliver
        let y = corner == .bottomLeft || corner == .bottomRight
            ? usableFrame.minY - size.height + sliver : usableFrame.maxY - sliver
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func parkingCorner(of frame: CGRect, on screen: NSScreen) -> ParkingCorner? {
        let bounds = screen.visibleFrame
        let sliver: CGFloat = 23
        let visible = frame.intersection(bounds)
        guard frame.width > 0, frame.height > 0,
              visible.width * visible.height <= frame.width * frame.height * 0.2 else { return nil }
        if frame.minX < bounds.minX, frame.maxX <= bounds.minX + sliver,
           frame.minY < bounds.minY, frame.maxY <= bounds.minY + sliver { return .bottomLeft }
        if frame.minX < bounds.minX, frame.maxX <= bounds.minX + sliver,
           frame.minY >= bounds.maxY - sliver, frame.maxY > bounds.maxY { return .topLeft }
        if frame.minX >= bounds.maxX - sliver, frame.maxX > bounds.maxX,
           frame.minY < bounds.minY, frame.maxY <= bounds.minY + sliver { return .bottomRight }
        if frame.minX >= bounds.maxX - sliver, frame.maxX > bounds.maxX,
           frame.minY >= bounds.maxY - sliver, frame.maxY > bounds.maxY { return .topRight }
        return nil
    }

    private func place(_ window: AXWindow, at target: CGRect, clearParking: Bool = false) {
        guard let current = window.frame else { return }
        if SnapGeometry.isClose(current, target) {
            if clearParking { parked.removeValue(forKey: window) }
            return
        }
        if let applied = appliedFrames[window], SnapGeometry.isClose(applied.target, target),
           SnapGeometry.isClose(current, applied.actual, tolerance: 2) { return }
        let transition = CGRect(origin: current.origin, size: target.size)
        expectedFrames[window] = ExpectedFrame(frames: [transition, target])
        window.setFrame(target)
        if let readBack = window.frame {
            expectedFrames[window] = ExpectedFrame(frames: [transition, target, readBack])
            if !SnapGeometry.isClose(readBack, target, tolerance: 5) {
                appliedFrames[window] = AppliedFrame(target: target, actual: readBack)
            } else {
                appliedFrames.removeValue(forKey: window)
                if clearParking, parked[window] != nil { parked.removeValue(forKey: window) }
            }
        }
    }

    private func revealFocusedWindow(_ window: AXWindow, among windows: [AXWindow], on display: Display, screen: NSScreen) -> [AXWindow] {
        guard let index = windows.firstIndex(of: window) else { return windows }
        if settings.layout == .columns {
            let capacity = columnCapacity(in: screen)
            guard capacity > 0 else { return windows }
            let start = scrollStartByDisplay[display, default: 0]
            if index < start { scrollStartByDisplay[display] = index }
            else if index >= start + capacity { scrollStartByDisplay[display] = index - capacity + 1 }
            return windows
        } else {
            let ordered = orderedForBig(windows, on: display, preferred: nil)
            let gap = CGFloat(settings.gap)
            let area = screen.visibleFrame.insetBy(dx: gap, dy: gap)
            let leftWidth = floor(max(0, area.width - gap) * 2 / 3)
            let rightWidth = area.width - leftWidth - gap
            let stackCapacity = leftWidth >= 200 && rightWidth >= 200
                ? Int(floor((area.height + gap) / (200 + gap))) : 0
            let capacity = min(ordered.count, 1 + stackCapacity)
            guard let focusedIndex = ordered.firstIndex(of: window), focusedIndex >= capacity, capacity > 0 else { return windows }
            var reordered = ordered
            reordered.swapAt(focusedIndex, capacity - 1)
            if capacity == 1 { mainWindowByDisplay[display] = window }
            windowsByDisplay[display] = reordered
            return reordered
        }
    }

    private func restoreParkedWindows() {
        for (window, _) in Array(parked) { restoreParked(window) }
        guard Permissions.accessibilityGranted else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            guard let windows = AXWindow.standardWindowsIfReadable(of: app) else { continue }
            for window in windows {
                guard parked[window] == nil, let frame = window.frame,
                      let screen = NSScreen.screens.first(where: { parkingCorner(of: frame, on: $0) != nil }) else { continue }
                let identity = app.bundleIdentifier.flatMap { bundleID in
                    window.title.map { WindowIdentity(bundleID: bundleID, title: $0) }
                }
                let target = identity.flatMap { savedFramesByIdentity.removeValue(forKey: $0) }
                    .map { clamped($0, to: screen.visibleFrame) } ?? centered(frame, in: screen.visibleFrame)
                appliedFrames.removeValue(forKey: window)
                place(window, at: target)
            }
        }
    }

    private func recoverUnexpectedParking(_ window: AXWindow, app: NSRunningApplication) {
        guard parked[window] == nil, let frame = window.frame,
              let screen = NSScreen.screens.first(where: { parkingCorner(of: frame, on: $0) != nil }) else { return }
        let identity = app.bundleIdentifier.flatMap { bundleID in
            window.title.map { WindowIdentity(bundleID: bundleID, title: $0) }
        }
        let target = identity.flatMap { savedFramesByIdentity.removeValue(forKey: $0) }
            .map { clamped($0, to: screen.visibleFrame) } ?? centered(frame, in: screen.visibleFrame)
        appliedFrames.removeValue(forKey: window)
        place(window, at: target)
        if let recoveredFrame = window.frame, !SnapGeometry.isClose(frame, recoveredFrame) { scheduleReflow() }
    }

    private func rememberParkedFrames(for app: NSRunningApplication) {
        for (window, parking) in parked where window.processIdentifier == app.processIdentifier {
            if let identity = parking.identity ?? identities[window] {
                savedFramesByIdentity[identity] = parking.originalFrame
            }
        }
    }

    private func rememberParkedFrame(for window: AXWindow) {
        guard let parking = parked[window], let identity = parking.identity ?? identities[window] else { return }
        savedFramesByIdentity[identity] = parking.originalFrame
    }

    private func restoreParked(_ window: AXWindow) {
        guard let parking = parked[window] else { return }
        let screen = NSScreen.screens.first(where: { Display($0) == parking.display }) ?? NSScreen.screens.min {
            distance(from: parking.display.frame, to: $0.frame) < distance(from: parking.display.frame, to: $1.frame)
        }
        let bounds = screen?.visibleFrame ?? parking.display.frame
        let target = clamped(parking.originalFrame, to: bounds)
        appliedFrames.removeValue(forKey: window)
        place(window, at: target)
        if let frame = window.frame, SnapGeometry.isClose(frame, target, tolerance: 5) {
            parked.removeValue(forKey: window)
        }
    }

    private func distance(from first: CGRect, to second: CGRect) -> CGFloat {
        hypot(first.midX - second.midX, first.midY - second.midY)
    }

    private func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    private func centered(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        let fitted = clamped(frame, to: bounds)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func columnCapacity(in screen: NSScreen) -> Int {
        let gap = CGFloat(settings.gap)
        let area = screen.visibleFrame.insetBy(dx: gap, dy: gap)
        let fraction = CGFloat(settings.columnWidth)
        guard area.height >= 200 else { return 0 }
        let configuredCapacity = max(1, Int(floor(1 / fraction)))
        for count in stride(from: configuredCapacity, through: 1, by: -1) {
            if (area.width - gap * CGFloat(count - 1)) * fraction >= 200 { return count }
        }
        return 0
    }

    private func isVisibleOnCurrentSpace(_ window: AXWindow) -> Bool {
        // SnapWindowInventory selects by center; a parked window's center is off-screen.
        guard let frame = window.frame, let pid = window.processIdentifier,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let title = window.title
        return infos.contains { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  SnapGeometry.isClose(quartzFrame.axFlipped, frame, tolerance: 8) else { return false }
            let visibleTitle = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return title == nil || visibleTitle == nil || title == visibleTitle
        }
    }

    private func displayContaining(_ window: AXWindow) -> Display? {
        if let display = windowsByDisplay.first(where: { $0.value.contains(window) })?.key { return display }
        guard let frame = window.frame,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { return nil }
        return Display(screen)
    }

    private func handleFocusedKey(_ keyCode: Int64, swap: Bool = false, scroll: Bool = false) {
        let window = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastFocusedWindow : AXWindow.focusedWindow()
        guard let window else { return }
        let display = displayContaining(window)
        if scroll, let display, settings.layout == .columns {
            let direction = keyCode == 123 ? -1 : 1
            let count = activeCountByDisplay[display, default: 0]
            let capacity = NSScreen.screens.first(where: { Display($0) == display }).map(columnCapacity(in:)) ?? 0
            scrollStartByDisplay[display] = min(max(scrollStartByDisplay[display, default: 0] + direction, 0), max(0, count - capacity))
            scheduleReflow()
        } else if swap, let display, let windows = windowsByDisplay[display], windows.contains(window) {
            swapNeighbor(window, direction: keyCode == 123 ? -1 : 1, on: display)
            scheduleReflow()
        } else if !swap && !scroll {
            toggleFloat(window)
        }
    }

    private func swapNeighbor(_ window: AXWindow, direction: Int, on display: Display) {
        var order = windowsByDisplay[display] ?? []
        let presentation = settings.layout == .bigLeftStack ? orderedForBig(order, on: display, preferred: nil) : order
        guard let index = presentation.firstIndex(of: window) else { return }
        if settings.layout == .bigLeftStack, direction < 0, index > 0 {
            mainWindowByDisplay[display] = window
            windowsByDisplay[display] = presentation
            return
        }
        let neighbor = index + direction
        guard presentation.indices.contains(neighbor) else { return }
        order = presentation
        order.swapAt(index, neighbor)
        if settings.layout == .bigLeftStack { mainWindowByDisplay[display] = order.first }
        windowsByDisplay[display] = order
    }

    private func toggleFloat(_ window: AXWindow) {
        guard let app = window.processIdentifier.flatMap({ pid in NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid } }),
              let frame = window.frame,
              app.activationPolicy == .regular, !app.isHidden, !window.isMinimized,
              AXWindow.subrole(of: window.element) == kAXStandardWindowSubrole,
              (originalSizes[window] ?? frame.size).width >= 200,
              (originalSizes[window] ?? frame.size).height >= 200,
              !isFullScreen(window), isResizable(window),
              !settings.alwaysFloatAppIDs.contains(app.bundleIdentifier ?? "") else { return }
        let isManaged = windowsByDisplay.values.contains { $0.contains(window) }
        guard let display = displayContaining(window) else { return }
        if !isManaged && parked[window] == nil {
            guard let screen = NSScreen.screens.first(where: { Display($0) == display }),
                  SnapWindowInventory.isOnCurrentSpaceIfReadable(window, on: screen) != false else { return }
        }

        if isManaged && !userFloated.contains(window) && !handPlaced.contains(window) {
            userFloated.insert(window)
            removeFromManagedWindows(window)
            if parked[window] != nil { restoreParked(window) }
        } else {
            handPlaced.remove(window)
            userFloated.remove(window)
            insertManaged(window, on: display)
        }
        scheduleReflow()
    }

    private func refreshKeyboardTap() {
        guard enabled, Permissions.accessibilityGranted, settings.modifier != .off else {
            stopKeyboardTap()
            return
        }
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: autoTileEventTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopKeyboardTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        swallowedKeys.removeAll()
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedKeys.removeAll()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled, Permissions.accessibilityGranted else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowedKeys.remove(keyCode) == nil ? Unmanaged.passUnretained(event) : nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        var required: CGEventFlags = [.maskControl, .maskAlternate]
        if settings.modifier == .controlOptionCommand { required.insert(.maskCommand) }
        let held = event.flags.intersection(modifiers)
        let swap = keyCode == 123 || keyCode == 124 ? held == required.union(.maskShift) : false
        let scroll = (keyCode == 123 || keyCode == 124) && held == required && settings.layout == .columns
        let toggle = keyCode == 3 && held == required
        guard swap || scroll || toggle else { return Unmanaged.passUnretained(event) }
        swallowedKeys.insert(keyCode)
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 || swap || scroll {
            DispatchQueue.main.async { [weak self] in self?.handleFocusedKey(keyCode, swap: swap, scroll: scroll) }
        }
        return nil
    }

    private func removeObservation(for pid: pid_t) {
        guard let observation = observers.removeValue(forKey: pid) else { return }
        removeNotifications(from: observation)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), observation.source, .commonModes)
    }

    private func removeNotifications(from observation: AppObservation) {
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverRemoveNotification(observation.observer, observation.application, name as CFString)
        }
        for window in observation.windows {
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                         kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification] {
                AXObserverRemoveNotification(observation.observer, window.element, name as CFString)
            }
        }
    }
}

private let autoTileAXCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let manager = Unmanaged<AutoTileManager>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async { manager.accessibilityChanged(element, notification: notification as String) }
}

private let autoTileEventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<AutoTileManager>.fromOpaque(refcon).takeUnretainedValue().handleTap(type: type, event: event)
}
