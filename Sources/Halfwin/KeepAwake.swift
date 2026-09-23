import Cocoa

final class KeepAwake {
    static let durations: [(String, Int)] = [
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
        ("2 hours", 2 * 60 * 60),
        ("5 hours", 5 * 60 * 60),
    ]

    var onChange: (() -> Void)?

    private var caffeinateProcess: Process?
    private var endDate: Date?
    private var lidEndDate: Date?
    private var tickTimer: Timer?
    private var lidWatchTimer: Timer?
    private(set) var lidEnabled = false

    var isActive: Bool { caffeinateProcess?.isRunning ?? false }
    var isAwake: Bool { isActive || lidEnabled }
    var isPlainAwake: Bool { isActive && endDate == nil && !lidEnabled }
    var isLidAwakeIndefinitely: Bool { lidEnabled && lidEndDate == nil }
    var activeDuration: Int? { isActive && endDate != nil && !lidEnabled ? nearest(endDate) : nil }
    var activeLidDuration: Int? { lidEnabled && lidEndDate != nil ? nearest(lidEndDate) : nil }

    var statusTitle: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if lidEnabled {
            return lidEndDate.map { "Awake, lid closed, until \(formatter.string(from: $0))" }
                ?? "Awake — even with lid closed"
        }
        if isActive {
            return endDate.map { "Awake until \(formatter.string(from: $0))" } ?? "Awake — indefinitely"
        }
        return "Off — Mac can sleep"
    }

    func refresh() {
        let nowLidOn = lidOn()
        if lidEnabled && !nowLidOn && lidEndDate != nil && endDate == nil {
            // Lid revert fired (pmset flag cleared itself): the caffeinate the
            // lid session started has no timeout of its own, so stop it here.
            stopCaffeinate()
        }
        lidEnabled = nowLidOn
        if !lidEnabled { lidEndDate = nil }
        if lidEnabled && !isActive { startCaffeinate(seconds: nil) }
        if lidEnabled { startLidWatch() }
        else { lidWatchTimer?.invalidate(); lidWatchTimer = nil }
        onChange?()
    }

    func toggle() {
        refresh()
        if lidEnabled {
            if runPrivileged("pkill -f HALFWIN_LID_REVERT 2>/dev/null; pmset -a disablesleep 0") {
                lidEndDate = nil
                if !isActive { startCaffeinate(seconds: nil) }
            }
        } else if isActive && endDate == nil {
            stopCaffeinate()
        } else {
            startCaffeinate(seconds: nil)
        }
        refresh()
    }

    func startTimed(_ seconds: Int) {
        startCaffeinate(seconds: seconds)
        refresh()
    }

    func toggleLid() {
        refresh()
        if lidEnabled { disableLid() }
        else if confirmLid(nil) { enableLid(seconds: nil) }
    }

    func startLidTimed(_ seconds: Int) {
        refresh()
        let label = Self.durations.first { $0.1 == seconds }?.0 ?? "a while"
        if confirmLid(label) { enableLid(seconds: seconds) }
    }

    func stop() {
        tickTimer?.invalidate()
        lidWatchTimer?.invalidate()
        tickTimer = nil
        lidWatchTimer = nil
        stopCaffeinate()
    }

    private func startCaffeinate(seconds: Int?) {
        stopCaffeinate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var arguments = ["-d", "-i", "-s", "-u"]
        if let seconds {
            arguments += ["-t", String(seconds)]
        } else {
            arguments += ["-w", String(ProcessInfo.processInfo.processIdentifier)]
        }
        process.arguments = arguments
        process.terminationHandler = { [weak self] finishedProcess in
            DispatchQueue.main.async {
                guard let self, self.caffeinateProcess === finishedProcess else { return }
                self.caffeinateProcess = nil
                self.endDate = nil
                self.refresh()
            }
        }
        do {
            try process.run()
            caffeinateProcess = process
            endDate = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
            startTicking()
        } catch {
            NSLog("Halfwin: failed to launch caffeinate: \(error)")
            caffeinateProcess = nil
            endDate = nil
        }
    }

    private func stopCaffeinate() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let process = caffeinateProcess, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        caffeinateProcess = nil
        endDate = nil
    }

    private func startTicking() {
        tickTimer?.invalidate()
        guard endDate != nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func startLidWatch() {
        guard lidWatchTimer == nil else { return }
        lidWatchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func lidOn() -> Bool {
        for line in shellOut("/usr/bin/pmset", ["-g"]).split(separator: "\n") {
            let value = line.lowercased()
            if value.contains("sleepdisabled") { return value.contains("1") }
        }
        return false
    }

    private func confirmLid(_ label: String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = label == nil
            ? "Keep Awake With Lid Closed?"
            : "Keep Awake With Lid Closed for \(label!)?"
        var body = """
        Disables system sleep so your Mac keeps running with the lid shut.

        • Requires your admin password.
        • With the lid closed there is no active cooling, so avoid heavy sustained loads for long stretches.
        """
        body += label == nil
            ? "\n• Stays on until you turn it off; persists even if you quit Halfwin."
            : "\n• Auto-reverts after \(label!)."
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func enableLid(seconds: Int?) {
        var command = "pkill -f HALFWIN_LID_REVERT 2>/dev/null; pmset -a disablesleep 1"
        if let seconds {
            command += "; nohup sh -c 'sleep \(seconds); pmset -a disablesleep 0' HALFWIN_LID_REVERT >/dev/null 2>&1 &"
        }
        if runPrivileged(command) {
            lidEndDate = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
            if !isActive { startCaffeinate(seconds: nil) }
        }
        refresh()
    }

    private func disableLid() {
        if runPrivileged("pkill -f HALFWIN_LID_REVERT 2>/dev/null; pmset -a disablesleep 0") {
            lidEndDate = nil
            if isActive && endDate == nil { stopCaffeinate() }
        }
        refresh()
    }

    @discardableResult
    private func runPrivileged(_ command: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?
            .executeAndReturnError(&error)
        if let error {
            NSLog("Halfwin: privileged command failed: \(error)")
            return false
        }
        return true
    }

    private func shellOut(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func nearest(_ date: Date?) -> Int? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        return Self.durations.map { $0.1 }.min {
            abs(Double($0) - remaining) < abs(Double($1) - remaining)
        }
    }
}
