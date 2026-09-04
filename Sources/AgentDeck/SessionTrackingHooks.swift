import Foundation

/// Installs or removes CLI hooks for the session-tracking switch.
///
/// AppDelegate calls this from a detached task on launch and whenever
/// `AppSettings.sessionsEnabled` flips. A lock serializes rapid toggles so
/// two file-writing tasks cannot interleave. `AGENTDECK_NO_INSTALL=1` skips
/// mutation, same as the old launch-only path.
enum SessionTrackingHooks {
    private static let lock = NSLock()

    static var skipFileMutation: Bool {
        ProcessInfo.processInfo.environment["AGENTDECK_NO_INSTALL"] != nil
    }

    static func apply(enabled: Bool, port: UInt16 = AgentDeck.port) throws {
        guard !skipFileMutation else { return }
        lock.lock()
        defer { lock.unlock() }
        if enabled {
            try HookInstaller.install(port: port)
        } else {
            try HookInstaller.uninstall()
        }
    }
}
