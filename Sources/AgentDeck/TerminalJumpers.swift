import Foundation

/// A per-terminal strategy for raising the pane/window that owns a session.
/// Implementations run entirely OFF the main thread (Process + osascript both
/// block) and fail quietly via NSLog on any error — never surfaced to the UI.
protocol TerminalJumper {
    func jump(_ target: JumpTarget)
}

/// Routes a `JumpTarget` to the jumper for its terminal kind, off the main
/// thread. This is the single entry point call sites (`MenuBarController`,
/// `OverlayView`) use — they no longer talk to a specific jumper directly.
enum TerminalJumpers {
    static func jump(_ target: JumpTarget) {
        DispatchQueue.global(qos: .userInitiated).async {
            jumper(for: target.terminal).jump(target)
        }
    }

    private static func jumper(for terminal: TerminalKind) -> TerminalJumper {
        switch terminal {
        case .iterm2:        return ITermJumper()
        case .appleTerminal: return AppleTerminalJumper()
        case .wezterm:       return WezTermJumper()
        case .tmux:          return TmuxJumper()
        case .ghostty:       return GhosttyJumper()
        case .unknown:       return FallbackJumper()
        }
    }
}

/// Resolves a CLI tool (tmux, wezterm) to an absolute path.
///
/// A GUI app launched by launchd / `open` inherits a MINIMAL PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) — it does NOT include `/opt/homebrew/bin`,
/// `/usr/local/bin`, or `/opt/local/bin` where these tools actually live. So
/// running `/usr/bin/env tmux` from inside the app fails ("env: tmux: No such
/// file or directory") for the common Homebrew/MacPorts install, and the jump
/// silently no-ops. We instead:
///   1. use an absolute `hint` captured by the forwarder — but ONLY after it
///      clears the trust checks below (see `isTrustedHint`); else
///   2. search the common install locations ourselves; else
///   3. ask the user's LOGIN shell (`$SHELL -lc 'command -v <name>'`), which
///      picks up PATH-managed installs (nix, asdf, mise, custom prefixes) that
///      no fixed directory list can enumerate; else
///   4. return nil — the caller logs an actionable message and aborts.
///
/// There is deliberately NO "just return the bare name" fallback: callers do
/// `Process.executableURL = URL(fileURLWithPath: resolved)`, which treats a
/// bare name as a path relative to the app's cwd and never performs a PATH
/// search, so such a value could only ever fail at spawn time.
enum ExecutableResolver {
    /// Homebrew (Apple silicon), Homebrew (Intel), MacPorts, per-user nix and
    /// `~/.local/bin` installs, NixOS-style system profile, then the system
    /// dirs that are already on the minimal PATH. `~` is expanded via
    /// `FileManager` rather than hardcoded so this works for any user account.
    private static let searchDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.nix-profile/bin",
            "\(home)/.local/bin",
            "/run/current-system/sw/bin",
            "/usr/bin",
            "/bin",
        ]
    }()

    /// Install prefixes we consider trusted for an *untrusted* hint (see
    /// `isTrustedHint`). Covers every legitimate way these tools get installed
    /// on macOS/nix, and therefore excludes user-writable scratch space —
    /// `/tmp`, `/private/tmp`, `/var/folders`, `~/Downloads`, and friends.
    private static let trustedPrefixes: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications",
            "/System",
            "/usr",
            "/bin",
            "/opt",
            "/nix/store",
            "/run/current-system/sw",
            "\(home)/Applications",
        ]
    }()

    /// Resolved absolute paths, keyed by tool name, memoized for the process
    /// lifetime so we don't spawn a login shell on every jump. Jumpers run on
    /// a global queue (`TerminalJumpers.jump`), so all access is under a lock.
    /// Hint-derived paths are intentionally NOT cached: the hint is per-event
    /// input, while this cache is per-tool.
    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]

    /// Rejected-hint log de-duplication: we warn once per distinct hint rather
    /// than on every jump, keeping the failure visible without log spam.
    private static var loggedRejectedHints: Set<String> = []

    /// Returns the absolute path to `name`, or nil if it genuinely can't be
    /// found anywhere we're willing to execute from.
    static func resolve(_ name: String, hint: String? = nil) -> String? {
        if let hint, !hint.isEmpty {
            if isTrustedHint(hint, name: name) {
                return hint
            }
            logRejectedHint(hint, name: name)
            // Fall through to the normal search — a rejected hint must never
            // reach `Process`, but it also shouldn't break a valid install.
        }

        cacheLock.lock()
        let cached = cache[name]
        cacheLock.unlock()
        if let cached { return cached }

        var resolved: String?
        let fm = FileManager.default
        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                resolved = candidate
                break
            }
        }
        if resolved == nil {
            resolved = resolveViaLoginShell(name)
        }

        if let resolved {
            cacheLock.lock()
            cache[name] = resolved
            cacheLock.unlock()
        }
        return resolved
    }

    /// SECURITY: `hint` originates from a hook event (the forwarder reads
    /// `$WEZTERM_EXECUTABLE`), so anything that can set that env var — or POST
    /// a crafted event to the local listener — controls it. Since the resolved
    /// value is handed straight to `Process`, an unvalidated hint is a remote
    /// code-execution sink. Per the repo's "validate user input at system
    /// boundaries / sanitize file paths" rules, this IS that boundary: we
    /// accept a hint only when it is
    ///   (a) an absolute path,
    ///   (b) an executable file,
    ///   (c) named like the tool we asked for (`wezterm`, `wezterm-gui`, …) —
    ///       so a hint can't redirect us to some unrelated binary, and
    ///   (d) located, AFTER symlink resolution, under a trusted install prefix
    ///       — so a symlink parked in a trusted-looking spot can't smuggle in
    ///       a payload from `/tmp`.
    private static func isTrustedHint(_ hint: String, name: String) -> Bool {
        guard hint.hasPrefix("/") else { return false }
        guard FileManager.default.isExecutableFile(atPath: hint) else { return false }

        let base = (hint as NSString).lastPathComponent
        guard base == name || base.hasPrefix(name) else { return false }

        let real = URL(fileURLWithPath: hint).resolvingSymlinksInPath().path
        return trustedPrefixes.contains { prefix in
            real == prefix || real.hasPrefix(prefix + "/")
        }
    }

    private static func logRejectedHint(_ hint: String, name: String) {
        cacheLock.lock()
        let isNew = loggedRejectedHints.insert(hint).inserted
        cacheLock.unlock()
        if isNew {
            NSLog("ExecutableResolver: rejected untrusted \(name) hint '\(hint)' (not an executable under a trusted install prefix); falling back to the standard search")
        }
    }

    /// Last resort: ask the user's login shell where the tool lives, so
    /// PATH-managed installs (asdf/mise shims, custom prefixes, per-project
    /// profiles) are found even though we can't enumerate their directories.
    /// `-l` is what makes this work — it sources the login profile that sets
    /// up that PATH, which the app's launchd environment never saw.
    ///
    /// The result comes from the user's own shell config rather than from
    /// event data, so it is not attacker-controlled the way a hint is; we
    /// still require absolute + executable + a matching basename before
    /// executing it.
    private static func resolveViaLoginShell(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(name)"]
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            // Read before waiting: `command -v` output is tiny, but draining
            // first avoids any chance of blocking on a full pipe buffer.
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let base = (path as NSString).lastPathComponent
            guard base == name || base.hasPrefix(name) else { return nil }
            return path
        } catch {
            return nil
        }
    }
}
