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
        if let tty = target.tty, !tty.isEmpty, Self.focusByTTY(tty) {
            return
        }
        if let cwd = target.cwd, !cwd.isEmpty, Self.focusByWorkingDirectory(cwd) {
            return
        }
        AppleScriptSupport.activate(candidates: ["Ghostty"], label: "GhosttyJumper")
    }

    /// Scans windows→tabs→terminals for a terminal whose `tty` matches and
    /// focuses it. Returns true iff the script ran cleanly and reported
    /// "focused". Reading the property is wrapped in a `try` so one odd
    /// terminal (or a Ghostty version that doesn't know `tty` at all) can't
    /// abort the scan — it just yields "nomatch"/an error, which we treat as
    /// silent no-match. `focus` raises the terminal's window within Ghostty
    /// but doesn't reliably bring the Ghostty app itself forward over other
    /// apps, so `activate` follows it (mirrors `ITermJumper`, which does the
    /// same after selecting its match).
    ///
    /// Terminals disagree about whether a tty is reported as `/dev/ttys004` or
    /// the bare `ttys004` (the same reason `WezTermJumper` has `normalizeTTY`),
    /// and we don't know which form this Ghostty build uses. So we compute both
    /// forms here and let the script accept either — otherwise a mismatch in
    /// form alone would make the precise tty tier never match, silently
    /// degrading every jump to the coarser cwd tier.
    private static func focusByTTY(_ tty: String) -> Bool {
        let bare = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        let escapedFull = AppleScriptSupport.escapeForAppleScriptString("/dev/" + bare)
        let escapedBare = AppleScriptSupport.escapeForAppleScriptString(bare)
        let script = """
        tell application "Ghostty"
            set targetFull to "\(escapedFull)"
            set targetBare to "\(escapedBare)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with tm in terminals of t
                        set tv to ""
                        try
                            set tv to tty of tm
                        end try
                        if tv is not "" and (tv is targetFull or tv is targetBare) then
                            focus tm
                            activate
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

    /// Same scan as `focusByTTY`, specialized for the cwd tier:
    /// both sides of the comparison are symlink-resolved so a session whose
    /// cwd is a symlink (e.g. `~/Source` -> `/Volumes/...`) still matches
    /// Ghostty's resolved `working directory`, and a trailing-slash
    /// difference is tolerated. Kept separate from `focus` rather than
    /// parameterized, since this normalization is specific to directory
    /// paths — the tty tier is a device path and must NOT go through it.
    private static func focusByWorkingDirectory(_ cwd: String) -> Bool {
        var target = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        if target.count > 1, target.hasSuffix("/") {
            target.removeLast()
        }
        let escaped = AppleScriptSupport.escapeForAppleScriptString(target)
        let script = """
        tell application "Ghostty"
            set targetValue to "\(escaped)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with tm in terminals of t
                        set tv to ""
                        try
                            set tv to working directory of tm
                        end try
                        -- Resolve tv through an alias so a symlinked cwd compares
                        -- equal to the already-resolved targetValue. Wrapped in a
                        -- `try` so a stale/nonexistent directory can't abort the
                        -- scan — tv just falls back to the raw value.
                        try
                            set tv to POSIX path of ((POSIX file tv) as alias)
                        end try
                        if tv ends with "/" and tv is not "/" then
                            set tv to text 1 thru -2 of tv
                        end if
                        if tv is targetValue then
                            focus tm
                            activate
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
