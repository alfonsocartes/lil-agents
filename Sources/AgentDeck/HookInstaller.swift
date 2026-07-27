import Foundation
import MachO
import Synchronization

/// Installs and removes AgentDeck's lifecycle hooks in Claude Code and Codex CLI.
///
/// Both CLIs are configured to invoke a small generated forwarder script on each
/// lifecycle event. The script reads the hook's stdin JSON, merges in `tool`,
/// `event`, the pane's controlling `tty`, and the owning CLI PID, then POSTs
/// the result — bearing the per-install
/// `X-AgentDeck-Token` header (see `AgentDeck.loadOrCreateToken()`) — to our
/// local listener (`127.0.0.1:<port>/event`) matching the `HookEvent` wire
/// contract in Model.swift.
///
/// Config files are always merged (never clobbered): existing hook entries from
/// other tools/plugins are preserved, and our own entries are only added once
/// (matched by exact command string), making install idempotent.
enum HookInstaller {
    struct Status { var claude: Bool; var codex: Bool }

    // MARK: - Paths

    /// Test seam: redirects the home directory that every hook-config path is
    /// computed from. Default `nil` → the real `homeDirectoryForCurrentUser`,
    /// so production behavior is byte-for-byte unchanged. Tests set this to a
    /// temp dir so install/uninstall never read or mutate the developer's real
    /// `~/.claude/settings.json` or `~/.codex/hooks.json`. Mutex-backed so the
    /// static is concurrency-safe under Swift 6 (tests that set it are also
    /// `.serialized`, but the storage itself must not be a bare mutable global).
    internal static var homeDirectoryOverride: URL? {
        get { homeDirectoryOverrideStorage.withLock { $0 } }
        set { homeDirectoryOverrideStorage.withLock { $0 = newValue } }
    }
    private static let homeDirectoryOverrideStorage = Mutex<URL?>(nil)

    /// True when this code is running inside a test harness (XCTest or
    /// swift-testing). Belt-and-braces on purpose, but each check is verified:
    ///  - `NSClassFromString("XCTestCase")` / the `XCTest*` env vars catch
    ///    XCTest-hosted runs (Xcode test action, xctest bundles).
    ///  - The dyld image scan catches swift-testing under `swift test`, which
    ///    (verified by experiment on this toolchain) runs suites inside
    ///    `swiftpm-testing-helper` with NO test-related env vars and WITHOUT
    ///    XCTest linked — the only reliable in-process signal there is the
    ///    loaded `Testing.framework`/`lib_TestingInterop` image. A production
    ///    app process never loads either, so this can't false-positive.
    ///    (`SWIFT_TESTING`-style env vars were tried first and are NOT set.)
    /// `internal` (not `private`) so a test can assert the detection actually
    /// fires under the real harness — see HookInstallerTests.
    internal static let isRunningUnderTestHarness: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil {
            return true
        }
        for i in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: cName)
            if name.contains("/Testing.framework/")
                || name.contains("libTesting.dylib")
                || name.contains("lib_TestingInterop") {
                return true
            }
        }
        return false
    }()

    private static var homeDirectory: URL {
        if let override = homeDirectoryOverride { return override }
        // Hard guard (from a real incident): a racy early test run reached this
        // path with `homeDirectoryOverride == nil` and rewrote the developer's
        // REAL ~/.claude/settings.json. The test suite is `.serialized` now,
        // but if any future test — or test-ordering change — ever gets here
        // without an override, crash loudly instead of touching the real home.
        // Production (non-test) processes never trip this: the harness checks
        // above are all false outside `swift test`/Xcode test runs.
        if isRunningUnderTestHarness {
            fatalError("""
                HookInstaller: refusing to touch the real home directory from a test process. \
                Set HookInstaller.homeDirectoryOverride to a temp directory before calling any \
                HookInstaller API (see HookInstallerTests.withTempHome).
                """)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var claudeSettingsURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    private static var claudeBackupURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json.agentdeck.bak")
    }

    private static var codexHooksURL: URL {
        homeDirectory.appendingPathComponent(".codex/hooks.json")
    }

    private static var forwarderScriptURL: URL {
        AgentDeck.supportDir.appendingPathComponent("forward-event.sh")
    }

    private static var mergerScriptURL: URL {
        AgentDeck.supportDir.appendingPathComponent("merge-event.py")
    }

    /// Events wired into Claude Code's `~/.claude/settings.json`.
    private static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification",
        "Stop", "SubagentStop", "SessionEnd",
    ]

    /// Events wired into Codex CLI's `~/.codex/hooks.json`.
    ///
    /// Verified against the current Codex hooks schema (developers.openai.com/codex/config-reference,
    /// learn.chatgpt.com/docs/hooks): hooks live under a top-level `"hooks"` object keyed by event
    /// name, each mapping to an array of matcher-groups `{ "matcher": ..., "hooks": [ { "type":
    /// "command", "command": ... } ] }` — structurally the same shape Claude Code uses. Codex hooks
    /// receive one JSON object on stdin (fields include session_id, cwd, hook_event_name, model,
    /// permission_mode), so no `notify`-style argv fallback is needed. `hooks.json` is a fully
    /// documented, first-class config surface (alongside inline `config.toml [hooks]` tables), so we
    /// write there rather than touching TOML.
    ///
    /// `SessionEnd` matters more than it looks: without it a Codex session has
    /// NO end signal at all, so every one-shot `codex exec` left a row that
    /// only the 1-hour stale sweep could ever retire. It is a real event in
    /// Codex's hook enum (verified against the shipped binary's hook-event
    /// wire names, alongside SessionStart/UserPromptSubmit/SubagentStart/
    /// SubagentStop/Stop) — it had simply never been wired up here.
    private static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop",
        "SessionEnd",
    ]

    private static func command(for tool: String, event: String) -> String {
        // The forwarder lives under "Application Support" — a path WITH A SPACE.
        // The command is run through a shell, so the path MUST be quoted or the
        // shell splits it (…/Library/Application → "command not found").
        "'\(forwarderScriptURL.path)' \(tool) \(event)"
    }

    // MARK: - status()

    static func status() -> Status {
        let scriptPath = forwarderScriptURL.path
        let claudeText = (try? String(contentsOf: claudeSettingsURL, encoding: .utf8)) ?? ""
        let codexText = (try? String(contentsOf: codexHooksURL, encoding: .utf8)) ?? ""
        return Status(
            claude: claudeText.contains(scriptPath),
            codex: codexText.contains(scriptPath)
        )
    }

    // MARK: - install(port:)

    static func install(port: UInt16) throws {
        try FileManager.default.createDirectory(at: AgentDeck.supportDir, withIntermediateDirectories: true)
        try writeForwarderScript(port: port)
        try writeMergerScript()
        try installClaudeHooks()
        try installCodexHooks()
    }

    // MARK: - uninstall()

    static func uninstall() throws {
        try uninstallClaudeHooks()
        try uninstallCodexHooks()

        let fm = FileManager.default
        try? fm.removeItem(at: forwarderScriptURL)
        try? fm.removeItem(at: mergerScriptURL)
    }

    // MARK: - Generated scripts

    private static func writeForwarderScript(port: UInt16) throws {
        let supportPath = AgentDeck.supportDir.path
        let tokenPath = AgentDeck.tokenURL.path
        let script = """
        #!/bin/bash
        # AgentDeck event forwarder. Generated by HookInstaller — do not edit by hand.
        # Invoked by CLI hooks as: forward-event.sh <tool> <event>
        # Reads the hook's stdin JSON, merges in tool/event/tty, POSTs it to the
        # local AgentDeck listener. Always exits 0 and never blocks the CLI.
        TOOL="$1"
        EVENT="$2"
        PORT="\(port)"
        SUPPORT_DIR="\(supportPath)"

        # Drain the hook's stdin BEFORE any work at all — including the tty
        # parent-chain walk immediately below, not just the terminal-
        # detection block that follows it. That walk alone can spawn ~2 `ps`
        # calls per ancestor (up to ~64 total for a deep pid tree), and the
        # detection block below it can spawn dozens more. A hook payload
        # larger than the pipe buffer (64KB) would block the calling CLI's
        # write() until we get around to reading it, so reading stdin FIRST
        # — before either piece of work — is what actually keeps this
        # script's "never blocks the CLI" contract intact. Nothing below
        # this point re-reads stdin.
        stdin_json="$(cat)"

        # Identify the CLI process that owns this session, then take THAT
        # process's controlling terminal as the session's pane. Start at our
        # parent rather than $$ so the short-lived forwarder can never be
        # mistaken for the process we should monitor.
        #
        # This used to walk up to the first ancestor that merely HAD a tty,
        # which is wrong the moment one agent spawns another. A headless
        # `codex exec` launched from a Claude Code session has no controlling
        # terminal of its own, so the walk sailed straight past it and
        # reported the PARENT Claude process's pid and tty. Every such run
        # then looked like it lived in the parent's pane and was owned by the
        # parent's (still very much alive) process — so the overlay grew a row
        # per run that nothing could ever retire, and process-exit tracking
        # watched a process that wasn't going to exit.
        #
        # So: find the nearest ancestor whose command name matches this tool,
        # and read the tty from that process alone. An owner with no
        # controlling terminal is reported as headless rather than borrowing
        # an ancestor's pane.
        case "$TOOL" in
          claude) owner_match="claude" ;;
          codex)  owner_match="codex" ;;
          *)      owner_match="" ;;
        esac

        tty=""
        agent_pid=""
        headless=""

        # ONE walk up the ancestors, preferring a command name that IS the tool
        # and falling back to the nearest language runtime.
        #
        # Exact match, not substring: sibling helpers like `codex-code-mode-host`
        # run without a controlling terminal, and matching one of those would
        # mark a real session headless and hide it from the overlay entirely.
        # `ps -o comm=` may print a full path, hence the basename.
        #
        # The runtime fallback exists because a CLI installed as a
        # `#!/usr/bin/env node` shim reports the RUNTIME as its command name,
        # never the script's — the npm shape of Claude Code would otherwise get
        # none of this. Hooks are spawned by the CLI itself, so the nearest
        # runtime ancestor is that CLI.
        #
        # Both are resolved in a single pass on purpose. Running them as two
        # separate walks meant an install pass 2 exists to serve could never
        # match in pass 1, so every hook event walked the whole chain to pid 1
        # before the second walk even started — measured at 18 `ps` forks
        # against 5 for the old code, roughly 60-80ms added to EVERY tool call,
        # since the CLI waits for PreToolUse hooks before running the tool.
        if [ -n "$owner_match" ]; then
          pid=$PPID
          depth=0
          runtime_pid=""
          while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 32 ]; do
            comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
            base="${comm##*/}"
            if [ "$base" = "$owner_match" ]; then
              agent_pid="$pid"
              break
            fi
            if [ -z "$runtime_pid" ]; then
              case "$base" in
                node|bun|deno) runtime_pid="$pid" ;;
              esac
            fi
            pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
            depth=$((depth + 1))
          done
          if [ -z "$agent_pid" ]; then
            agent_pid="$runtime_pid"
          fi
        fi

        if [ -n "$agent_pid" ]; then
          # "??" means the owner genuinely has no controlling terminal. EMPTY
          # means the probe itself told us nothing — `ps` failed, or the owner
          # exited in the gap since the walk above. Those are not the same
          # thing, and treating the second as headless would drop the event in
          # SessionLifecycleCoordinator.receive — including a SessionEnd, which
          # for Codex is the ONLY end signal there is. So claim neither a tty
          # nor headlessness when we simply do not know.
          t="$(ps -o tty= -p "$agent_pid" 2>/dev/null | tr -d ' ')"
          if [ -n "$t" ] && [ "$t" != "??" ]; then
            tty="/dev/$t"
          elif [ "$t" = "??" ]; then
            headless="1"
          fi
        else
          # Owner unidentified. Report a tty for the jump feature if some
          # ancestor has one, but deliberately DO NOT set agent_pid: claiming
          # ownership we cannot substantiate is worse than claiming none. The
          # first ancestor with a terminal is frequently the WRONG process —
          # for a nested agent run it is the parent agent — and asserting that
          # pid would hand the parent's row to this session, evict it, and
          # (because a process-backed row is exempt from stale pruning) leave
          # the replacement in place for as long as the parent lives. Without a
          # pid this degrades to exactly the pre-ownership behavior.
          pid=$PPID
          depth=0
          while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 32 ]; do
            t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
            if [ -n "$t" ] && [ "$t" != "??" ]; then
              tty="/dev/$t"
              break
            fi
            pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
            depth=$((depth + 1))
          done
        fi

        # Detect which terminal (or multiplexer) hosts this pane, for the
        # "jump to pane" feature (see TerminalJumpers.swift). Best-effort —
        # an unrecognized environment just leaves everything below empty and
        # the app falls back to a no-op jump. Order: tmux (it hides the real
        # terminal's env from most detection) first, then $TERM_PROGRAM, then
        # a couple of last-resort env checks.
        terminal=""
        wezterm_pane=""
        wezterm_socket=""
        wezterm_exe=""
        tmux_pane=""
        tmux_socket=""
        tmux_host=""
        host_tty=""

        if [ -n "${TMUX:-}" ]; then
          terminal="tmux"
          tmux_socket="${TMUX%%,*}"
          tmux_pane="${TMUX_PANE:-}"

          # Best-effort: identify the GUI app hosting the tmux client attached
          # to this session, so a jump can also raise ITS window. Takes the
          # FIRST attached client — good enough for the common single-client
          # case.
          #
          # Scope the lookup to THIS pane's session. `tmux list-clients`
          # WITHOUT `-t` lists clients attached to ANY session on the whole
          # tmux server, not just this one. With two terminal windows on one
          # server (e.g. window A on session "work", window B on session
          # "api"), a hook from "api" could pick up window A's client/tty
          # here — and TmuxJumper later runs `switch-client -c <tty> -t
          # "api"`, which would yank window A off the session the user is
          # actively using and hijack it, instead of raising window B where
          # this agent actually is. We scope by session ID rather than
          # session NAME: tmux's `-t` target resolution can prefix-match an
          # unqualified session name (e.g. a lookup for "api" can resolve to
          # "api-staging" on a server that has both), which would silently
          # pick clients from the wrong session and reintroduce the exact
          # hijack this scoping is meant to prevent. Session IDs (e.g. "$3")
          # are unique and never prefix-match, so `-t "$tmux_session_id"` is
          # unambiguous by construction. If resolving the ID fails for any
          # reason, fall back to the old unscoped lookup rather than losing
          # detection entirely.
          tmux_session_id=""
          if [ -n "$tmux_pane" ]; then
            tmux_session_id="$(tmux display-message -p -t "$tmux_pane" '#{session_id}' 2>/dev/null)"
          fi
          if [ -n "$tmux_session_id" ]; then
            client_line="$(tmux list-clients -t "$tmux_session_id" -F '#{client_pid} #{client_tty} #{client_termname}' 2>/dev/null | head -1)"
          else
            client_line="$(tmux list-clients -F '#{client_pid} #{client_tty} #{client_termname}' 2>/dev/null | head -1)"
          fi
          if [ -n "$client_line" ]; then
            client_pid="$(printf '%s' "$client_line" | awk '{print $1}')"
            client_tty_raw="$(printf '%s' "$client_line" | awk '{print $2}')"
            client_termname="$(printf '%s' "$client_line" | awk '{print $3}')"

            # Walk the client pid up the process tree looking for a known GUI app.
            walk_pid="$client_pid"
            depth=0
            while [ -n "$walk_pid" ] && [ "$walk_pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 32 ]; do
              comm="$(ps -o comm= -p "$walk_pid" 2>/dev/null | tr -d ' ')"
              case "$comm" in
                *iTerm2*|*iTerm*) tmux_host="iterm2"; break ;;
                *Terminal*)       tmux_host="apple_terminal"; break ;;
                *WezTerm*|*wezterm*) tmux_host="wezterm"; break ;;
                *Ghostty*|*ghostty*) tmux_host="ghostty"; break ;;
              esac
              walk_pid="$(ps -o ppid= -p "$walk_pid" 2>/dev/null | tr -d ' ')"
              depth=$((depth + 1))
            done

            # Fallback: infer from the client's reported TERM when the
            # process-tree walk didn't match (e.g. sandboxed/renamed process).
            if [ -z "$tmux_host" ]; then
              case "$client_termname" in
                xterm-ghostty) tmux_host="ghostty" ;;
                wezterm)       tmux_host="wezterm" ;;
              esac
            fi

            # Only iTerm2/Terminal support a precise host-window raise (via
            # their own tty-matching osascript) — capture the client's tty
            # for that. WezTerm/Ghostty hosts are activated by app name only.
            if [ "$tmux_host" = "iterm2" ] || [ "$tmux_host" = "apple_terminal" ]; then
              if [ -n "$client_tty_raw" ] && [ "$client_tty_raw" != "??" ]; then
                case "$client_tty_raw" in
                  /dev/*) host_tty="$client_tty_raw" ;;
                  *)      host_tty="/dev/$client_tty_raw" ;;
                esac
              fi
            fi
          fi
        elif [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
          terminal="iterm2"
        elif [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ]; then
          terminal="apple_terminal"
        elif [ "${TERM_PROGRAM:-}" = "WezTerm" ]; then
          terminal="wezterm"
          wezterm_pane="${WEZTERM_PANE:-}"
          wezterm_socket="${WEZTERM_UNIX_SOCKET:-}"
          wezterm_exe="${WEZTERM_EXECUTABLE:-}"
        elif [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
          terminal="ghostty"
        elif [ -n "${GHOSTTY_RESOURCES_DIR:-}" ]; then
          terminal="ghostty"
        elif [ -n "${WEZTERM_PANE:-}" ]; then
          terminal="wezterm"
          wezterm_pane="${WEZTERM_PANE:-}"
          wezterm_socket="${WEZTERM_UNIX_SOCKET:-}"
          wezterm_exe="${WEZTERM_EXECUTABLE:-}"
        fi

        json="$(printf '%s' "$stdin_json" | \\
          AGENTDECK_AGENT_PID="$agent_pid" \\
          AGENTDECK_HEADLESS="$headless" \\
          AGENTDECK_TERMINAL="$terminal" \\
          AGENTDECK_WEZTERM_PANE="$wezterm_pane" \\
          AGENTDECK_WEZTERM_SOCKET="$wezterm_socket" \\
          AGENTDECK_WEZTERM_EXE="$wezterm_exe" \\
          AGENTDECK_TMUX_PANE="$tmux_pane" \\
          AGENTDECK_TMUX_SOCKET="$tmux_socket" \\
          AGENTDECK_TMUX_HOST="$tmux_host" \\
          AGENTDECK_HOST_TTY="$host_tty" \\
          /usr/bin/python3 "$SUPPORT_DIR/merge-event.py" "$TOOL" "$EVENT" "$tty" 2>/dev/null)"

        if [ -n "$json" ]; then
          # Read the per-install bearer token the listener requires on every
          # request (see EventListener.swift). Read fresh each time rather than
          # cached, so a token rotation takes effect on the next event.
          token=$(cat '\(tokenPath)' 2>/dev/null)

          # -f: treat a non-2xx response (wrong/missing token, or some other
          #     process entirely squatting on the port) as a curl failure.
          # -s -S: quiet on success, but -S still surfaces real errors to stderr
          #     (which we discard below) rather than the default silent -s.
          # -m 2: never let a wedged/absent listener block the CLI hook.
          # `|| exit 0`: any failure here — squatter, stale token, connection
          #     refused — is intentionally a silent no-op rather than surfaced
          #     to the CLI. (Residual: a squatter that wins the port before
          #     AgentDeck ever launches could observe one token value on the
          #     first POST; this is a same-host, low-severity residual — see
          #     the bind-failure log in EventListener.swift for the detection
          #     side of this mitigation.)
          curl -fsS -m 2 -X POST \\
            -H 'Content-Type: application/json' \\
            -H "X-AgentDeck-Token: $token" \\
            -d "$json" \\
            "http://127.0.0.1:$PORT/event" >/dev/null 2>&1 || exit 0
        fi

        exit 0
        """
        try script.write(to: forwarderScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: forwarderScriptURL.path)
    }

    private static func writeMergerScript() throws {
        let script = """
        #!/usr/bin/env python3
        # AgentDeck event merger. Generated by HookInstaller — do not edit by hand.
        # Reads the hook's stdin JSON, overlays tool/event/tty plus the
        # terminal-jump fields (passed via AGENTDECK_* env vars rather than argv,
        # so this stays stable as fields are added), prints merged JSON.
        import json
        import os
        import sys


        # Maps each optional terminal-jump JSON key to the env var the forwarder
        # sets it from (see HookInstaller.swift's writeForwarderScript). Only
        # non-empty values are added, so old/undetected fields simply don't
        # appear — HookEvent.swift decodes their absence as nil.
        ENV_FIELDS = {
            "terminal": "AGENTDECK_TERMINAL",
            "wezterm_pane": "AGENTDECK_WEZTERM_PANE",
            "wezterm_socket": "AGENTDECK_WEZTERM_SOCKET",
            "wezterm_exe": "AGENTDECK_WEZTERM_EXE",
            "tmux_pane": "AGENTDECK_TMUX_PANE",
            "tmux_socket": "AGENTDECK_TMUX_SOCKET",
            "tmux_host": "AGENTDECK_TMUX_HOST",
            "host_tty": "AGENTDECK_HOST_TTY",
        }


        def main() -> None:
            tool = sys.argv[1] if len(sys.argv) > 1 else ""
            event = sys.argv[2] if len(sys.argv) > 2 else ""
            tty = sys.argv[3] if len(sys.argv) > 3 else ""

            raw = sys.stdin.read()
            data = {}
            try:
                parsed = json.loads(raw) if raw.strip() else {}
                if isinstance(parsed, dict):
                    data = parsed
            except Exception:
                data = {}

            data["tool"] = tool
            data["event"] = event
            if tty:
                data["tty"] = tty

            for key, env_name in ENV_FIELDS.items():
                value = os.environ.get(env_name, "")
                if value:
                    data[key] = value

            # Never trust a PID or a headless claim supplied by the CLI hook
            # payload itself. Only the locally generated forwarder may assert
            # process ownership or how the session was launched.
            data.pop("agent_pid", None)
            agent_pid = os.environ.get("AGENTDECK_AGENT_PID", "")
            if agent_pid.isdecimal() and int(agent_pid) > 1:
                data["agent_pid"] = int(agent_pid)

            data.pop("headless", None)
            if os.environ.get("AGENTDECK_HEADLESS", ""):
                data["headless"] = True

            print(json.dumps(data))


        if __name__ == "__main__":
            main()
        """
        try script.write(to: mergerScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mergerScriptURL.path)
    }

    // MARK: - Claude Code (~/.claude/settings.json)

    private static func installClaudeHooks() throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeSettingsURL) {
            // Back up the ORIGINAL settings exactly once. install() runs on every
            // launch, so overwriting an existing backup would clobber the pristine
            // pre-AgentDeck copy with an already-hook-modified one.
            if !fm.fileExists(atPath: claudeBackupURL.path) {
                try? data.write(to: claudeBackupURL)
            }
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            }
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            hooks[event] = upsertGroups(hooks[event], command: command(for: "claude", event: event))
        }
        root["hooks"] = hooks

        try fm.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeSettingsURL, options: .atomic)
    }

    private static func uninstallClaudeHooks() throws {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return }

        let remaining = prunedHooks(hooks)
        root["hooks"] = remaining.isEmpty ? nil : remaining

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: claudeSettingsURL, options: .atomic)
    }

    // MARK: - Codex CLI (~/.codex/hooks.json)

    private static func installCodexHooks() throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: codexHooksURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in codexEvents {
            hooks[event] = upsertGroups(hooks[event], command: command(for: "codex", event: event), matcher: ".*")
        }
        root["hooks"] = hooks
        if root["description"] == nil {
            root["description"] = "AgentDeck lifecycle hooks — forwards session events to the AgentDeck overlay."
        }

        try fm.createDirectory(at: codexHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: codexHooksURL, options: .atomic)
    }

    private static func uninstallCodexHooks() throws {
        guard let data = try? Data(contentsOf: codexHooksURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return }

        let remaining = prunedHooks(hooks)
        root["hooks"] = remaining.isEmpty ? nil : remaining

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: codexHooksURL, options: .atomic)
    }

    // MARK: - Shared matcher-group merge/prune helpers
    //
    // Both Claude Code and Codex CLI use the same hook shape for a given event:
    // an array of matcher-groups, each `{ "matcher": <string>, "hooks": [ { "type":
    // "command", "command": <string> } ] }`. These helpers add/remove our own
    // command idempotently while leaving any other tool's entries untouched.

    /// Returns `existing` (an `Any?` expected to be `[[String: Any]]`) with a group
    /// added for `command`, unless a group already contains that exact command.
    // `internal` (not `private`) so unit tests can exercise the pure merge logic directly.
    internal static func mergedGroups(_ existing: Any?, adding command: String, matcher: String = "") -> [[String: Any]] {
        var groups = existing as? [[String: Any]] ?? []
        let alreadyPresent = groups.contains { group in
            let entries = group["hooks"] as? [[String: Any]] ?? []
            return entries.contains { ($0["command"] as? String) == command }
        }
        if !alreadyPresent {
            let entry: [String: Any] = ["type": "command", "command": command]
            groups.append(["matcher": matcher, "hooks": [entry]])
        }
        return groups
    }

    /// Self-healing add: removes ANY prior entry that references our forwarder
    /// script path (catching stale/broken variants — e.g. the old unquoted command
    /// that the shell mis-split), then appends the one correct `command`. Foreign
    /// hooks (whose command doesn't contain our script path) are left untouched.
    // `internal` (not `private`) so unit tests can exercise the pure merge logic directly.
    internal static func upsertGroups(_ existing: Any?, command: String, matcher: String = "") -> [[String: Any]] {
        let scriptPath = forwarderScriptURL.path
        var groups = (existing as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
            guard var entries = group["hooks"] as? [[String: Any]] else { return group }
            entries.removeAll { ($0["command"] as? String)?.contains(scriptPath) == true }
            if entries.isEmpty { return nil }   // was only ours → drop the empty group
            var g = group
            g["hooks"] = entries
            return g
        }
        groups.append(["matcher": matcher, "hooks": [["type": "command", "command": command]]])
        return groups
    }

    /// Returns `hooks` with every entry referencing our forwarder script
    /// removed, from EVERY event key present — not just the ones in
    /// `claudeEvents`/`codexEvents` — dropping matcher-groups and then event
    /// keys that become empty. Foreign hooks are left untouched.
    ///
    /// Matching by script path rather than by exact command string is what
    /// makes uninstall survive the event lists changing. An older build's
    /// uninstall iterated its own (shorter) list, so a hook a newer build had
    /// added was invisible to it — while `uninstall()` still deleted the
    /// forwarder that entry pointed at, leaving the config permanently
    /// invoking a script that no longer exists. This mirrors the self-healing
    /// `upsertGroups` already does on the install side.
    // `internal` (not `private`) so unit tests can exercise the pure prune logic directly.
    internal static func prunedHooks(_ hooks: [String: Any]) -> [String: Any] {
        let scriptPath = forwarderScriptURL.path
        var pruned: [String: Any] = [:]
        for (event, value) in hooks {
            // A shape we don't understand is left exactly as found.
            guard let groups = value as? [[String: Any]] else {
                pruned[event] = value
                continue
            }

            var removedAny = false
            let kept = groups.compactMap { group -> [String: Any]? in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                let before = entries.count
                entries.removeAll { ($0["command"] as? String)?.contains(scriptPath) == true }
                if entries.count != before { removedAny = true }
                guard !entries.isEmpty else { return nil }
                var survivor = group
                survivor["hooks"] = entries
                return survivor
            }

            // Drop the key only when it is empty BECAUSE we emptied it. An
            // already-empty foreign key is somebody else's config, and
            // deleting it would break the promise that uninstall only ever
            // removes our own entries.
            if !kept.isEmpty || !removedAny {
                pruned[event] = kept
            }
        }
        return pruned
    }
}
