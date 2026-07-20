import Foundation
import Observation

/// Result of running an external command: exit status plus captured stdout/stderr.
private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Keeps the Mac awake with the lid closed by toggling the kernel `SleepDisabled`
/// flag via `pmset -a disablesleep 1|0`. This is the only mechanism that actually
/// prevents sleep on Apple Silicon with the lid shut — `caffeinate` cannot do it.
///
/// `pmset -a disablesleep` requires root. To avoid a password prompt on every
/// toggle, we install a narrowly scoped sudoers NOPASSWD rule (limited to exactly
/// the two `pmset -a disablesleep 0|1` invocations) the first time it's needed,
/// prompting for admin credentials once via AppleScript. After that, toggling
/// runs `sudo -n pmset ...` non-interactively.
@MainActor
@Observable
final class StayAwakeController {
    private(set) var isAwake: Bool = false {
        didSet {
            guard isAwake != oldValue else { return }
            updateBatteryMonitoring()
        }
    }

    var batteryFloorEnabled: Bool = true {
        didSet {
            guard batteryFloorEnabled != oldValue else { return }
            updateBatteryMonitoring()
        }
    }

    var batteryFloorPercent: Int = 20

    var timerMinutes: Int? = nil {
        didSet {
            // Only reschedule if we're currently awake; otherwise this simply
            // affects the next call to `enable()`.
            guard isAwake else { return }
            scheduleAutoOffTimerIfNeeded()
        }
    }

    // surfaced nowhere yet — candidate for Settings
    private(set) var lastMessage: String? = nil

    /// True only if THIS controller instance is the one that flipped SleepDisabled
    /// on. Gates `appWillTerminate()` so we never revert a setting some other
    /// process (or a previous app launch) put in place.
    private var weEnabledIt = false

    private var batteryTimer: Timer?
    private var autoOffTimer: Timer?

    /// Forces the display off when the lid closes while stay-awake is active —
    /// `disablesleep` alone can leave the internal panel backlit under the lid.
    /// `@ObservationIgnored`: `@Observable` can't transform a `lazy var` (it
    /// becomes a computed property under the hood, which `lazy` rejects), and
    /// this is a private implementation detail with no UI observer anyway.
    @ObservationIgnored
    private lazy var clamshell = ClamshellMonitor { [weak self] in self?.onLidClosed() }

    private static let pmsetPath = "/usr/bin/pmset"
    private static let sudoPath = "/usr/bin/sudo"
    private static let sudoersPath = "/etc/sudoers.d/agentdeck"

    // MARK: - Public API (frozen interface)

    /// Reads the current kernel `SleepDisabled` flag via `pmset -g` and updates
    /// `isAwake`. This is the source of truth — never trust `weEnabledIt` for
    /// display state, since the flag can be changed outside this app.
    func refresh() {
        isAwake = Self.readSleepDisabled()
        // Keep the lid-close watcher running whenever the flag is set (including
        // when it was already set at launch, before any toggle this session).
        if isAwake { clamshell.start() } else { clamshell.stop() }
    }

    /// Flips stay-awake on or off.
    func toggle() {
        if isAwake {
            disable(message: "Stay-awake disabled.")
        } else {
            Task { await enable() }
        }
    }

    /// Called from `applicationWillTerminate`. If we were the one who disabled
    /// sleep this session, revert it synchronously so the machine doesn't stay
    /// awake indefinitely after the app quits.
    func appWillTerminate() {
        cancelAutoOffTimer()
        stopBatteryMonitoring()
        clamshell.stop()
        guard weEnabledIt else { return }
        _ = Self.runProcess(Self.sudoPath, ["-n", Self.pmsetPath, "-a", "disablesleep", "0"])
        weEnabledIt = false
    }

    // MARK: - Enable / disable

    private func enable() async {
        let ok = await runPmsetDisableSleep(true)
        guard ok else { return }

        refresh()
        guard isAwake else {
            lastMessage = "Failed to enable stay-awake."
            return
        }
        weEnabledIt = true
        lastMessage = "Stay-awake enabled — lid can stay closed."
        scheduleAutoOffTimerIfNeeded()
        clamshell.start()
        if clamshell.isClosed() { onLidClosed() }   // lid already shut? kill display now
    }

    private func disable(message: String) {
        cancelAutoOffTimer()
        // Stop the battery timer synchronously so a tick during the async pmset
        // call can't re-enter disable(). The clamshell watcher is NOT stopped here
        // — only once sleep is actually re-enabled (via refresh() on success), so a
        // failed disable leaves the lid-close→display-off guard running.
        stopBatteryMonitoring()
        Task {
            let ok = await runPmsetDisableSleep(false)
            if ok {
                refresh()                 // isAwake→false stops the clamshell watcher
                weEnabledIt = false
                lastMessage = message
            } else {
                lastMessage = "Failed to disable stay-awake."
                updateBatteryMonitoring() // still awake → resume the battery guard
            }
        }
    }

    // MARK: - Battery-floor guard

    private func updateBatteryMonitoring() {
        if isAwake && batteryFloorEnabled {
            startBatteryMonitoringIfNeeded()
        } else {
            stopBatteryMonitoring()
        }
    }

    private func startBatteryMonitoringIfNeeded() {
        guard batteryTimer == nil else { return }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkBatteryFloor()
            }
        }
    }

    private func stopBatteryMonitoring() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    private func checkBatteryFloor() {
        guard isAwake, batteryFloorEnabled else { return }
        guard let percent = Self.readBatteryPercent() else { return }
        guard percent <= batteryFloorPercent else { return }
        disable(message: "Stay-awake disabled — battery at \(percent)%, at or below your \(batteryFloorPercent)% floor.")
    }

    // MARK: - Auto-off timer

    private func scheduleAutoOffTimerIfNeeded() {
        cancelAutoOffTimer()
        guard let minutes = timerMinutes, minutes > 0 else { return }
        let interval = TimeInterval(minutes) * 60
        autoOffTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAwake else { return }
                self.disable(message: "Stay-awake timer expired after \(minutes) minute\(minutes == 1 ? "" : "s").")
            }
        }
    }

    private func cancelAutoOffTimer() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
    }

    // MARK: - pmset / sudoers plumbing

    /// Runs `sudo -n pmset -a disablesleep <0|1>`. If sudoers isn't configured
    /// yet, installs the scoped NOPASSWD rule (prompting for admin once) and
    /// retries exactly once.
    private func runPmsetDisableSleep(_ enable: Bool) async -> Bool {
        let value = enable ? "1" : "0"
        let first = await runProcessAsync(Self.sudoPath, ["-n", Self.pmsetPath, "-a", "disablesleep", value])
        if first.status == 0 { return true }

        guard await installSudoers() else {
            lastMessage = "Admin setup was cancelled or failed — couldn't change sleep settings."
            return false
        }

        let retry = await runProcessAsync(Self.sudoPath, ["-n", Self.pmsetPath, "-a", "disablesleep", value])
        if retry.status != 0 {
            lastMessage = "Failed to change sleep settings even after admin setup."
        }
        return retry.status == 0
    }

    /// Installs a sudoers rule scoped to exactly the two pmset invocations we
    /// need, so future toggles never prompt for a password. Prompts for admin
    /// credentials once via AppleScript; the elevated shell command validates
    /// the file with `visudo -cf` before installing it, and sets 440 perms.
    private func installSudoers() async -> Bool {
        lastMessage = "Requesting admin permission (one-time) to control sleep without a password prompt…"
        guard let script = Self.buildAdminInstallAppleScript() else {
            lastMessage = "Couldn't set up admin access — unexpected system username."
            return false
        }
        let result = await runProcessAsync("/usr/bin/osascript", ["-e", script])
        return result.status == 0
    }

    /// Returns `nil` (aborting the install) if `NSUserName()` doesn't look like
    /// a normal macOS short name. `username` is spliced, unescaped, into a root
    /// `do shell script`; real macOS short names can't contain a `'` or newline
    /// and `visudo -cf` would also reject a malformed line before it's ever
    /// installed, so this isn't believed to be practically exploitable — but we
    /// validate before building the command anyway, as defense in depth, rather
    /// than relying solely on that downstream check.
    private static func buildAdminInstallAppleScript() -> String? {
        let username = NSUserName()
        guard username.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
            NSLog("AgentDeck: refusing to install sudoers rule — unexpected system username \"\(username)\"")
            return nil
        }
        let sudoersLine = "\(username) ALL=(root) NOPASSWD: \(pmsetPath) -a disablesleep 0, \(pmsetPath) -a disablesleep 1"
        // Write to a temp file, validate with visudo before installing anywhere,
        // then move into place with root ownership and 440 perms. Every step
        // uses an absolute path so it doesn't depend on the elevated shell's PATH.
        let steps = [
            "tmp=$(/usr/bin/mktemp /tmp/agentdeck-sudoers.XXXXXX)",
            "/bin/echo '\(sudoersLine)' > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\"",
            "/bin/mkdir -p /etc/sudoers.d",
            "/bin/mv \"$tmp\" \(sudoersPath)",
            "/usr/sbin/chown root:wheel \(sudoersPath)",
            "/bin/chmod 440 \(sudoersPath)",
        ]
        let shellCommand = steps.joined(separator: " && ")
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    // MARK: - Lid close → force display off

    /// The lid just closed while stay-awake is on. The system must stay awake, but
    /// the display should go dark — force it with `pmset displaysleepnow` (no root
    /// needed). Runs on the main run loop from the clamshell callback.
    nonisolated private func onLidClosed() {
        // Runs from the IOKit interest callback on the main run loop; do the
        // blocking Process off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.runProcess("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    // MARK: - State readers

    /// Parses `pmset -g` for a `SleepDisabled  1` (or `0`/absent) line.
    private static func readSleepDisabled() -> Bool {
        let result = runProcess(pmsetPath, ["-g"])
        guard result.status == 0 else { return false }
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SleepDisabled") {
                return trimmed.hasSuffix("1")
            }
        }
        return false
    }

    /// Parses `pmset -g batt` for the current battery percentage, e.g. a line
    /// like ` -InternalBattery-0 (id=...)\t87%; discharging; ...`.
    private static func readBatteryPercent() -> Int? {
        let result = runProcess(pmsetPath, ["-g", "batt"])
        guard result.status == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            guard let percentRange = line.range(of: "%") else { continue }
            let prefix = line[..<percentRange.lowerBound]
            let digitsStart = prefix.lastIndex(where: { !$0.isNumber })
                .map { prefix.index(after: $0) } ?? prefix.startIndex
            if let value = Int(prefix[digitsStart...]) {
                return value
            }
        }
        return nil
    }

    // MARK: - Process helper

    /// Runs a command off the main actor and awaits its result.
    private func runProcessAsync(_ path: String, _ args: [String]) async -> ProcessResult {
        await Task.detached(priority: .utility) {
            Self.runProcess(path, args)
        }.value
    }

    /// Synchronously runs a command and captures its output. Not actor-isolated
    /// so it can be called both from the main actor (fast local reads, and the
    /// termination-time revert which must be synchronous) and from a detached
    /// background task (slower calls like sudo/osascript).
    nonisolated private static func runProcess(_ path: String, _ args: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
