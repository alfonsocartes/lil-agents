import Foundation

/// Jumps to the Ghostty split whose tty or working directory matches the
/// session shown in the overlay, using Ghostty's AppleScript scripting API
/// (application → windows → tabs → terminals, one "terminal" per split/pane;
/// shipped in Ghostty 1.3.0, March 2026).
///
/// Tries three strategies in order, falling back as soon as one is
/// unavailable rather than failing outright:
///  1. Exact `tty` match via `focus <terminal>` — precise, but the `tty`
///     property only exists on Ghostty 1.4.0 / `tip` builds. On older
///     Ghostty this terminology is unknown to the app, the whole osascript
///     errors, and we silently fall through (no per-jump log noise).
///  2. `working directory` match via `focus <terminal>` — works on Ghostty
///     1.3.0+. Ambiguous only if two splits share a cwd, but still strictly
///     better than blind app activation.
///  3. Best-effort `AppleScriptSupport.activate` — just brings Ghostty
///     forward, for Ghostty versions predating the scripting API.
///
/// NOTE: The first `focus` call triggers a one-time macOS Automation (TCC)
/// consent prompt for controlling Ghostty (same as iTerm2).
struct GhosttyJumper: TerminalJumper {
    func jump(_ target: JumpTarget) {
        if let tty = target.tty, !tty.isEmpty, Self.focus(property: "tty", equals: tty) {
            return
        }
        if let cwd = target.cwd, !cwd.isEmpty, Self.focus(property: "working directory", equals: cwd) {
            return
        }
        AppleScriptSupport.activate(candidates: ["Ghostty"], label: "GhosttyJumper")
    }

    /// Scans windows→tabs→terminals for a terminal whose `property` equals
    /// `value` and focuses it. Returns true iff the script ran cleanly and
    /// reported "focused". Reading the property is wrapped in a `try` so one
    /// odd terminal (or a Ghostty version that doesn't know the property at
    /// all) can't abort the scan — it just yields "nomatch"/an error, which
    /// we treat as silent no-match.
    private static func focus(property: String, equals value: String) -> Bool {
        let escaped = AppleScriptSupport.escapeForAppleScriptString(value)
        let script = """
        tell application "Ghostty"
            set targetValue to "\(escaped)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with tm in terminals of t
                        set tv to ""
                        try
                            set tv to \(property) of tm
                        end try
                        if tv is targetValue then
                            focus tm
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
            return "nomatch"
        end tell
        """
        let (status, out, _) = AppleScriptSupport.run(script)
        return status == 0 && out == "focused"
    }
}
