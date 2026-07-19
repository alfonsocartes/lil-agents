import Foundation
import Security

/// Shared constants for AgentDeck.
enum AgentDeck {
    /// Loopback port the embedded event listener binds to, and that installed
    /// CLI hooks forward events to. Loopback-only (127.0.0.1) — never LAN.
    static let port: UInt16 = 8787

    /// A session that hasn't emitted any event in this many seconds is treated
    /// as dead and pruned (safety net for a missed SessionEnd).
    static let staleAfter: TimeInterval = 60 * 60

    /// Directory where AgentDeck keeps its runtime files (forwarder script, etc).
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AgentDeck", isDirectory: true)
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
        precondition(status == errSecSuccess, "AgentDeck: SecRandomCopyBytes failed with status \(status)")
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
            NSLog("AgentDeck: failed to create token file at \(tokenURL.path): \(error)")
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
