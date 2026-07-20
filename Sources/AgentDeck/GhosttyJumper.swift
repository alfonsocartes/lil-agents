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

    /// Pure path-normalization extracted from `focusByWorkingDirectory` so it
    /// can be unit-tested without running any AppleScript. Symlink-resolves the
    /// cwd (Foundation's `resolvingSymlinksInPath()` returns the "sugared"
    /// short form for `/tmp`, `/var`, `/etc`), trims a trailing slash, and
    /// computes the `/private`-prefixed long form the way AppleScript's `as
    /// alias` reports it — while guarding against double-prefixing a path that
    /// is already under `/private`. Behavior is identical to the inline logic
    /// it replaced.
    internal static func normalizedCWDVariants(_ cwd: String) -> (plain: String, privatePath: String) {
        var target = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        if target.count > 1, target.hasSuffix("/") {
            target.removeLast()
        }
        let privateTarget: String
        if target.hasPrefix("/private/") || target == "/private" {
            // Already long-form; don't double-prefix into "/private/private/...".
            privateTarget = target
        } else if target == "/tmp" || target.hasPrefix("/tmp/")
            || target == "/var" || target.hasPrefix("/var/")
            || target == "/etc" || target.hasPrefix("/etc/") {
            privateTarget = "/private" + target
        } else {
            privateTarget = target
        }
        return (plain: target, privatePath: privateTarget)
    }

    /// Same scan as `focusByTTY`, specialized for the cwd tier:
    /// both sides of the comparison are symlink-resolved so a session whose
    /// cwd is a symlink (e.g. `~/Source` -> `/Volumes/...`) still matches
    /// Ghostty's resolved `working directory`, and a trailing-slash
    /// difference is tolerated. Kept separate from `focus` rather than
    /// parameterized, since this normalization is specific to directory
    /// paths — the tty tier is a device path and must NOT go through it.
    ///
    /// `/tmp`, `/var`, and `/etc` are symlinks into `/private` on macOS, and
    /// the two sides of this comparison disagree about which spelling to use:
    /// Foundation's `resolvingSymlinksInPath()` special-cases those three and
    /// returns the short, "sugared" form (`/tmp/x`, no `/private`), even
    /// though the fully-resolved path is `/private/tmp/x`. AppleScript's
    /// `as alias` coercion has no such special case — it always reports the
    /// fully-resolved long form (`/private/tmp/x`). Left alone, a cwd under
    /// any of those three roots would normalize to a different string on
    /// each side and this tier would never match. So — mirroring how
    /// `focusByTTY` accepts both the bare and `/dev/`-prefixed forms — we
    /// compute both the plain and `/private`-prefixed spellings of the
    /// target here and let the script accept either.
    private static func focusByWorkingDirectory(_ cwd: String) -> Bool {
        let variants = normalizedCWDVariants(cwd)
        let escapedPlain = AppleScriptSupport.escapeForAppleScriptString(variants.plain)
        let escapedPrivate = AppleScriptSupport.escapeForAppleScriptString(variants.privatePath)
        let script = """
        tell application "Ghostty"
            set targetPlain to "\(escapedPlain)"
            set targetPrivate to "\(escapedPrivate)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with tm in terminals of t
                        set tv to ""
                        try
                            set tv to working directory of tm
                        end try
                        -- Resolve tv through an alias so a symlinked cwd compares
                        -- equal to the already-resolved target. Wrapped in a
                        -- `try` so a stale/nonexistent directory can't abort the
                        -- scan — tv just falls back to the raw value.
                        try
                            set tv to POSIX path of ((POSIX file tv) as alias)
                        end try
                        if tv ends with "/" and tv is not "/" then
                            set tv to text 1 thru -2 of tv
                        end if
                        if tv is targetPlain or tv is targetPrivate then
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
