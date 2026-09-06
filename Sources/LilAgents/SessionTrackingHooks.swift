import Foundation
import Synchronization

/// Installs or removes CLI hooks for the session-tracking switch.
///
/// AppDelegate calls this from a detached task on launch and whenever
/// `AppSettings.sessionsEnabled` flips. File writes are serialized. The
/// desired on/off flag can change while a write is in flight; the holder
/// then applies the latest value so the last requested state wins.
/// `LILAGENTS_NO_INSTALL=1` skips mutation, same as the old launch-only path.
enum SessionTrackingHooks {
    private static let ioLock = NSLock()
    private static let desiredEnabled = Mutex<Bool?>(nil)

    /// `AGENTDECK_NO_INSTALL` is the pre-rename spelling of the same switch.
    /// It is documented and set by hand in existing scripts and smoke tests, so
    /// it keeps working alongside the new name.
    static var skipFileMutation: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["LILAGENTS_NO_INSTALL"] != nil
            || environment["AGENTDECK_NO_INSTALL"] != nil
    }

    static func apply(enabled: Bool, port: UInt16 = LilAgents.port) throws {
        guard !skipFileMutation else { return }
        desiredEnabled.withLock { $0 = enabled }
        ioLock.lock()
        defer { ioLock.unlock() }
        while let target = desiredEnabled.withLock({ $0 }) {
            if target {
                try HookInstaller.install(port: port)
            } else {
                try HookInstaller.uninstall()
            }
            if desiredEnabled.withLock({ $0 }) == target { break }
        }
    }
}
