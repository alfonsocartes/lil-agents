import Foundation
import Security

/// Shared iCloud Keychain items for the iPhone app and, optionally, lil
/// agents on the Mac. Service/account/group strings must stay in lockstep
/// with `IPhoneTokenHandoff` in AgentDeck.
public struct KeychainTokenStore: TokenStoring, Sendable {
    public static let accessGroupSuffix = "group.com.wandity.lilagents"

    public init() {}

    public static func service(for kind: ProviderKind) -> String {
        "com.wandity.lilagents.token.\(kind.rawValue)"
    }

    /// `TEAMID.group.com.wandity.lilagents` when the binary is signed.
    /// Unsigned Simulator builds omit the group so local paste still saves.
    public static var accessGroup: String? {
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ".")).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return "\(trimmed).\(accessGroupSuffix)"
            }
        }
        if let team = signingTeamID(), !team.isEmpty {
            return "\(team).\(accessGroupSuffix)"
        }
        return nil
    }

    public func load(kind: ProviderKind) throws -> String? {
        if let value = try copy(kind: kind, synchronizable: true) { return value }
        return try copy(kind: kind, synchronizable: false)
    }

    public func save(kind: ProviderKind, raw: String) throws {
        if raw.isEmpty {
            try delete(kind: kind)
            return
        }
        try delete(kind: kind)
        var query = baseQuery(kind: kind, synchronizable: true)
        query[kSecValueData as String] = Data(raw.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(kind: ProviderKind) throws {
        for flag in [true, false] {
            let status = SecItemDelete(baseQuery(kind: kind, synchronizable: flag) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError(status: status)
            }
        }
    }

    private func copy(kind: ProviderKind, synchronizable: Bool) throws -> String? {
        var query = baseQuery(kind: kind, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func baseQuery(kind: ProviderKind, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service(for: kind),
            kSecAttrAccount as String: kind.rawValue,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        if let group = Self.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    private static func signingTeamID() -> String? {
        #if os(macOS)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
        #else
        nil
        #endif
    }
}

public struct KeychainError: Error {
    public var status: OSStatus
    public init(status: OSStatus) { self.status = status }
}
