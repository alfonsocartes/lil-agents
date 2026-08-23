import Foundation
import Security

/// Copies CLI credential blobs into the same iCloud Keychain items the
/// iPhone app reads. Opt-in via Settings. Strings must match
/// `UsageCore.KeychainTokenStore`.
enum IPhoneTokenHandoff {
    /// Wandity Ltd team + the iOS keychain-access-groups suffix.
    static let accessGroup = "S74M2P6469.group.com.wandity.lilagents"

    @MainActor static var lastError: String?

    enum SyncAction: Equatable {
        case skip
        case upsert(String)
    }

    static func service(_ name: String) -> String {
        "com.wandity.lilagents.token.\(name)"
    }

    /// iPhone sign-in uses these same items; disable/uninstall must not wipe them.
    static func action(enabled: Bool, cliBlob: String?) -> SyncAction {
        guard enabled, let cliBlob, !cliBlob.isEmpty else { return .skip }
        return .upsert(cliBlob)
    }

    @MainActor
    static func sync(enabled: Bool) {
        lastError = nil
        for name in ["claude", "grok", "codex"] {
            switch action(enabled: enabled, cliBlob: readCLIBlob(name)) {
            case .skip:
                continue
            case .upsert(let raw):
                do {
                    try save(name, raw: raw)
                } catch {
                    lastError = "Couldn’t write to iCloud Keychain. Use a signed lil agents build (not `swift run`) and turn on iCloud Keychain for this Mac."
                }
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
        let query = baseQuery(name)
        let attributes: [String: Any] = [kSecValueData as String: Data(raw.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        // A failed add after delete-first used to leave the iPhone item gone.
        guard updated == errSecItemNotFound else { throw KeychainWriteError(status: updated) }
        var add = query
        add[kSecValueData as String] = Data(raw.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainWriteError(status: added) }
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
