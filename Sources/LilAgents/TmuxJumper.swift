import Foundation

/// Jumps to the tmux pane that owns a session (precise, via the tmux server
/// itself — this works even though we're not "inside" tmux), then raises the
/// GUI window that hosts the attached client.
///
/// Host-raise precision depends on what the forwarder could detect:
///   - iTerm2/Apple Terminal host with a captured `host_tty` → precise,
///     delegates to that terminal's own jumper.
///   - Any other/undetected host → best-effort `activate` of the app only.
struct TmuxJumper: TerminalJumper {
    func jump(_ target: JumpTarget) {
        guard let pane = target.tmuxPane, !pane.isEmpty else {
            // Without a pane id we can't select the right pane — but bailing
            // outright would make the click a total no-op. Raising the host
            // window is still strictly useful, so do that much.
            NSLog("TmuxJumper: no tmux_pane for session (cwd=\(target.cwd ?? "nil")); skipping pane focus, still raising host window")
            Self.raiseHost(target)
            return
        }
        let socketArgs: [String] = (target.tmuxSocket?.isEmpty == false) ? ["-S", target.tmuxSocket!] : []

        // Resolve the pane's window (and session, for the switch-client step
        // below) so raising the host window lands on the right place even if
        // its client is currently attached elsewhere.
        let windowID = Self.runTmux(socketArgs + ["display-message", "-p", "-t", pane, "#{window_id}"])
        let sessionName = Self.runTmux(socketArgs + ["display-message", "-p", "-t", pane, "#{session_name}"])

        Self.runTmux(socketArgs + ["select-pane", "-t", pane])
        if let windowID, !windowID.isEmpty {
            Self.runTmux(socketArgs + ["select-window", "-t", windowID])
        }
        // If the host client (the one we're about to raise, identified by its
        // own tty) is attached to a DIFFERENT tmux session, point it at ours
        // too. A missing/detached client here is a routine no-op, not a real
        // error, so this one is quiet on failure.
        if let hostTTY = target.hostTTY, !hostTTY.isEmpty, let sessionName, !sessionName.isEmpty {
            Self.runTmux(socketArgs + ["switch-client", "-c", hostTTY, "-t", sessionName], quiet: true)
        }

        Self.raiseHost(target)
    }

    /// Best-effort: raise the GUI window hosting the tmux client. Precise
    /// when the host is iTerm2 or Apple Terminal and we captured its window
    /// pty (`host_tty`) — delegates to that terminal's own jumper. Otherwise
    /// just activates the host app by name (pane focus above still applied).
    private static func raiseHost(_ target: JumpTarget) {
        if let hostTTY = target.hostTTY, !hostTTY.isEmpty {
            switch target.tmuxHost {
            case .iterm2:
                ITermJumper.jump(tty: hostTTY)
                return
            case .appleTerminal:
                AppleTerminalJumper.jump(tty: hostTTY)
                return
            default:
                break
            }
        }
        switch target.tmuxHost {
        case .iterm2:
            AppleScriptSupport.activate(candidates: ["iTerm2", "iTerm"], label: "TmuxJumper(iterm2 host)")
        case .appleTerminal:
            AppleScriptSupport.activate(candidates: ["Terminal"], label: "TmuxJumper(Terminal host)")
        case .wezterm:
            AppleScriptSupport.activate(candidates: ["WezTerm"], label: "TmuxJumper(WezTerm host)")
        case .ghostty:
            AppleScriptSupport.activate(candidates: ["Ghostty"], label: "TmuxJumper(Ghostty host)")
        case .tmux, .unknown, nil:
            NSLog("TmuxJumper: unknown host app; pane focus applied but no window could be raised")
        }
    }

    @discardableResult
    private static func runTmux(_ args: [String], quiet: Bool = false) -> String? {
        // Resolve tmux to an absolute path: the app's launchd PATH excludes
        // Homebrew/MacPorts, so `/usr/bin/env tmux` would not find it. A nil
        // result means tmux really isn't installed anywhere we can see, and
        // there is nothing sensible left to spawn — say so once per command
        // instead of failing silently. (Not gated by `quiet`: `quiet` is for
        // routine tmux-level no-ops, whereas a missing binary is actionable.)
        guard let tmux = ExecutableResolver.resolve("tmux") else {
            NSLog("TmuxJumper: tmux not found in PATH or standard install locations; cannot jump")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            // Drain both pipes concurrently BEFORE waitUntilExit(): tmux can
            // write more than the pipe's ~64KB kernel buffer to either
            // stream, and once that buffer fills the child blocks inside
            // write(2) until we read from it. waitUntilExit() only returns
            // once the child has actually exited, so calling it first while a
            // pipe sits undrained is a permanent deadlock (we're waiting on
            // the child, the child is waiting on us). Reading both pipes off
            // separate queues first — rather than only reading stderr on the
            // failure path, as before — means neither stream can back up
            // regardless of which one tmux fills or whether the command
            // succeeds. Shared with the other Process-running jumpers via
            // `AppleScriptSupport.drainAndWait`; stderr is still only USED
            // below on the failure path, it's just always drained.
            let (outData, errData) = AppleScriptSupport.drainAndWait(process, outPipe: outPipe, errPipe: errPipe)
            let out = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                if !quiet {
                    let err = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    NSLog("TmuxJumper: tmux \(args.joined(separator: " ")) failed: \(err)")
                }
                return nil
            }
            return out
        } catch {
            if !quiet { NSLog("TmuxJumper: failed to launch tmux: \(error)") }
            return nil
        }
    }
}
