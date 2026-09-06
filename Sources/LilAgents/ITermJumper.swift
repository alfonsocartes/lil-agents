import Foundation

/// Jumps to the iTerm2 tab/pane whose controlling TTY matches a session shown in
/// the overlay, by matching the controlling TTY via osascript.
///
/// NOTE: The first run triggers a macOS Automation (TCC) prompt to control
/// "iTerm2". If denied, osascript exits non-zero and we log and return.
struct ITermJumper: TerminalJumper {
    func jump(_ target: JumpTarget) {
        guard let tty = target.tty, !tty.isEmpty else {
            NSLog("ITermJumper: no tty for session (cwd=\(target.cwd ?? "nil")); skipping jump")
            return
        }
        Self.jump(tty: tty)
    }

    /// Focuses the iTerm2 session whose tty matches `tty`. Exposed as a
    /// static helper (in addition to the `TerminalJumper` conformance above)
    /// so `TmuxJumper` can reuse it directly for a precise host-window raise
    /// via a captured `host_tty` — the original single-terminal jump logic,
    /// unchanged.
    static func jump(tty: String) {
        let escaped = AppleScriptSupport.escapeForAppleScriptString(tty)
        // Raise the matching session's window by setting its index to 1 (frontmost),
        // select the tab + session, then activate. Reading `tty of s` is wrapped in a
        // try so an odd session can't abort the whole scan.
        let script = """
        tell application "iTerm2"
            set targetTTY to "\(escaped)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set stty to ""
                        try
                            set stty to tty of s
                        end try
                        if stty is targetTTY then
                            select s
                            select t
                            set index of w to 1
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
            return "nomatch"
        end tell
        """
        AppleScriptSupport.runFocusScript(script, label: "ITermJumper tty=\(tty)")
    }
}
