import AppKit
import Foundation
import Synchronization

/// Thread-safe single-write, single-read box for one pipe's drained bytes.
/// `drainAndWait` below hands one of these to each of two concurrent
/// `DispatchQueue.global()` closures; each writes it exactly once via `set`
/// and nothing reads via `get` until both closures have finished (enforced
/// by `group.wait()`), so there's no real contention. The box — and its
/// `Mutex` — exist only because Swift 6 language mode rejects mutating a
/// captured `var` from concurrently-executing closures outright, not because
/// the underlying access pattern is actually unsafe. All storage is a
/// `Mutex` (itself `Sendable`), so the class earns a checked `Sendable`
/// conformance — no `@unchecked` needed.
private final class DataBox: Sendable {
    private let data = Mutex(Data())

    func set(_ newData: Data) {
        data.withLock { $0 = newData }
    }

    func get() -> Data {
        data.withLock { $0 }
    }
}

/// Shared plumbing for the terminal jumpers that drive apps via AppleScript
/// (osascript): running a script, escaping strings safely, and logging
/// failures consistently. Every entry point here blocks the calling thread —
/// callers must already be off the main thread (see `TerminalJumpers.jump`).
enum AppleScriptSupport {
    /// Drains `outPipe` and `errPipe` concurrently, then waits for `process`
    /// to exit, returning the raw bytes read from each stream. Must be
    /// called AFTER `process.run()` has succeeded but BEFORE
    /// `waitUntilExit()` — see the comment in `run` below for why the
    /// ordering matters (short version: an undrained pipe that fills its
    /// kernel buffer deadlocks against a `waitUntilExit()` call that never
    /// returns until the child, blocked on that same full pipe, exits).
    ///
    /// Shared by every Process-running call site in this file plus
    /// `WezTermJumper.run` and `TmuxJumper.runTmux`, since all three need the
    /// identical drain-before-wait dance and previously duplicated it
    /// verbatim. Deliberately doesn't own `process.run()`'s try/catch or the
    /// decoding/trimming of the resulting bytes: what counts as a launch
    /// failure (and what to return for it), and how the output is decoded,
    /// differs per caller — this only covers the part that's identical
    /// everywhere. Also doesn't touch `executableURL`/`arguments`/
    /// `environment`; callers set those up before `run()` as before.
    static func drainAndWait(_ process: Process, outPipe: Pipe, errPipe: Pipe) -> (out: Data, err: Data) {
        let group = DispatchGroup()
        let outBox = DataBox()
        let errBox = DataBox()
        group.enter()
        DispatchQueue.global().async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        return (outBox.get(), errBox.get())
    }

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
            // Drain both pipes concurrently BEFORE waitUntilExit(): osascript
            // can write more than the pipe's ~64KB kernel buffer to either
            // stream, and once that buffer fills the child blocks inside
            // write(2) until we read from it. waitUntilExit() only returns
            // once the child has actually exited, so calling it first while a
            // pipe sits undrained is a permanent deadlock (we're waiting on
            // the child, the child is waiting on us). Reading both pipes off
            // separate queues first means neither stream can back up
            // regardless of which one osascript fills. See `drainAndWait`
            // above for the shared mechanics.
            let (outData, errData) = Self.drainAndWait(process, outPipe: outPipe, errPipe: errPipe)
            let out = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: errData, encoding: .utf8)?
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
    ///   - for any name in `names` that has NO known bundle-id mapping (see
    ///     `TerminalBundleIDs.forDisplayNames`), that name as a
    ///     case-insensitive PREFIX of the app's localized name PROVIDED the
    ///     match lands on a word boundary (end of string, or the next
    ///     character is non-alphanumeric) — so "iTerm2 Nightly" still matches
    ///     "iTerm2", but "TerminalFooHelper" does not match "Terminal".
    ///
    /// Read-only; safe to call off the main thread. Callers rely on this to
    /// avoid LAUNCHING an app that isn't running (see `activate` below): a
    /// false positive here — not a false negative — is what causes the
    /// unwanted launch, so widening the match is dangerous, not safe. Names
    /// that already have a reliable bundle-id mapping never fall through to
    /// the (inherently fuzzier) name check at all; the word-boundary
    /// requirement limits the risk for the remaining unmapped names.
    static func isRunning(bundleIDs: [String], names: [String] = []) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        let unmappedNames = names.filter { TerminalBundleIDs.forDisplayNames([$0]).isEmpty }
        for app in apps {
            if let id = app.bundleIdentifier,
               bundleIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
                return true
            }
            if !unmappedNames.isEmpty, let localized = app.localizedName,
               unmappedNames.contains(where: { isWordBoundaryPrefix($0, of: localized) }) {
                return true
            }
        }
        return false
    }

    /// True if `prefix` matches the start of `string` case-insensitively AND
    /// the match ends on a word boundary in `string` (nothing left, or the
    /// next character isn't a letter/digit). Guards the `isRunning` name
    /// fallback against over-matching, e.g. "Terminal" must not match
    /// "TerminalFooHelper".
    private static func isWordBoundaryPrefix(_ prefix: String, of string: String) -> Bool {
        let lowerString = string.lowercased()
        let lowerPrefix = prefix.lowercased()
        guard lowerString.hasPrefix(lowerPrefix) else { return false }
        let boundary = lowerString.index(lowerString.startIndex, offsetBy: lowerPrefix.count)
        guard boundary < lowerString.endIndex else { return true }
        return !lowerString[boundary].isLetter && !lowerString[boundary].isNumber
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
