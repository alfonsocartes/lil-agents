import AppKit
import Foundation

/// Shared plumbing for the terminal jumpers that drive apps via AppleScript
/// (osascript): running a script, escaping strings safely, and logging
/// failures consistently. Every entry point here blocks the calling thread —
/// callers must already be off the main thread (see `TerminalJumpers.jump`).
enum AppleScriptSupport {
    /// Escapes a raw string for interpolation into an AppleScript string
    /// literal (backslash/quote escaping; strips newlines that would break
    /// out of the literal).
    static func escapeForAppleScriptString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Runs `script` via /usr/bin/osascript and returns (status, stdout,
    /// stderr), trimmed. Never throws — a launch failure is reported as
    /// status -1 with the error text in `err`.
    static func run(_ script: String) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, out, err)
        } catch {
            return (-1, "", "\(error)")
        }
    }

    /// Runs a "find the pane/window by tty and focus it" style script that
    /// returns "focused" on success / "nomatch" otherwise, logging via
    /// `label` on any non-"focused" outcome. Quiet on success.
    static func runFocusScript(_ script: String, label: String) {
        let (status, out, err) = run(script)
        if status != 0 || out != "focused" {
            NSLog("\(label): status=\(status) out='\(out)' err='\(err)'")
        }
    }

    /// Best-effort app activation: `tell application "<name>" to activate`,
    /// trying each candidate name in order until one succeeds. Some apps are
    /// known under multiple display names across versions/installs (e.g.
    /// "iTerm" vs "iTerm2"), so callers that don't have a dedicated precise
    /// script pass every plausible name here. Logs once if every candidate
    /// fails; quiet on success.
    static func activate(candidates: [String], label: String) {
        // `tell application "X" to activate` LAUNCHES X if it isn't running and
        // reports success, so a stale/misdetected name could spawn an unwanted
        // app. Only activate a candidate that is already running.
        guard isRunning(anyOf: candidates) else {
            NSLog("\(label): none of \(candidates) is running; skipping activate")
            return
        }
        for name in candidates {
            let (status, _, _) = run("tell application \"\(name)\" to activate")
            if status == 0 { return }
        }
        NSLog("\(label): failed to activate any of \(candidates)")
    }

    /// True if any currently-running app's localized name case-insensitively
    /// matches one of `candidates`. Read-only; safe to call off the main thread.
    static func isRunning(anyOf candidates: [String]) -> Bool {
        let names = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        return candidates.contains { candidate in
            names.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
    }
}
