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
    /// on macOS/nix. NOTE: this is honestly narrower protection than it might
    /// look — `/opt` covers `/opt/homebrew` and `/usr` covers `/usr/local`,
    /// both of which are writable by the admin user (no root needed) on a
    /// standard Homebrew install. So this allowlist is NOT a defense against
    /// a same-user process that can already write into Homebrew's install
    /// prefix; what it actually blocks is a hint pointing at obvious scratch
    /// space — `/tmp`, `/private/tmp`, `/var/folders`, `~/Downloads`, and
    /// similar locations a dropped payload would realistically land.
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
    ///
    /// The value type is `String?` inside the dictionary (so lookups yield
    /// `String??`): a stored `.some(nil)` means "we tried to resolve this
    /// tool and it isn't installed," distinct from an absent key ("never
    /// tried"). This negative-caching is deliberate and permanent for the
    /// process lifetime — not TTL'd. Without it, `TmuxJumper` (which calls
    /// `resolve("tmux")` up to 5x per jump) would re-spawn a login shell on
    /// every single jump whenever tmux isn't installed. The tradeoff: a
    /// `brew install tmux` done after the app launched won't be picked up
    /// until the app restarts — acceptable for a background utility app.
    private static let cacheLock = NSLock()
    private static var cache: [String: String?] = [:]

    /// Rejected-hint log de-duplication: we warn once per distinct hint rather
    /// than on every jump, keeping the failure visible without log spam. This
    /// set is capped at `maxLoggedRejectedHints` (see `logRejectedHint`) so a
    /// local client abusing the listener can't grow it without bound by
    /// POSTing endless distinct hint values.
    private static var loggedRejectedHints: Set<String> = []
    private static let maxLoggedRejectedHints = 100

    /// Returns the absolute path to `name`, or nil if it genuinely can't be
    /// found anywhere we're willing to execute from.
    static func resolve(_ name: String, hint: String? = nil) -> String? {
        if let hint, !hint.isEmpty {
            // Fix 5 (TOCTOU): `isTrustedHint` returns the symlink-resolved
            // *real* path it actually validated, and that's what we hand
            // back here — returning the original `hint` would let a symlink
            // under a trusted prefix get validated, then retargeted at an
            // untrusted location before it's actually executed.
            if let trustedPath = isTrustedHint(hint, name: name) {
                return trustedPath
            }
            logRejectedHint(hint, name: name)
            // Fall through to the normal search — a rejected hint must never
            // reach `Process`, but it also shouldn't break a valid install.
        }

        cacheLock.lock()
        let cached = cache[name]
        cacheLock.unlock()
        // `cached` is `String??` here: `.some(.some(path))` is a resolved
        // hit, `.some(nil)` is a cached miss (negative cache — see the
        // `cache` doc comment above), and `nil` means never attempted.
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

        // Cache the outcome either way — success AND failure — so a tool
        // that isn't installed doesn't re-spawn a login shell on every jump.
        cacheLock.lock()
        cache[name] = resolved
        cacheLock.unlock()
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
    ///   (c) named like the tool we asked for (`wezterm`, `wezterm-gui`, …,
    ///       but not a lookalike like `weztermXYZ` — we require an exact
    ///       name match or a `<name>-` prefix), and
    ///   (d) located, AFTER symlink resolution, under a trusted install prefix
    ///       — so a symlink parked in a trusted-looking spot can't smuggle in
    ///       a payload from `/tmp`.
    ///
    /// Returns the symlink-resolved *real* path on success (not the original
    /// `hint`) — and the caller (`resolve`) must execute THAT value, not
    /// `hint`. Otherwise this is a TOCTOU hole: `real` is what gets checked
    /// against `trustedPrefixes`, but if the caller went on to execute the
    /// original (possibly-symlink) `hint`, the symlink could be retargeted at
    /// an untrusted path in the window between this check and `Process.run`.
    private static func isTrustedHint(_ hint: String, name: String) -> String? {
        guard hint.hasPrefix("/") else { return nil }
        guard FileManager.default.isExecutableFile(atPath: hint) else { return nil }

        let base = (hint as NSString).lastPathComponent
        guard base == name || base.hasPrefix(name + "-") else { return nil }

        let real = URL(fileURLWithPath: hint).resolvingSymlinksInPath().path
        let isTrusted = trustedPrefixes.contains { prefix in
            real == prefix || real.hasPrefix(prefix + "/")
        }
        return isTrusted ? real : nil
    }

    /// Fix 6: bounded so a local client abusing the listener can't grow
    /// `loggedRejectedHints` without bound by POSTing endless distinct hint
    /// values. Once the cap is hit we stop inserting new entries AND stop
    /// logging for hints not already tracked — dedup keeps working up to the
    /// cap, but the set itself stops growing past it.
    private static func logRejectedHint(_ hint: String, name: String) {
        cacheLock.lock()
        var isNew = false
        if !loggedRejectedHints.contains(hint), loggedRejectedHints.count < maxLoggedRejectedHints {
            isNew = loggedRejectedHints.insert(hint).inserted
        }
        cacheLock.unlock()
        if isNew {
            NSLog("ExecutableResolver: rejected untrusted \(name) hint '\(sanitizedForLog(hint))' (not an executable under a trusted install prefix); falling back to the standard search")
        }
    }

    /// `hint` is attacker-controlled (see the SECURITY note on
    /// `isTrustedHint`), and it reaches `NSLog` verbatim in `logRejectedHint`.
    /// A hint containing newlines — trivial to smuggle through a JSON string
    /// field — would otherwise let an attacker forge fake-looking log lines
    /// (log injection). Strip newline/control characters and cap the length
    /// before anything reaches `NSLog`; this sanitized copy is used ONLY for
    /// the log line — `hint` itself, as tracked in `loggedRejectedHints` and
    /// used everywhere else in `resolve`/`isTrustedHint`, is untouched.
    private static func sanitizedForLog(_ raw: String) -> String {
        let truncated = raw.prefix(256)
        let sanitizedScalars = truncated.unicodeScalars.map { scalar -> Character in
            (CharacterSet.newlines.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7f)
                ? " "
                : Character(scalar)
        }
        return String(sanitizedScalars)
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
        // Fix 2b: a profile script that reads stdin (some prompt-y rc files
        // do) must never be able to block us waiting for input we'll never
        // provide — nail it to /dev/null.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()

            // Fix 2a: a blocked/misbehaving login profile (nvm resolving over
            // a dead network, an rc file that prompts, a network-mounted
            // profile) must not hang this thread forever — this runs on
            // `DispatchQueue.global(qos: .userInitiated)`, and callers like
            // `TmuxJumper.runTmux` can invoke `resolve` several times per
            // jump. Bound the wait with a timer that force-terminates the
            // process if it's still running after ~4s; cancel the timer once
            // we're past `waitUntilExit()` so it can't fire (and terminate
            // something else) after the fact — cancelling after the process
            // already exited is a harmless no-op.
            let timeoutWork = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeoutWork)

            // Read before waiting: `command -v` output is tiny, but draining
            // first avoids any chance of blocking on a full pipe buffer. If
            // the process is hung, this read unblocks as soon as the
            // `terminate()` above closes its end of the pipe.
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutWork.cancel()
            // A timeout-triggered `terminate()` (SIGTERM) means the process
            // didn't exit cleanly, so `terminationStatus == 0` already fails
            // in that case — no separate "did we time out" flag needed.
            guard process.terminationStatus == 0 else { return nil }

            // Fix 3: `-lc` sources `.zprofile`/`.zlogin`, so a profile that
            // prints anything at all (motd, a tool banner, `echo "welcome!"`)
            // lands on stdout BEFORE the `command -v` result — e.g.
            // "welcome!\n/opt/homebrew/bin/tmux". Taking the whole trimmed
            // blob would fail the `hasPrefix("/")` check below and report
            // "not found" even though the tool exists. Instead take the LAST
            // non-empty line, which is where `command -v` actually wrote.
            let output = String(data: data, encoding: .utf8) ?? ""
            guard let path = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty })
            else { return nil }

            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let base = (path as NSString).lastPathComponent
            // Fix 5: tightened to match `isTrustedHint` — exact name or a
            // `<name>-` prefix (e.g. `wezterm-gui`), not a bare `hasPrefix`
            // that a lookalike like `weztermXYZ` would also satisfy.
            guard base == name || base.hasPrefix(name + "-") else { return nil }
            return path
        } catch {
            return nil
        }
    }
}
