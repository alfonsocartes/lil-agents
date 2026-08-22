import Foundation

/// Where the Grok CLI stores config and `auth.json`. Shared by hook install
/// and usage fetch so a relocated `$GROK_HOME` cannot split them.
enum GrokCLIHome {
    static func resolve(
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTestHarness: Bool = HookInstaller.isRunningUnderTestHarness
    ) -> URL {
        if isTestHarness {
            return homeDirectory.appendingPathComponent(".grok")
        }
        if let grokHome = environment["GROK_HOME"], !grokHome.isEmpty {
            return URL(fileURLWithPath: grokHome)
        }
        return homeDirectory.appendingPathComponent(".grok")
    }
}
