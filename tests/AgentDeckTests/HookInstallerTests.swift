import Foundation
import Testing
@testable import AgentDeck

// Serialized: these tests mutate the process-global `homeDirectoryOverride`,
// so they must not interleave with each other under swift-testing's default
// parallelism (no other suite touches that static).
@Suite(.serialized) struct HookInstallerTests {
    /// Absolute path to the generated forwarder our commands reference. Computed
    /// from the (accessible) support dir so tests don't need HookInstaller's
    /// private URL.
    private var scriptPath: String {
        AgentDeck.supportDir.appendingPathComponent("forward-event.sh").path
    }

    private func claudeSettingsURL(_ home: URL) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    private func seedClaude(_ home: URL, _ root: [String: Any]) {
        let url = claudeSettingsURL(home)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try! JSONSerialization.data(withJSONObject: root)
        try! data.write(to: url)
    }

    private func codexHooksURL(_ home: URL) -> URL {
        home.appendingPathComponent(".codex/hooks.json")
    }

    private func seedCodex(_ home: URL, _ root: [String: Any]) {
        let url = codexHooksURL(home)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try! JSONSerialization.data(withJSONObject: root)
        try! data.write(to: url)
    }

    private func agentDeckEntry(tool: String, event: String, timeout: Int? = 10) -> [String: Any] {
        var entry: [String: Any] = [
            "type": "command",
            "command": "'\(scriptPath)' \(tool) \(event)",
        ]
        if let timeout { entry["timeout"] = timeout }
        return entry
    }

    private func agentDeckGroup(tool: String, event: String, matcher: String, timeout: Int? = 10) -> [String: Any] {
        ["matcher": matcher, "hooks": [agentDeckEntry(tool: tool, event: event, timeout: timeout)]]
    }

    /// Seeds every Claude event with the quoted AgentDeck command (and timeout
    /// unless `timeout` is nil). Optional extra PreToolUse group is prepended.
    private func seedCorrectClaude(
        _ home: URL,
        timeout: Int? = 10,
        extraPreToolUse: [String: Any]? = nil
    ) {
        let events = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification",
            "Stop", "SubagentStop", "SessionEnd",
        ]
        var hooks: [String: Any] = [:]
        for event in events {
            var groups: [[String: Any]] = [
                agentDeckGroup(tool: "claude", event: event, matcher: "", timeout: timeout)
            ]
            if event == "PreToolUse", let extraPreToolUse {
                groups.insert(extraPreToolUse, at: 0)
            }
            hooks[event] = groups
        }
        seedClaude(home, ["hooks": hooks])
    }

    /// Seeds every Codex event with the quoted AgentDeck command (matcher `.*`).
    private func seedCorrectCodex(
        _ home: URL,
        timeout: Int? = 10,
        matcher: String = ".*",
        extraPreToolUse: [String: Any]? = nil
    ) {
        let events = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop",
            "SessionEnd",
        ]
        var hooks: [String: Any] = [:]
        for event in events {
            var groups: [[String: Any]] = [
                agentDeckGroup(tool: "codex", event: event, matcher: matcher, timeout: timeout)
            ]
            if event == "PreToolUse", let extraPreToolUse {
                groups.insert(extraPreToolUse, at: 0)
            }
            hooks[event] = groups
        }
        seedCodex(home, ["hooks": hooks])
    }

    /// Every command string wired for `event` in the temp home's settings.json.
    private func claudeCommands(_ home: URL, event: String) -> [String] {
        guard let data = try? Data(contentsOf: claudeSettingsURL(home)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]]
        else { return [] }
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// Runs `body` with BOTH the hook-config home and the runtime support
    /// directory redirected at fresh temp dirs, then restores the overrides.
    ///
    /// The support dir matters as much as the home dir: `install()` writes the
    /// generated forwarder there and `uninstall()` deletes it, so without this
    /// a test run removed the developer's live `forward-event.sh` and broke
    /// hook delivery for every running CLI session until the app relaunched.
    private func withTempHome(_ body: (URL) throws -> Void) rethrows {
        let home = makeTempDir()
        let support = makeTempDir()
        HookInstaller.homeDirectoryOverride = home
        AgentDeck.supportDirOverride = support
        defer {
            HookInstaller.homeDirectoryOverride = nil
            AgentDeck.supportDirOverride = nil
            cleanup(home)
            cleanup(support)
        }
        try body(home)
    }

    private func runGeneratedMerger(
        input: [String: Any],
        discoveredPID: String?
    ) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            AgentDeck.supportDir.appendingPathComponent("merge-event.py").path,
            "claude",
            "SessionStart",
            "/dev/ttys001",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTDECK_AGENT_PID"] = discoveredPID
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(
            JSONSerialization.data(withJSONObject: input)
        )
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    /// Every command string wired for `event` in the temp home's Codex hooks.
    private func codexCommands(_ home: URL, event: String) -> [String] {
        let url = home.appendingPathComponent(".codex/hooks.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]]
        else { return [] }
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// Runs the REAL generated forwarder against a synthetic process tree.
    ///
    /// `ps` and `curl` are shadowed by stubs on PATH: the `ps` stub answers
    /// `-o comm=/-o ppid=/-o tty=` from `tree` (keyed by pid, and rooted at
    /// this test process — the forwarder starts its walk at `$PPID`), and the
    /// `curl` stub captures the POST body. That makes the bash owner-resolution
    /// logic itself testable, which is where the mis-attribution bug lived.
    private struct FakeProcess {
        let comm: String
        let ppid: Int32
        let tty: String        // "??" for no controlling terminal
    }

    private func grokHooksURL(_ home: URL) -> URL {
        home.appendingPathComponent(".grok/hooks/agentdeck.json")
    }

    /// Every command string wired for `event` in the temp home's Grok hooks.
    private func grokCommands(_ home: URL, event: String) -> [String] {
        grokHandlers(home, event: event).compactMap { $0["command"] as? String }
    }

    private func grokHandlers(_ home: URL, event: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: grokHooksURL(home)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]]
        else { return [] }
        return groups.flatMap { group in
            group["hooks"] as? [[String: Any]] ?? []
        }
    }

    private func claudeHandlers(_ home: URL, event: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: claudeSettingsURL(home)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]]
        else { return [] }
        return groups.flatMap { group in
            group["hooks"] as? [[String: Any]] ?? []
        }
    }

    private func codexHandlers(_ home: URL, event: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: codexHooksURL(home)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]]
        else { return [] }
        return groups.flatMap { group in
            group["hooks"] as? [[String: Any]] ?? []
        }
    }

    private func runGeneratedForwarder(
        tool: String,
        event: String,
        tree: [Int32: FakeProcess],
        stdin: [String: Any] = ["session_id": "s1", "cwd": "/private/tmp"],
        extraEnv: [String: String] = [:]
    ) throws -> [String: Any] {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let table = dir.appendingPathComponent("tree")
        let rows = tree.map { "\($0.key):\($0.value.comm):\($0.value.ppid):\($0.value.tty)" }
        try rows.joined(separator: "\n").write(to: table, atomically: true, encoding: .utf8)

        let capture = dir.appendingPathComponent("posted.json")
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let psStub = """
        #!/bin/bash
        field=""; pid=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) field="${2%=}"; shift 2 ;;
            -p) pid="$2"; shift 2 ;;
            *)  shift ;;
          esac
        done
        row="$(grep "^$pid:" "$FAKE_PS_TREE" 2>/dev/null | head -1)"
        [ -z "$row" ] && exit 1
        IFS=':' read -r _ comm ppid tty <<< "$row"
        case "$field" in
          comm) printf '%s\\n' "$comm" ;;
          ppid) printf '%s\\n' "$ppid" ;;
          tty)  printf '%s\\n' "$tty" ;;
        esac
        """
        let curlStub = """
        #!/bin/bash
        body=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -d)
              body="$2"; shift 2 ;;
            --data-binary|--data)
              src="${2:-}"; shift 2
              if [ "$src" = "@-" ] || [ "$src" = "-" ]; then
                body="$(cat)"
              elif [ "${src#@}" != "$src" ]; then
                body="$(cat "${src#@}")"
              else
                body="$src"
              fi
              ;;
            *) shift ;;
          esac
        done
        printf '%s' "$body" > "$FAKE_CURL_CAPTURE"
        """
        for (name, source) in [("ps", psStub), ("curl", curlStub)] {
            let url = bin.appendingPathComponent(name)
            try source.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            AgentDeck.supportDir.appendingPathComponent("forward-event.sh").path,
            tool,
            event,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_PS_TREE"] = table.path
        environment["FAKE_CURL_CAPTURE"] = capture.path
        // Terminal detection must not key off the harness's own environment.
        for key in ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR", "GROK_HOOK_EVENT"] {
            environment.removeValue(forKey: key)
        }
        for (key, value) in extraEnv {
            environment[key] = value
        }
        process.environment = environment

        let input = Pipe()
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(JSONSerialization.data(withJSONObject: stdin))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let posted = try Data(contentsOf: capture)
        return try #require(JSONSerialization.jsonObject(with: posted) as? [String: Any])
    }

    /// A headless `codex exec` launched from a Claude Code session: only the
    /// `claude` process at the top of the chain has a tty.
    private var nestedAgentTree: [Int32: FakeProcess] {
        [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "swiftpm-testing-helper", ppid: 9001, tty: "??"),
            9001: FakeProcess(comm: "/opt/homebrew/bin/codex", ppid: 9002, tty: "??"),
            9002: FakeProcess(comm: "node", ppid: 9003, tty: "??"),
            9003: FakeProcess(comm: "claude", ppid: 1, tty: "ttys003"),
        ]
    }

    /// The defense-in-depth home guard (see `HookInstaller.homeDirectory`) only
    /// protects the real ~/.claude if the harness detection actually fires in
    /// THIS process. Verified by experiment: under `swift test` the suite runs
    /// in swiftpm-testing-helper, where only the dyld Testing-framework scan
    /// detects the harness (no XCTest class, no XCTest* env vars). If this
    /// expectation ever fails, the fatalError guard is dead code and a test
    /// reaching HookInstaller without an override would silently write to the
    /// real home directory again.
    @Test func harnessDetectionFiresUnderTheTestRunner() {
        #expect(HookInstaller.isRunningUnderTestHarness)
    }

    @Test func installIsIdempotent() throws {
        try withTempHome { home in
            try HookInstaller.install(port: AgentDeck.port)
            try HookInstaller.install(port: AgentDeck.port)   // double install
            let ours = claudeCommands(home, event: "PreToolUse").filter { $0.contains(scriptPath) }
            #expect(ours.count == 1)                          // exactly one entry, not two
        }
    }

    @Test func foreignHookSurvivesInstallAndUninstall() throws {
        try withTempHome { home in
            let foreign = "/opt/othertool/hook.sh run"
            seedClaude(home, [
                "hooks": ["PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": foreign]]]]],
            ])

            try HookInstaller.install(port: AgentDeck.port)
            var cmds = claudeCommands(home, event: "PreToolUse")
            #expect(cmds.contains(foreign))                    // foreign preserved
            #expect(cmds.contains { $0.contains(scriptPath) }) // ours added

            try HookInstaller.uninstall()
            cmds = claudeCommands(home, event: "PreToolUse")
            #expect(cmds.contains(foreign))                    // foreign STILL there
            #expect(!cmds.contains { $0.contains(scriptPath) })// only ours removed
        }
    }

    @Test func upsertHealsStaleForwarderVariant() throws {
        try withTempHome { home in
            // An old, unquoted variant that still references our forwarder path.
            let stale = "\(scriptPath) claude PreToolUse"
            seedClaude(home, [
                "hooks": ["PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": stale]]]]],
            ])

            try HookInstaller.install(port: AgentDeck.port)
            let cmds = claudeCommands(home, event: "PreToolUse")
            let ours = cmds.filter { $0.contains(scriptPath) }
            #expect(ours.count == 1)                           // healed, not duplicated
            #expect(!cmds.contains(stale))                     // stale variant gone
            #expect(ours.first == "'\(scriptPath)' claude PreToolUse") // correct quoted form
        }
    }

    @Test func generatedScriptsCaptureAndEncodeOwningProcessPID() throws {
        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let support = AgentDeck.supportDir
            let forwarder = try String(
                contentsOf: support.appendingPathComponent("forward-event.sh"),
                encoding: .utf8
            )
            let merger = try String(
                contentsOf: support.appendingPathComponent("merge-event.py"),
                encoding: .utf8
            )

            #expect(forwarder.contains("pid=$PPID"))
            #expect(forwarder.contains("agent_pid=\"$pid\""))
            #expect(forwarder.contains("AGENTDECK_AGENT_PID=\"$agent_pid\""))
            #expect(forwarder.contains("--data-binary @-"))
            #expect(!forwarder.contains("-d \"$json\""))
            #expect(merger.contains("data.pop(\"agent_pid\", None)"))

            let valid = try runGeneratedMerger(
                input: ["session_id": "s", "agent_pid": 999],
                discoveredPID: "123"
            )
            #expect(valid["agent_pid"] as? Int == 123)

            let missing = try runGeneratedMerger(
                input: ["session_id": "s", "agent_pid": 999],
                discoveredPID: nil
            )
            #expect(missing["agent_pid"] == nil)

            let malformed = try runGeneratedMerger(
                input: ["session_id": "s", "agent_pid": 999],
                discoveredPID: "not-a-pid"
            )
            #expect(malformed["agent_pid"] == nil)
        }
    }

    /// Without SessionEnd a Codex session has no end signal whatsoever, so
    /// every one-shot `codex exec` parked a row until the 1-hour stale sweep.
    @Test func codexHooksIncludeSessionEnd() throws {
        try withTempHome { home in
            try HookInstaller.install(port: AgentDeck.port)

            let ours = codexCommands(home, event: "SessionEnd")
            #expect(ours == ["'\(scriptPath)' codex SessionEnd"])

            try HookInstaller.uninstall()
            #expect(codexCommands(home, event: "SessionEnd").isEmpty)
        }
    }

    /// The bug: the forwarder walked up to the first ancestor that HAD a tty,
    /// so a headless `codex exec` was attributed to the parent Claude process's
    /// pid and pane.
    @Test func forwarderAttributesNestedRunToItsOwnCLINotTheParentAgent() throws {
        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(
                tool: "codex", event: "Stop", tree: nestedAgentTree
            )

            #expect(posted["agent_pid"] as? Int == 9001)   // the codex process
            #expect(posted["headless"] as? Bool == true)   // which owns no tty
            #expect(posted["tty"] == nil)                  // and borrows nobody's
        }
    }

    @Test func forwarderResolvesAnInteractiveCLIToItsOwnPane() throws {
        // A native install in a terminal: the hook's shell, then the CLI.
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9003, tty: "??"),
            9003: FakeProcess(comm: "/usr/local/bin/claude", ppid: 1, tty: "ttys003"),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(tool: "claude", event: "Stop", tree: tree)

            #expect(posted["agent_pid"] as? Int == 9003)
            #expect(posted["tty"] as? String == "/dev/ttys003")
            #expect(posted["headless"] == nil)
        }
    }

    /// The nearest plausible CLI wins. Preferring an exact name match at any
    /// depth would attribute a nested npm-installed run to the native `claude`
    /// further up the chain — handing it the parent's pid and pane, which is
    /// the mis-attribution this routine exists to prevent.
    @Test func forwarderPrefersTheNearestOwnerOverAFartherExactMatch() throws {
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9401, tty: "??"),
            // Nested `claude -p`, npm-installed, so it presents as the runtime.
            9401: FakeProcess(comm: "/Users/x/.nvm/versions/node/v24/bin/node", ppid: 9402, tty: "??"),
            9402: FakeProcess(comm: "zsh", ppid: 9403, tty: "??"),
            // The native interactive session that ultimately spawned it.
            9403: FakeProcess(comm: "/usr/local/bin/claude", ppid: 1, tty: "ttys077"),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(tool: "claude", event: "Stop", tree: tree)

            #expect(posted["agent_pid"] as? Int == 9401)   // the nested run
            #expect(posted["headless"] as? Bool == true)
            #expect(posted["tty"] == nil)                  // never ttys077
        }
    }

    /// An unidentifiable owner reports a tty for the jump feature but claims NO
    /// pid. Asserting the first tty-owning ancestor — which for a nested run is
    /// the parent agent — would hand the parent's row to this session, evict
    /// it, and (since a process-backed row is exempt from stale pruning) keep
    /// the replacement for as long as the parent lives.
    @Test func forwarderClaimsNoOwnershipWhenItCannotIdentifyTheOwner() throws {
        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(
                tool: "someothertool", event: "Stop", tree: nestedAgentTree
            )

            #expect(posted["agent_pid"] == nil)
            #expect(posted["tty"] as? String == "/dev/ttys003")
            #expect(posted["headless"] == nil)
        }
    }

    /// The npm shape: a `#!/usr/bin/env node` shim reports the interpreter as
    /// its command name, so name matching alone would miss the CLI entirely and
    /// this whole feature would be inert for those installs.
    @Test func forwarderResolvesInterpreterBackedInstallsToTheNearestRuntime() throws {
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9101, tty: "??"),
            // Nested `claude -p`, no controlling terminal of its own.
            9101: FakeProcess(comm: "/Users/x/.nvm/versions/node/v24/bin/node", ppid: 9102, tty: "??"),
            // The interactive session that spawned it.
            9102: FakeProcess(comm: "/Users/x/.nvm/versions/node/v24/bin/node", ppid: 1, tty: "ttys088"),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(tool: "claude", event: "Stop", tree: tree)

            #expect(posted["agent_pid"] as? Int == 9101)   // the nested run
            #expect(posted["headless"] as? Bool == true)
            #expect(posted["tty"] == nil)                  // never the parent's pane
        }
    }

    /// Matching the tool name as a substring would catch sibling helpers that
    /// run without a controlling terminal, and the headless rule would then
    /// silently hide a real session that has a perfectly good pane.
    @Test func forwarderDoesNotMatchSiblingHelpersNamedAfterTheTool() throws {
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9201, tty: "??"),
            9201: FakeProcess(comm: "/opt/codex/bin/codex-code-mode-host", ppid: 9202, tty: "??"),
            9202: FakeProcess(comm: "/opt/codex/bin/codex", ppid: 1, tty: "ttys012"),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(tool: "codex", event: "Stop", tree: tree)

            #expect(posted["agent_pid"] as? Int == 9202)
            #expect(posted["tty"] as? String == "/dev/ttys012")
            #expect(posted["headless"] == nil)
        }
    }

    /// An owner whose tty probe returns nothing at all is UNKNOWN, not
    /// headless. Conflating the two drops the event in the coordinator —
    /// including SessionEnd, which for Codex is the only end signal there is.
    @Test func forwarderDoesNotCallAnOwnerHeadlessWhenTheProbeFails() throws {
        // ttyProbeFails: this pid answers comm/ppid but has no tty row at all,
        // which is what a failed `ps -o tty=` looks like to the script.
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9301, tty: ""),
            9301: FakeProcess(comm: "/usr/local/bin/claude", ppid: 1, tty: ""),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(
                tool: "claude", event: "SessionEnd", tree: tree
            )

            #expect(posted["agent_pid"] as? Int == 9301)
            #expect(posted["headless"] == nil)   // unknown, so not suppressed
            #expect(posted["tty"] == nil)
        }
    }

    /// Uninstall leaves a foreign event key that was already empty alone —
    /// deleting it would break the promise that we only remove our own
    /// entries, and an empty array is somebody else's config.
    @Test func uninstallPreservesForeignKeysThatWereAlreadyEmpty() throws {
        try withTempHome { home in
            seedClaude(home, ["hooks": ["PostToolUse": [], "Notification": []]])

            try HookInstaller.install(port: AgentDeck.port)
            try HookInstaller.uninstall()

            let data = try #require(try? Data(contentsOf: claudeSettingsURL(home)))
            let root = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hooks = root["hooks"] as? [String: Any] ?? [:]

            // PostToolUse was never ours and stays; Notification held only our
            // entry after install, so it goes.
            #expect(hooks["PostToolUse"] as? [[String: Any]] != nil)
            #expect(hooks["Notification"] == nil)
        }
    }

    /// Uninstall must remove hook entries pointing at our forwarder even for
    /// events this build has never heard of — otherwise an older binary's
    /// uninstall leaves a newer one's entry behind while still deleting the
    /// script it invokes.
    @Test func uninstallRemovesForwarderEntriesForUnknownEvents() throws {
        try withTempHome { home in
            let foreign = "/opt/othertool/hook.sh run"
            let ours = "'\(scriptPath)' claude SomeFutureEvent"
            seedClaude(home, [
                "hooks": [
                    "SomeFutureEvent": [
                        ["matcher": "", "hooks": [["type": "command", "command": ours]]],
                        ["matcher": "", "hooks": [["type": "command", "command": foreign]]],
                    ]
                ],
            ])

            try HookInstaller.install(port: AgentDeck.port)
            try HookInstaller.uninstall()

            let remaining = claudeCommands(home, event: "SomeFutureEvent")
            #expect(remaining == [foreign])
        }
    }

    @Test func grokInstallWritesOwnedHookFile() throws {
        try withTempHome { home in
            try HookInstaller.install(port: AgentDeck.port)
            try HookInstaller.install(port: AgentDeck.port)

            let events = [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification",
                "Stop", "StopFailure", "StopCancelled", "SessionEnd", "SubagentStop",
            ]
            for event in events {
                let handlers = grokHandlers(home, event: event)
                #expect(handlers.count == 1)
                #expect(handlers.first?["command"] as? String == "'\(scriptPath)' grok \(event)")
                #expect(handlers.first?["timeout"] as? Int == 10)
            }
        }
    }

    @Test func grokUninstallDeletesOnlyOurFile() throws {
        try withTempHome { home in
            let sibling = home.appendingPathComponent(".grok/hooks/other.json")
            try FileManager.default.createDirectory(
                at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: sibling)

            try HookInstaller.install(port: AgentDeck.port)
            #expect(FileManager.default.fileExists(atPath: grokHooksURL(home).path))

            try HookInstaller.uninstall()
            #expect(!FileManager.default.fileExists(atPath: grokHooksURL(home).path))
            #expect(FileManager.default.fileExists(atPath: sibling.path))
        }
    }

    @Test func grokStatusTracksInstallAndUninstall() throws {
        try withTempHome { _ in
            #expect(!HookInstaller.status().grok)
            try HookInstaller.install(port: AgentDeck.port)
            #expect(HookInstaller.status().grok)
            try HookInstaller.uninstall()
            #expect(!HookInstaller.status().grok)
        }
    }

    @Test func mergerMapsGrokCamelCaseWithoutOverwritingSnakeCase() throws {
        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let mapped = try runGeneratedMerger(
                input: ["sessionId": "uuid-1", "notificationType": "permission_prompt"],
                discoveredPID: nil
            )
            #expect(mapped["session_id"] as? String == "uuid-1")
            #expect(mapped["notification_type"] as? String == "permission_prompt")

            let preserved = try runGeneratedMerger(
                input: [
                    "sessionId": "camel",
                    "session_id": "snake",
                    "notificationType": "permission_prompt",
                    "notification_type": "idle_prompt",
                ],
                discoveredPID: nil
            )
            #expect(preserved["session_id"] as? String == "snake")
            #expect(preserved["notification_type"] as? String == "idle_prompt")
        }
    }

    @Test func forwarderResolvesAnInteractiveGrokToItsOwnPane() throws {
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9703, tty: "??"),
            9703: FakeProcess(comm: "/usr/local/bin/grok", ppid: 1, tty: "ttys003"),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(tool: "grok", event: "Stop", tree: tree)

            #expect(posted["agent_pid"] as? Int == 9703)
            #expect(posted["tty"] as? String == "/dev/ttys003")
            #expect(posted["headless"] == nil)
        }
    }

    @Test func forwarderRetagsClaudeCompatDualFireAsGrok() throws {
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9801, tty: "??"),
            9801: FakeProcess(comm: "/usr/local/bin/grok", ppid: 9802, tty: "ttys010"),
            9802: FakeProcess(comm: "/usr/local/bin/claude", ppid: 1, tty: "ttys003"),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(
                tool: "claude",
                event: "Stop",
                tree: tree,
                extraEnv: ["GROK_HOOK_EVENT": "stop"]
            )

            #expect(posted["tool"] as? String == "grok")
            #expect(posted["agent_pid"] as? Int == 9801)
            #expect(posted["tty"] as? String == "/dev/ttys010")
        }
    }

    @Test func forwarderMapsGrokCamelCaseSessionId() throws {
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9903, tty: "??"),
            9903: FakeProcess(comm: "/usr/local/bin/grok", ppid: 1, tty: "ttys003"),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(
                tool: "grok",
                event: "Stop",
                tree: tree,
                stdin: ["sessionId": "uuid-1"]
            )

            #expect(posted["session_id"] as? String == "uuid-1")
        }
    }

    @Test func installThrowsOnUnreadableClaudeSettings() throws {
        try withTempHome { home in
            let url = claudeSettingsURL(home)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("{not json".utf8)
            try original.write(to: url)

            #expect(throws: HookInstaller.Error.unreadableConfig(url)) {
                try HookInstaller.install(port: AgentDeck.port)
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(FileManager.default.fileExists(atPath: grokHooksURL(home).path))
            #expect(FileManager.default.fileExists(atPath: codexHooksURL(home).path))
        }
    }

    @Test func installThrowsOnUnreadableCodexHooks() throws {
        try withTempHome { home in
            let url = codexHooksURL(home)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("{not json".utf8)
            try original.write(to: url)

            #expect(throws: HookInstaller.Error.unreadableConfig(url)) {
                try HookInstaller.install(port: AgentDeck.port)
            }
            #expect(try Data(contentsOf: url) == original)
            #expect(FileManager.default.fileExists(atPath: grokHooksURL(home).path))
            #expect(claudeCommands(home, event: "PreToolUse").contains { $0.contains(scriptPath) })
        }
    }

    @Test func installThrowsWhenClaudeHooksValueIsNotAnObject() throws {
        try withTempHome { home in
            seedClaude(home, ["hooks": ["not", "an", "object"], "statusLine": "keep-me"])
            let url = claudeSettingsURL(home)
            let original = try Data(contentsOf: url)

            #expect(throws: HookInstaller.Error.unreadableConfig(url)) {
                try HookInstaller.install(port: AgentDeck.port)
            }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func installDoesNotRewriteClaudeWhenEntriesAreAlreadyCorrect() throws {
        try withTempHome { home in
            let foreign: [String: Any] = [
                "matcher": "",
                "hooks": [["type": "command", "command": "/opt/othertool/hook.sh run"]],
            ]
            seedCorrectClaude(home, extraPreToolUse: foreign)
            let before = try Data(contentsOf: claudeSettingsURL(home))

            try HookInstaller.install(port: AgentDeck.port)

            #expect(try Data(contentsOf: claudeSettingsURL(home)) == before)
            #expect(claudeCommands(home, event: "PreToolUse").contains("/opt/othertool/hook.sh run"))
        }
    }

    @Test func installDoesNotRewriteCodexWhenEntriesAreAlreadyCorrect() throws {
        try withTempHome { home in
            let foreign: [String: Any] = [
                "matcher": ".*",
                "hooks": [["type": "command", "command": "/opt/othertool/hook.sh run"]],
            ]
            seedCorrectCodex(home, extraPreToolUse: foreign)
            let before = try Data(contentsOf: codexHooksURL(home))

            try HookInstaller.install(port: AgentDeck.port)

            #expect(try Data(contentsOf: codexHooksURL(home)) == before)
            #expect(codexCommands(home, event: "PreToolUse").contains("/opt/othertool/hook.sh run"))
        }
    }

    @Test func installHealsCodexEntryWithWrongMatcher() throws {
        try withTempHome { home in
            seedCorrectCodex(home, matcher: "")
            let before = try Data(contentsOf: codexHooksURL(home))

            try HookInstaller.install(port: AgentDeck.port)

            #expect(try Data(contentsOf: codexHooksURL(home)) != before)
            let data = try Data(contentsOf: codexHooksURL(home))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hooks = try #require(root["hooks"] as? [String: Any])
            let groups = try #require(hooks["PreToolUse"] as? [[String: Any]])
            let ours = groups.filter { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(scriptPath) == true
                }
            }
            #expect(ours.count == 1)
            #expect(ours.first?["matcher"] as? String == ".*")
        }
    }

    @Test func installHealsClaudeEntryMissingTimeout() throws {
        try withTempHome { home in
            seedCorrectClaude(home, timeout: nil)
            let before = try Data(contentsOf: claudeSettingsURL(home))

            try HookInstaller.install(port: AgentDeck.port)

            #expect(try Data(contentsOf: claudeSettingsURL(home)) != before)
            let ours = claudeHandlers(home, event: "PreToolUse").filter {
                ($0["command"] as? String)?.contains(scriptPath) == true
            }
            #expect(ours.count == 1)
            #expect(ours.first?["timeout"] as? Int == 10)
            #expect(ours.first?["command"] as? String == "'\(scriptPath)' claude PreToolUse")
        }
    }

    @Test func installLeavesUnknownEventShapeAlone() throws {
        try withTempHome { home in
            seedClaude(home, [
                "statusLine": "keep-me",
                "hooks": ["PreToolUse": "not-an-array"],
            ])

            try HookInstaller.install(port: AgentDeck.port)

            let data = try Data(contentsOf: claudeSettingsURL(home))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hooks = try #require(root["hooks"] as? [String: Any])
            #expect(root["statusLine"] as? String == "keep-me")
            #expect(hooks["PreToolUse"] as? String == "not-an-array")
            #expect(claudeCommands(home, event: "Stop").contains { $0.contains(scriptPath) })
            #expect(claudeCommands(home, event: "SessionStart").contains { $0.contains(scriptPath) })

            let afterFirst = try Data(contentsOf: claudeSettingsURL(home))
            try HookInstaller.install(port: AgentDeck.port)
            #expect(try Data(contentsOf: claudeSettingsURL(home)) == afterFirst)
        }
    }

    @Test func installDoesNotRewriteClaudeWhenOneEventHasUnknownShape() throws {
        try withTempHome { home in
            seedCorrectClaude(home)
            var root = try JSONSerialization.jsonObject(
                with: Data(contentsOf: claudeSettingsURL(home))) as! [String: Any]
            var hooks = root["hooks"] as! [String: Any]
            hooks["PreToolUse"] = "not-an-array"
            root["hooks"] = hooks
            try JSONSerialization.data(withJSONObject: root).write(to: claudeSettingsURL(home))
            let before = try Data(contentsOf: claudeSettingsURL(home))

            try HookInstaller.install(port: AgentDeck.port)

            #expect(try Data(contentsOf: claudeSettingsURL(home)) == before)
        }
    }

    @Test func claudeAndCodexEntriesIncludeTimeout10() throws {
        try withTempHome { home in
            try HookInstaller.install(port: AgentDeck.port)

            let claudeEvents = [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification",
                "Stop", "SubagentStop", "SessionEnd",
            ]
            for event in claudeEvents {
                let ours = claudeHandlers(home, event: event).filter {
                    ($0["command"] as? String)?.contains(scriptPath) == true
                }
                #expect(ours.count == 1)
                #expect(ours.first?["timeout"] as? Int == 10)
            }

            let codexEvents = [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop",
                "SessionEnd",
            ]
            for event in codexEvents {
                let ours = codexHandlers(home, event: event).filter {
                    ($0["command"] as? String)?.contains(scriptPath) == true
                }
                #expect(ours.count == 1)
                #expect(ours.first?["timeout"] as? Int == 10)
            }
        }
    }

    @Test func mergerDropsKeysTheListenerDoesNotDecode() throws {
        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let huge = String(repeating: "x", count: 100_000)
            let result = try runGeneratedMerger(
                input: [
                    "session_id": "s1",
                    "tool_input": huge,
                    "prompt": "secret",
                    "toolInput": huge,
                ],
                discoveredPID: nil
            )
            #expect(result["session_id"] as? String == "s1")
            #expect(result["tool_input"] == nil)
            #expect(result["prompt"] == nil)
            #expect(result["toolInput"] == nil)
        }
    }

    @Test func forwarderPostsLargePayloadViaStdin() throws {
        let tree: [Int32: FakeProcess] = [
            ProcessInfo.processInfo.processIdentifier:
                FakeProcess(comm: "sh", ppid: 9603, tty: "??"),
            9603: FakeProcess(comm: "/usr/local/bin/claude", ppid: 1, tty: "ttys003"),
        ]

        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let huge = String(repeating: "y", count: 100_000)
            let posted = try runGeneratedForwarder(
                tool: "claude",
                event: "PreToolUse",
                tree: tree,
                stdin: ["session_id": "s-large", "tool_input": huge]
            )

            #expect(posted["session_id"] as? String == "s-large")
            #expect(posted["tool_input"] == nil)
        }
    }
}
