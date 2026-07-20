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
            NSLog("TmuxJumper: no tmux_pane for session (cwd=\(target.cwd ?? "nil")); skipping jump")
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
        // Homebrew/MacPorts, so `/usr/bin/env tmux` would not find it.
        let tmux = ExecutableResolver.resolve("tmux")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                if !quiet {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
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
