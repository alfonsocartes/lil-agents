import Foundation

/// Used when the hook forwarder couldn't determine — or is from a version too
/// old to report — which terminal hosts a session (`target.terminal ==
/// .unknown`).
///
/// The forwarder couldn't name the host, but the session still has a
/// controlling tty. As a last resort we probe the tty-addressable terminals
/// (iTerm2, Terminal.app) that are ACTUALLY RUNNING — never launching one that
/// isn't — and let each match on the captured tty. At most the real host
/// matches; a non-match is a quiet no-op. If neither is running (e.g. the host
/// is WezTerm/Ghostty, which we can't address by tty), we log and give up.
struct FallbackJumper: TerminalJumper {
    func jump(_ target: JumpTarget) {
        guard let tty = target.tty, !tty.isEmpty else {
            NSLog("FallbackJumper: unknown terminal and no tty for session (cwd=\(target.cwd ?? "nil")); nothing to do")
            return
        }

        // Detect by BUNDLE IDENTIFIER first: an exact display-name match would
        // skip an iTerm2 nightly/beta or a renamed bundle ("iTerm2 Nightly")
        // entirely, making the click do nothing. The display names are still
        // passed as a prefix-match fallback for odd installs. This only widens
        // what counts as already-running — we still never launch an app.
        var attempted = false
        if AppleScriptSupport.isRunning(bundleIDs: [TerminalBundleIDs.iTerm2], names: ["iTerm2", "iTerm"]) {
            ITermJumper.jump(tty: tty)
            attempted = true
        }
        if AppleScriptSupport.isRunning(bundleIDs: [TerminalBundleIDs.appleTerminal], names: ["Terminal"]) {
            AppleTerminalJumper.jump(tty: tty)
            attempted = true
        }
        if !attempted {
            NSLog("FallbackJumper: unknown terminal for session (tty=\(tty), cwd=\(target.cwd ?? "nil")); no tty-addressable terminal running")
        }
    }
}
