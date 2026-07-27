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

    private func runGeneratedForwarder(
        tool: String,
        event: String,
        tree: [Int32: FakeProcess],
        stdin: [String: Any] = ["session_id": "s1", "cwd": "/private/tmp"]
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
          if [ "$1" = "-d" ]; then body="$2"; shift 2; else shift; fi
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
        for key in ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR"] {
            environment.removeValue(forKey: key)
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
        try withTempHome { _ in
            try HookInstaller.install(port: AgentDeck.port)

            let posted = try runGeneratedForwarder(
                tool: "claude", event: "Stop", tree: nestedAgentTree
            )

            #expect(posted["agent_pid"] as? Int == 9003)
            #expect(posted["tty"] as? String == "/dev/ttys003")
            #expect(posted["headless"] == nil)
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
}
