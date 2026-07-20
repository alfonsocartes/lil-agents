import Foundation

/// Jumps to the WezTerm pane that owns a session via `wezterm cli
/// activate-pane`, then activates the app itself so its window comes forward.
///
/// Precise when a `wezterm_pane` id was captured by the forwarder; otherwise
/// falls back to resolving the pane id from `wezterm cli list --format json`
/// by matching `tty_name`, and finally to just activating the app (best-effort)
/// if even that lookup can't find a match.
struct WezTermJumper: TerminalJumper {
    func jump(_ target: JumpTarget) {
        // Resolve to an absolute path: prefer the WEZTERM_EXECUTABLE the
        // forwarder captured (only if it clears ExecutableResolver's trust
        // checks — it is untrusted event data), else search the common install
        // locations. The app's launchd PATH excludes Homebrew, so a bare
        // "wezterm" run via /usr/bin/env would not be found.
        guard let exe = ExecutableResolver.resolve("wezterm", hint: target.weztermExe) else {
            NSLog("WezTermJumper: wezterm not found in PATH or standard install locations; cannot jump")
            return
        }
        var env = ProcessInfo.processInfo.environment
        if let socket = target.weztermSocket, !socket.isEmpty {
            env["WEZTERM_UNIX_SOCKET"] = socket
        }

        var paneID = target.weztermPane
        if paneID?.isEmpty != false {
            paneID = Self.resolvePaneID(exe: exe, env: env, tty: target.tty)
        }

        guard let paneID, !paneID.isEmpty else {
            // No pane id (stale/closed pane, or the tty lookup found nothing).
            // Activating WezTerm here would yank it to the front onto whatever
            // arbitrary pane happens to be focused, which is not what the user
            // clicked on — better to leave their focus untouched.
            NSLog("WezTermJumper: no pane id resolvable for tty=\(target.tty ?? "nil"); leaving focus untouched")
            return
        }

        let result = Self.run(exe: exe, args: ["cli", "activate-pane", "--pane-id", paneID], env: env)
        guard result.status == 0 else {
            // Same reasoning: if we couldn't focus the right pane inside
            // WezTerm, raising the app would land the user somewhere random.
            NSLog("WezTermJumper: activate-pane --pane-id \(paneID) failed: \(result.err); leaving focus untouched")
            return
        }

        // Belt-and-suspenders: activate-pane focuses the pane within WezTerm,
        // but doesn't necessarily bring the app itself to the front. Only
        // reached once we know the correct pane is selected.
        AppleScriptSupport.activate(candidates: ["WezTerm"], label: "WezTermJumper")
    }

    /// Runs `wezterm cli list --format json` and matches `tty_name` against
    /// `tty`, returning the matching pane's `pane_id`. Parsed with
    /// `JSONSerialization` rather than shelling out to `jq`.
    private static func resolvePaneID(exe: String, env: [String: String], tty: String?) -> String? {
        guard let tty, !tty.isEmpty else { return nil }
        let result = Self.run(exe: exe, args: ["cli", "list", "--format", "json"], env: env)
        guard result.status == 0, let data = result.out.data(using: .utf8) else { return nil }
        guard let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let want = normalizeTTY(tty)
        for pane in panes {
            if let ttyName = pane["tty_name"] as? String, normalizeTTY(ttyName) == want, let paneID = pane["pane_id"] {
                return "\(paneID)"
            }
        }
        return nil
    }

    /// Normalizes a tty string for comparison by stripping a leading `/dev/`,
    /// so the forwarder's `/dev/ttys004` matches `wezterm cli list`'s reported
    /// form regardless of whether it includes the prefix.
    // `internal` (not `private`) so tests can exercise this pure helper directly.
    internal static func normalizeTTY(_ s: String) -> String {
        s.hasPrefix("/dev/") ? String(s.dropFirst("/dev/".count)) : s
    }

    private static func run(exe: String, args: [String], env: [String: String]) -> (status: Int32, out: String, err: String) {
        // `exe` is already resolved to an absolute path by the caller; run it
        // directly rather than via /usr/bin/env (which searches the app's
        // minimal launchd PATH).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            // Drain both pipes concurrently BEFORE waitUntilExit(): `wezterm
            // cli list --format json` can emit well over the pipe's ~64KB
            // kernel buffer on a session with many panes, and once that
            // buffer fills the child blocks inside write(2) until we read
            // from it. waitUntilExit() only returns once the child has
            // actually exited, so calling it first while a pipe sits
            // undrained is a permanent deadlock (we're waiting on the child,
            // the child is waiting on us). Reading both pipes off separate
            // queues first means neither stream can back up regardless of
            // which one wezterm fills. Shared with the other Process-running
            // jumpers via `AppleScriptSupport.drainAndWait`.
            let (outData, errData) = AppleScriptSupport.drainAndWait(process, outPipe: outPipe, errPipe: errPipe)
            let out = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, out, err)
        } catch {
            return (-1, "", "\(error)")
        }
    }
}
