import AppKit

/// Fully reverses lil agents' footprint on the machine: CLI hooks, the
/// stay-awake sudoers rule (and the disablesleep flag if it's on), and the
/// app's support directory. Triggered from the Uninstall action in Settings
/// after a native confirmation dialog (the confirmation is SwiftUI's, so this
/// runs only once the user has already confirmed). Never crashes — every step
/// is best-effort and logs/surfaces failures without aborting the remaining
/// steps, so a partially-broken install can still be cleaned up.
@MainActor
enum Uninstaller {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static let pmsetPath = "/usr/bin/pmset"
    private static let sudoersPath = "/etc/sudoers.d/agentdeck"

    // MARK: - Entry point

    /// Performs the full uninstall and terminates the app. The confirmation is
    /// owned by SwiftUI now (a `.confirmationDialog` in Settings), so this is
    /// only ever called after the user has confirmed.
    static func performUninstall() {
        var issues: [String] = []

        do {
            try HookInstaller.uninstall()
        } catch {
            let message = "Failed to remove CLI hooks: \(error.localizedDescription)"
            NSLog("Uninstaller: \(message)")
            issues.append(message)
        }

        if let message = revertStayAwake() {
            NSLog("Uninstaller: \(message)")
            issues.append(message)
        }

        do {
            if FileManager.default.fileExists(atPath: AgentDeck.supportDir.path) {
                try FileManager.default.removeItem(at: AgentDeck.supportDir)
            }
        } catch {
            let message = "Failed to remove support files: \(error.localizedDescription)"
            NSLog("Uninstaller: \(message)")
            issues.append(message)
        }

        if !issues.isEmpty {
            showIssuesAlert(issues)
        }

        showFinalAlertAndQuit()
    }

    /// Turns off `disablesleep` if currently on, and removes the sudoers
    /// NOPASSWD rule StayAwakeController installed — mirroring its install
    /// mechanism (a single AppleScript "with administrator privileges" prompt
    /// covering both). Idempotent: does nothing (and prompts nothing) if
    /// neither is present. Returns a non-nil message on failure.
    private static func revertStayAwake() -> String? {
        let sudoersExists = FileManager.default.fileExists(atPath: sudoersPath)
        let isAwake = readSleepDisabled()
        guard sudoersExists || isAwake else { return nil }

        var commands: [String] = []
        if isAwake { commands.append("\(pmsetPath) -a disablesleep 0") }
        if sudoersExists { commands.append("/bin/rm -f \(sudoersPath)") }

        let shellCommand = commands.joined(separator: " && ")
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let result = runProcess("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else {
            return "Failed to revert stay-awake settings: \(result.stderr.isEmpty ? "cancelled or failed" : result.stderr)"
        }
        return nil
    }

    // MARK: - Alerts

    private static func showIssuesAlert(_ issues: [String]) {
        let alert = NSAlert()
        alert.messageText = "Some cleanup steps failed"
        alert.informativeText = issues.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    private static func showFinalAlertAndQuit() {
        let alert = NSAlert()
        alert.messageText = "lil agents is ready to be removed"
        alert.informativeText = "The app will now quit and reveal itself in Finder — drag it to the Trash to finish."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()

        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    // MARK: - State + process helpers (mirrors StayAwakeController's mechanism)

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

    private static func runProcess(_ path: String, _ args: [String]) -> ProcessResult {
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
