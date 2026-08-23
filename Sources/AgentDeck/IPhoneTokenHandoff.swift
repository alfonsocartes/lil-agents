import Foundation
import Security

/// Copies CLI credential blobs into the same iCloud Keychain items the
/// iPhone app reads. Opt-in via Settings. Strings must match
/// `UsageCore.KeychainTokenStore`.
enum IPhoneTokenHandoff {
    /// Wandity Ltd team + the iOS keychain-access-groups suffix.
    static let accessGroup = "S74M2P6469.group.com.wandity.lilagents"

    @MainActor static var lastError: String?

    static func service(_ name: String) -> String {
        "com.wandity.lilagents.token.\(name)"
    }

    @MainActor
    static func sync(enabled: Bool) {
        lastError = nil
        for name in ["claude", "grok", "codex"] {
            if !enabled {
                delete(name)
                continue
            }
            guard let raw = readCLIBlob(name), !raw.isEmpty else {
                delete(name)
                continue
            }
            do {
                try save(name, raw: raw)
            } catch {
                lastError = "Couldn’t write to iCloud Keychain. Use a signed lil agents build (not `swift run`) and turn on iCloud Keychain for this Mac."
            }
        }
    }

    private static func readCLIBlob(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch name {
        case "claude":
            let file = home.appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: file),
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            return claudeKeychainBlob()
        case "grok":
            let url = GrokCLIHome.resolve(homeDirectory: home).appendingPathComponent("auth.json")
            return stringContents(url)
        case "codex":
            let url = home.appendingPathComponent(".codex/auth.json")
            return stringContents(url)
        default:
            return nil
        }
    }

    private static func stringContents(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    private static func claudeKeychainBlob() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", "Claude Code-credentials"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func save(_ name: String, raw: String) throws {
        delete(name)
        var query = baseQuery(name)
        query[kSecValueData as String] = Data(raw.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainWriteError(status: status) }
    }

    private static func delete(_ name: String) {
        _ = SecItemDelete(baseQuery(name) as CFDictionary)
        var unsynced = baseQuery(name)
        unsynced[kSecAttrSynchronizable as String] = false
        _ = SecItemDelete(unsynced as CFDictionary)
    }

    private static func baseQuery(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(name),
            kSecAttrAccount as String: name,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
        ]
    }
}

private struct KeychainWriteError: Error {
    var status: OSStatus
}
