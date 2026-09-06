import Foundation
import Security
import Synchronization

/// Shared constants for LilAgents.
enum LilAgents {
    /// Loopback port the embedded event listener binds to, and that installed
    /// CLI hooks forward events to. Loopback-only (127.0.0.1) — never LAN.
    static let port: UInt16 = 54173

    /// A session that hasn't emitted any event in this many seconds is treated
    /// as dead and pruned (safety net for a missed SessionEnd).
    static let staleAfter: TimeInterval = 60 * 60

    /// Test seam mirroring `HookInstaller.homeDirectoryOverride`: redirects the
    /// runtime directory so a test never writes to — or deletes from — the
    /// developer's real `~/Library/Application Support/LilAgents`.
    ///
    /// This existed only for the home directory before, which was a real gap
    /// rather than an oversight of no consequence: `HookInstaller.install()`
    /// and `uninstall()` write and REMOVE the generated forwarder here, so a
    /// plain `swift test` deleted the live `forward-event.sh` out from under
    /// every running CLI session. Hooks then failed with "No such file or
    /// directory" until the app was relaunched. Tests also execute that
    /// generated script, so without redirection the only thing standing
    /// between the harness and the real listener on 127.0.0.1 was a stubbed
    /// `curl` on `PATH`.
    internal static var supportDirOverride: URL? {
        get { supportDirOverrideStorage.withLock { $0 } }
        set { supportDirOverrideStorage.withLock { $0 = newValue } }
    }
    private static let supportDirOverrideStorage = Mutex<URL?>(nil)

    /// Directory where LilAgents keeps its runtime files (forwarder script, etc).
    static var supportDir: URL {
        if let override = supportDirOverride { return override }
        // Same hard guard as `HookInstaller.homeDirectory`, for the same
        // reason and after the same real incident: a test that reaches here
        // without an override is about to mutate the developer's live install,
        // so fail loudly instead of silently doing it.
        if HookInstaller.isRunningUnderTestHarness {
            fatalError("""
                LilAgents.supportDir: refusing to touch the real support directory from a test \
                process. Set LilAgents.supportDirOverride to a temp directory first (see \
                HookInstallerTests.withTempHome).
                """)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LilAgents", isDirectory: true)
    }

    /// Test seam for `legacySupportDir`, mirroring `supportDirOverride`. It is
    /// a SEPARATE override rather than a sibling of the support-dir override
    /// on purpose: tests point `supportDirOverride` at a bare temp directory,
    /// so deriving the legacy path from its parent would resolve to something
    /// like `/tmp/AgentDeck` — outside the test's own temp tree, and the one
    /// thing these seams exist to make impossible.
    internal static var legacySupportDirOverride: URL? {
        get { legacySupportDirOverrideStorage.withLock { $0 } }
        set { legacySupportDirOverrideStorage.withLock { $0 = newValue } }
    }
    private static let legacySupportDirOverrideStorage = Mutex<URL?>(nil)

    /// Where `supportDir` lived while the app shipped as "AgentDeck". Read
    /// only by `migrateLegacySupportDir()` and by HookInstaller's hook-path
    /// recognition; nothing is ever written here.
    // TODO(rename cleanup): exists solely to migrate the pre-rename install.
    // Delete this property (and `legacySupportDirOverride`) one release after
    // this ships.
    static var legacySupportDir: URL {
        if let override = legacySupportDirOverride { return override }
        // Same hard guard, same reason as `supportDir` above: migration MOVES
        // and DELETES this directory, so a test that reaches here without an
        // override is about to destroy the developer's pre-rename install.
        if HookInstaller.isRunningUnderTestHarness {
            fatalError("""
                LilAgents.legacySupportDir: refusing to touch the real legacy support directory \
                from a test process. Set LilAgents.legacySupportDirOverride to a temp directory \
                first (see HookInstallerTests.withTempHome).
                """)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AgentDeck", isDirectory: true)
    }

    /// Moves a pre-rename support directory to `supportDir`. Called once per
    /// launch, before anything else reads either location.
    ///
    /// The contents matter, so this is a move rather than a fresh start:
    /// `token` is the bearer token every already-running CLI session's
    /// forwarder reads on each event, and generating a new one would 401 every
    /// one of those sessions until their hook configs are rewritten.
    ///
    /// Best-effort throughout — a failure here must never abort launch, and
    /// the old directory is removed only once it is actually empty, so a file
    /// we could not move is left in place instead of deleted.
    ///
    /// Skipped when `SessionTrackingHooks.skipFileMutation` is set: migration
    /// is itself a file mutation (it moves the token and, via `HookInstaller`'s
    /// legacy-path recognition, invalidates every already-written hook-config
    /// entry that pointed at the old absolute forwarder path), and running it
    /// while the one thing that would repair those entries is disabled would
    /// leave the install broken. Guarded here rather than at each call site so
    /// no future caller can get this wrong.
    // TODO(rename cleanup): exists solely to migrate the pre-rename install.
    // Delete this function (and its call site in AppDelegate) one release
    // after this ships.
    static func migrateLegacySupportDir() {
        guard !SessionTrackingHooks.skipFileMutation else { return }
        let fm = FileManager.default
        let legacy = legacySupportDir
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return   // already migrated, or a fresh install that never had one
        }

        let current = supportDir
        if !fm.fileExists(atPath: current.path) {
            do {
                try fm.createDirectory(
                    at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: legacy, to: current)
                return
            } catch {
                NSLog("lil agents: failed to move \(legacy.path) to \(current.path): \(error)")
                return
            }
        }

        // Both directories exist (an interrupted migration, or a downgrade and
        // re-upgrade). Merge file by file and let the NEW directory win every
        // collision: it was written by this build, the legacy copy wasn't.
        do {
            for name in try fm.contentsOfDirectory(atPath: legacy.path) {
                let source = legacy.appendingPathComponent(name)
                let destination = current.appendingPathComponent(name)
                do {
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: source)
                    } else {
                        try fm.moveItem(at: source, to: destination)
                    }
                } catch {
                    NSLog("lil agents: failed to migrate \(source.path): \(error)")
                }
            }
            if try fm.contentsOfDirectory(atPath: legacy.path).isEmpty {
                try fm.removeItem(at: legacy)
            }
        } catch {
            NSLog("lil agents: failed to migrate \(legacy.path): \(error)")
        }
    }

    /// Path to the per-install bearer token that gates `POST /event` on the
    /// loopback listener (see EventListener.swift). Any local process that can
    /// read this file can post/spoof session events — hence mode 0600.
    static var tokenURL: URL {
        supportDir.appendingPathComponent("token")
    }

    /// Serializes token creation so two near-simultaneous callers in this
    /// process (e.g. a hot relaunch) don't both try to generate one.
    private static let tokenLock = NSLock()

    /// Returns the per-install bearer token, generating one (32
    /// cryptographically-random bytes, hex-encoded, file mode 0600) the first
    /// time it's needed. Idempotent, and safe under a cross-process race: if
    /// our write loses to another writer (or simply fails), we re-read
    /// whatever ended up on disk rather than erroring.
    static func loadOrCreateToken() -> String {
        tokenLock.lock()
        defer { tokenLock.unlock() }

        let fm = FileManager.default
        if let existing = readToken(fm) {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "lil agents: SecRandomCopyBytes failed with status \(status)")
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try token.write(to: tokenURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        } catch {
            // Another process may have raced us to create the file — re-read
            // rather than fail outright.
            if let existing = readToken(fm) {
                return existing
            }
            NSLog("lil agents: failed to create token file at \(tokenURL.path): \(error)")
        }

        // Belt-and-suspenders: re-assert the mode in case the winner of a
        // create race left looser permissions.
        if let attrs = try? fm.attributesOfItem(atPath: tokenURL.path),
           let mode = attrs[.posixPermissions] as? NSNumber,
           mode.uint16Value != 0o600 {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        }

        return token
    }

    private static func readToken(_ fm: FileManager) -> String? {
        guard let data = try? Data(contentsOf: tokenURL),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Constant-time string comparison for the bearer token check: iterates
    /// over the full length of both inputs and accumulates XOR differences
    /// rather than using `==`, so a mismatch doesn't return early and leak
    /// timing information about how many leading bytes matched.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let length = max(aBytes.count, bBytes.count, 1)
        var diff: UInt8 = UInt8(truncatingIfNeeded: aBytes.count ^ bBytes.count)
        for i in 0..<length {
            let x = i < aBytes.count ? aBytes[i] : 0
            let y = i < bBytes.count ? bBytes[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}
