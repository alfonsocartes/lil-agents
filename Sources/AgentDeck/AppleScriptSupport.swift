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
        // app. Only activate a candidate that is already running. The check
        // goes through the bundle-id-aware path so a nightly/beta/renamed
        // bundle ("iTerm2 Nightly") isn't mistaken for "not running".
        guard isRunning(bundleIDs: TerminalBundleIDs.forDisplayNames(candidates), names: candidates) else {
            NSLog("\(label): none of \(candidates) is running; skipping activate")
            return
        }
        for name in candidates {
            let (status, _, _) = run("tell application \"\(name)\" to activate")
            if status == 0 { return }
        }
        NSLog("\(label): failed to activate any of \(candidates)")
    }

    /// True if any currently-running app matches either
    ///   - one of `bundleIDs` (case-insensitive exact match — the reliable
    ///     signal, since the bundle identifier is stable across renames,
    ///     nightlies and betas), or
    ///   - one of `names` as a case-insensitive PREFIX of the app's localized
    ///     name, so "iTerm2 Nightly" still matches the "iTerm2" candidate.
    ///
    /// Read-only; safe to call off the main thread. Callers rely on this to
    /// avoid LAUNCHING an app that isn't running — a prefix match can only
    /// widen what we recognize as already-running, never cause a launch.
    static func isRunning(bundleIDs: [String], names: [String] = []) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            if let id = app.bundleIdentifier,
               bundleIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
                return true
            }
            if let localized = app.localizedName,
               names.contains(where: { localized.lowercased().hasPrefix($0.lowercased()) }) {
                return true
            }
        }
        return false
    }
}

/// Bundle identifiers for the terminals we drive. Matching on these rather
/// than on display names is what makes the running-check survive nightly and
/// beta builds, renamed bundles, and localized app names.
enum TerminalBundleIDs {
    static let iTerm2 = "com.googlecode.iterm2"
    static let appleTerminal = "com.apple.Terminal"
    static let wezterm = "com.github.wez.wezterm"
    static let ghostty = "com.mitchellh.ghostty"

    /// Maps the display names callers already pass around (e.g. ["iTerm2",
    /// "iTerm"]) onto the bundle ids above, so `activate` can do the reliable
    /// check without every call site changing its signature. Unknown names
    /// simply contribute no id and fall back to the name prefix match.
    static func forDisplayNames(_ names: [String]) -> [String] {
        var ids: [String] = []
        for name in names {
            switch name.lowercased() {
            case "iterm", "iterm2": ids.append(iTerm2)
            case "terminal":        ids.append(appleTerminal)
            case "wezterm":         ids.append(wezterm)
            case "ghostty":         ids.append(ghostty)
            default:                break
            }
        }
        return ids
    }
}
