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

    /// Runs `body` with HookInstaller redirected at a fresh temp home, then
    /// restores the override so the real ~/.claude is never touched.
    private func withTempHome(_ body: (URL) throws -> Void) rethrows {
        let home = makeTempDir()
        HookInstaller.homeDirectoryOverride = home
        defer {
            HookInstaller.homeDirectoryOverride = nil
            cleanup(home)
        }
        try body(home)
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
}
