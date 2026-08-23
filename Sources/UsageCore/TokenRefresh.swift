import Foundation

public enum TokenRefresh {
    /// Best-effort refresh using a refresh_token in the stored paste/JSON.
    /// Returns nil if there is nothing to refresh.
    public static func refresh(
        kind: ProviderKind,
        raw: String,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        now: Date = Date()
    ) async throws -> String? {
        let session = try? refreshable(kind: kind, raw: raw)
        guard let session, let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            return nil
        }
        let tokens: OAuthTokens
        switch kind {
        case .claude:
            tokens = try await refreshClaude(refreshToken: refreshToken, transport: transport, now: now)
        case .codex:
            var t = try await refreshForm(
                url: URL(string: "\(OAuthClients.codexIssuer)/oauth/token")!,
                clientID: OAuthClients.codexID,
                refreshToken: refreshToken,
                transport: transport,
                now: now
            )
            t.accountID = session.accountID ?? t.accountID
            tokens = t
        case .grok:
            tokens = try await refreshForm(
                url: OAuthClients.grokToken,
                clientID: OAuthClients.grokID,
                refreshToken: refreshToken,
                transport: transport,
                now: now
            )
        }
        return CredentialBlob.encode(tokens, kind: kind)
    }

    public static func needsRefresh(kind: ProviderKind, raw: String, now: Date) -> Bool {
        guard let session = try? refreshable(kind: kind, raw: raw),
              session.refreshToken != nil else { return false }
        guard let expires = session.expiresAt else { return false }
        return expires.addingTimeInterval(-60) <= now
    }

    struct Session {
        var refreshToken: String?
        var accountID: String?
        var expiresAt: Date?
    }

    static func refreshable(kind: ProviderKind, raw: String) throws -> Session {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
            return Session()
        }
        switch kind {
        case .claude:
            let file = try JSONDecoder().decode(ClaudeFile.self, from: data)
            let expires = file.claudeAiOauth?.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            return Session(refreshToken: file.claudeAiOauth?.refreshToken, expiresAt: expires)
        case .codex:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let file = try decoder.decode(CodexFile.self, from: data)
            return Session(refreshToken: file.tokens?.refreshToken, accountID: file.tokens?.accountId)
        case .grok:
            if let single = try? JSONDecoder().decode(GrokKey.self, from: data) {
                return Session(refreshToken: single.refreshToken, expiresAt: ISO8601Dates.parse(single.expiresAt))
            }
            let entries = try JSONDecoder().decode([String: GrokKey].self, from: data)
            let withRefresh = entries.values.compactMap { entry -> Session? in
                guard let refresh = entry.refreshToken, !refresh.isEmpty else { return nil }
                return Session(refreshToken: refresh, expiresAt: ISO8601Dates.parse(entry.expiresAt))
            }
            return withRefresh.first ?? Session()
        }
    }

    private struct ClaudeFile: Decodable {
        struct OAuth: Decodable {
            var refreshToken: String?
            var expiresAt: Int64?
        }
        var claudeAiOauth: OAuth?
    }

    private struct CodexFile: Decodable {
        struct Tokens: Decodable {
            var refreshToken: String?
            var accountId: String?
        }
        var tokens: Tokens?
    }

    private struct GrokKey: Decodable {
        var refreshToken: String?
        var expiresAt: String?
        enum CodingKeys: String, CodingKey {
            case refreshToken, expiresAt, refresh_token, expires_at
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
                ?? c.decodeIfPresent(String.self, forKey: .refresh_token)
            expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
                ?? c.decodeIfPresent(String.self, forKey: .expires_at)
        }
    }

    private static func refreshClaude(
        refreshToken: String,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        now: Date
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: OAuthClients.claudeToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthClients.claudeID,
        ])
        let (data, http) = try await OAuthHTTP.send(request, transport: transport)
        guard (200..<300).contains(http.statusCode) else {
            throw UsageFetchError.tokenExpired
        }
        return try parseTokenJSON(data, now: now)
    }

    private static func refreshForm(
        url: URL,
        clientID: String,
        refreshToken: String,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        now: Date
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
        let (data, http) = try await OAuthHTTP.send(request, transport: transport)
        guard (200..<300).contains(http.statusCode) else {
            throw UsageFetchError.tokenExpired
        }
        return try parseTokenJSON(data, now: now)
    }
}
