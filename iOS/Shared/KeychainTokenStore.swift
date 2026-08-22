import Foundation
import Security
import UsageCore

struct KeychainTokenStore: TokenStoring, Sendable {
    /// Team-prefixed group matching `keychain-access-groups` in both
    /// entitlements. `AppIdentifierPrefix` is injected into Info.plist.
    private static var accessGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return "\(prefix)group.com.wandity.lilagents"
    }

    func load(kind: ProviderKind) throws -> String? {
        var query = baseQuery(kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(kind: ProviderKind, raw: String) throws {
        if raw.isEmpty {
            try delete(kind: kind)
            return
        }
        try delete(kind: kind)
        var query = baseQuery(kind: kind)
        query[kSecValueData as String] = Data(raw.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(kind: ProviderKind) throws {
        let status = SecItemDelete(baseQuery(kind: kind) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError(status: status)
    }

    private func baseQuery(kind: ProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.wandity.lilagents.token.\(kind.rawValue)",
            kSecAttrAccount as String: kind.rawValue,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
    }
}

struct KeychainError: Error {
    var status: OSStatus
}
