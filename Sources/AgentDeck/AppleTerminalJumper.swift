import Foundation

/// Jumps to the Apple Terminal window/tab whose controlling TTY matches a
/// session, by matching `tty of t` via osascript across windows → tabs.
///
/// NOTE: The first run triggers a macOS Automation (TCC) prompt to control
/// "Terminal". If denied, osascript exits non-zero and we log and return.
struct AppleTerminalJumper: TerminalJumper {
    func jump(_ target: JumpTarget) {
        guard let tty = target.tty, !tty.isEmpty else {
            NSLog("AppleTerminalJumper: no tty for session (cwd=\(target.cwd ?? "nil")); skipping jump")
            return
        }
        Self.jump(tty: tty)
    }

    /// Focuses the Terminal.app tab whose tty matches `tty`. Exposed as a
    /// static helper (in addition to the `TerminalJumper` conformance above)
    /// so `TmuxJumper` can reuse it directly for a precise host-window raise
    /// via a captured `host_tty`.
    static func jump(tty: String) {
        let escaped = AppleScriptSupport.escapeForAppleScriptString(tty)
        let script = """
        tell application "Terminal"
            set targetTTY to "\(escaped)"
            repeat with w in windows
                repeat with t in tabs of w
                    set stty to ""
                    try
                        set stty to tty of t
                    end try
                    if stty is targetTTY then
                        set selected of t to true
                        set index of w to 1
                        set frontmost of w to true
                        activate
                        return "focused"
                    end if
                end repeat
            end repeat
            return "nomatch"
        end tell
        """
        AppleScriptSupport.runFocusScript(script, label: "AppleTerminalJumper tty=\(tty)")
    }
}
