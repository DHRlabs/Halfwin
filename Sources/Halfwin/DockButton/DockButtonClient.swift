import CoreFoundation
import Foundation

enum DockButtonProtocol {
    enum Name {
        static let hostReady = Notification.Name("com.dhrlabs.dockstrip.v1.hostReady")
        static let discover = Notification.Name("com.dhrlabs.dockstrip.v1.discover")
        static let register = Notification.Name("com.dhrlabs.dockstrip.v1.register")
        static let update = Notification.Name("com.dhrlabs.dockstrip.v1.update")
        static let remove = Notification.Name("com.dhrlabs.dockstrip.v1.remove")
        static let hostAck = Notification.Name("com.dhrlabs.dockstrip.v1.hostAck")
        static let invoke = Notification.Name("com.dhrlabs.dockstrip.v1.invoke")
        static let result = Notification.Name("com.dhrlabs.dockstrip.v1.result")
        static let goodbye = Notification.Name("com.dhrlabs.dockstrip.v1.goodbye")
    }

    enum Key {
        static let protocolVersion = "protocol"
        static let hostSession = "hostSession"
        static let provider = "provider"
        static let providerSession = "providerSession"
        static let buttonID = "buttonID"
        static let presentation = "presentation"
        static let label = "label"
        static let tooltip = "tooltip"
        static let enabled = "enabled"
        static let toggled = "toggled"
        static let symbol = "symbol"
        static let requestID = "requestID"
        static let outcome = "outcome"
        static let leaseSeconds = "leaseSeconds"
    }

    static let version = 1
    static let providerID = "com.dhrlabs.halfwin"
    static let buttonID = "com.dhrlabs.halfwin.show-desktop"
    static let presentation = "desktopStrip"
    static let label = "Show desktop"
    static func buttonPayload(providerSession: String, enabled: Bool, toggled: Bool) -> [String: Any] {
        [
            Key.protocolVersion: version,
            Key.provider: providerID,
            Key.providerSession: providerSession,
            Key.buttonID: buttonID,
            Key.presentation: presentation,
            Key.label: label,
            Key.tooltip: toggled ? "Restore windows" : label,
            Key.enabled: enabled,
            Key.toggled: toggled
        ]
    }
}

@MainActor
final class DockButtonClient {
    private typealias Name = DockButtonProtocol.Name
    private typealias Key = DockButtonProtocol.Key

    private let center = DistributedNotificationCenter.default()
    private let providerSession = UUID().uuidString
    private let invoke: () -> Bool?
    private let isToggled: () -> Bool
    private let postMessage: (Notification.Name, [String: Any]) -> Void
    private let version = DockButtonProtocol.version
    private let provider = DockButtonProtocol.providerID
    private let buttonID = DockButtonProtocol.buttonID
    private var observers: [NSObjectProtocol] = []
    private var discoveryTimer: Timer?
    private var leaseTimer: Timer?
    private var hostSession: String?
    private var leaseDeadline: TimeInterval?
    private var handledRequests: [String: String] = [:]
    private var enabled = false
    private var registered = false
    private var toggled = false
    private var started = false
    private var fallbackVisible = false
    var onFallbackVisibilityChange: ((Bool) -> Void)?

    init(invoke: @escaping () -> Bool?, isToggled: @escaping () -> Bool,
         postMessage: ((Notification.Name, [String: Any]) -> Void)? = nil) {
        self.invoke = invoke
        self.isToggled = isToggled
        self.postMessage = postMessage ?? { name, userInfo in
            DistributedNotificationCenter.default().postNotificationName(
                name, object: nil, userInfo: userInfo, deliverImmediately: true
            )
        }
    }

    func start() {
        guard !started else { return }
        started = true
        for name in [Name.hostReady, Name.hostAck, Name.invoke, Name.goodbye] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.receive(note) }
            })
        }
        discover()
        if enabled {
            registerButton()
            scheduleDiscovery()
        } else {
            removeButton()
        }
        announceFallbackVisibility()
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            discover()
            if started { registerButton() }
            scheduleDiscovery()
        } else {
            discoveryTimer?.invalidate()
            discoveryTimer = nil
            leaseTimer?.invalidate()
            leaseTimer = nil
            leaseDeadline = nil
            hostSession = nil
            if started { removeButton() }
        }
        announceFallbackVisibility()
    }

    func setToggled(_ toggled: Bool) {
        guard self.toggled != toggled else { return }
        self.toggled = toggled
        if started, enabled, registered { post(Name.update, buttonPayload) }
    }

    func stop() {
        guard started else { return }
        post(Name.remove, [
            Key.protocolVersion: version,
            Key.provider: provider,
            Key.providerSession: providerSession,
            Key.buttonID: buttonID
        ])
        post(Name.goodbye, [Key.protocolVersion: version, Key.providerSession: providerSession])
        started = false
        registered = false
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        leaseTimer?.invalidate()
        leaseTimer = nil
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        enabled = false
        leaseDeadline = nil
        announceFallbackVisibility()
    }

    private var buttonPayload: [String: Any] {
        DockButtonProtocol.buttonPayload(providerSession: providerSession, enabled: enabled, toggled: toggled)
    }

    private func discover() {
        post(Name.discover, [
            Key.protocolVersion: version,
            Key.provider: provider,
            Key.providerSession: providerSession
        ])
    }

    private func registerButton() {
        guard enabled else { return }
        registered = true
        post(Name.register, buttonPayload)
    }

    private func removeButton() {
        registered = false
        post(Name.remove, [
            Key.protocolVersion: version,
            Key.provider: provider,
            Key.providerSession: providerSession,
            Key.buttonID: buttonID
        ])
    }

    private func scheduleDiscovery() {
        discoveryTimer?.invalidate()
        guard started, enabled else { return }
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.discover() }
        }
    }

    func receive(_ notification: Notification) {
        guard let info = notification.userInfo, Self.hasVersion(info) else { return }
        switch notification.name {
        case Name.hostReady:
            guard let session = Self.uuid(info[Key.hostSession]) else { return }
            if hostSession != session {
                hostSession = session
                leaseDeadline = nil
                leaseTimer?.invalidate()
                leaseTimer = nil
                announceFallbackVisibility()
            }
            if enabled { registerButton() }
            else { removeButton() }
        case Name.hostAck:
            guard enabled, registered,
                  Self.string(info[Key.provider]) == provider,
                  Self.string(info[Key.buttonID]) == buttonID,
                  let session = Self.uuid(info[Key.hostSession]), session == hostSession,
                  let seconds = Self.integer(info[Key.leaseSeconds]), (1...60).contains(seconds)
            else { return }
            leaseDeadline = ProcessInfo.processInfo.systemUptime + TimeInterval(seconds)
            announceFallbackVisibility()
            armLeaseTimer()
        case Name.invoke:
            receiveInvoke(info)
        case Name.goodbye:
            guard let session = Self.uuid(info[Key.hostSession]), session == hostSession else { return }
            hostSession = nil
            leaseDeadline = nil
            leaseTimer?.invalidate()
            leaseTimer = nil
            announceFallbackVisibility()
            if enabled { discover() }
        default:
            break
        }
    }

    private func receiveInvoke(_ info: [AnyHashable: Any]) {
        guard registered,
              Self.string(info[Key.provider]) == provider,
              Self.string(info[Key.providerSession]) == providerSession,
              let session = Self.uuid(info[Key.hostSession]), session == hostSession,
              Self.string(info[Key.buttonID]) == buttonID,
              let rawRequestID = Self.string(info[Key.requestID]),
              let requestUUID = UUID(uuidString: rawRequestID)
        else { return }

        let requestID = requestUUID.uuidString
        let outcome: String
        if let previous = handledRequests[requestID] {
            outcome = previous
        } else if let state = invoke() {
            setToggled(state)
            outcome = "ok"
            handledRequests[requestID] = outcome
        } else {
            outcome = "unavailable"
            handledRequests[requestID] = outcome
        }
        setToggled(isToggled())
        post(Name.result, [
            Key.protocolVersion: version,
            Key.provider: provider,
            Key.providerSession: providerSession,
            Key.buttonID: buttonID,
            Key.requestID: rawRequestID,
            Key.outcome: outcome,
            Key.toggled: toggled
        ])
    }

    private func armLeaseTimer() {
        leaseTimer?.invalidate()
        guard let leaseDeadline else { return }
        let timer = Timer(timeInterval: max(0, leaseDeadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireLease() }
        }
        leaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func expireLease() {
        guard let leaseDeadline else { return }
        if ProcessInfo.processInfo.systemUptime >= leaseDeadline {
            self.leaseDeadline = nil
            leaseTimer = nil
            announceFallbackVisibility()
            if enabled { discover() }
        } else {
            armLeaseTimer()
        }
    }

    private func announceFallbackVisibility() {
        let visible = enabled && leaseDeadline == nil
        guard visible != fallbackVisible else { return }
        fallbackVisible = visible
        onFallbackVisibilityChange?(visible)
    }

    private func post(_ name: Notification.Name, _ userInfo: [String: Any]) {
        postMessage(name, userInfo)
    }

    private static func hasVersion(_ info: [AnyHashable: Any]) -> Bool {
        integer(info[Key.protocolVersion]) == DockButtonProtocol.version
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    private static func uuid(_ value: Any?) -> String? {
        guard let value = string(value), let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite,
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        let result = value.intValue
        return Double(result) == value.doubleValue ? result : nil
    }
}
