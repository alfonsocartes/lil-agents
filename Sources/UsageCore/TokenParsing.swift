import Foundation

/// Parse a pasted token (bare string or CLI JSON). Refresh tokens are
/// ignored — never returned, never used. Failure is always
/// `UsageFetchError.credentialsMissing`.
public enum TokenParsing {
    public static func claude(_ raw: String) throws -> ClaudeCredentials {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UsageFetchError.credentialsMissing }
        if trimmed.hasPrefix("{") {
            do {
                return try decodeClaudeJSON(Data(trimmed.utf8))
            } catch let error as UsageFetchError {
                throw error
            } catch {
                throw UsageFetchError.credentialsMissing
            }
        }
        return ClaudeCredentials(accessToken: trimmed, expiresAt: nil)
    }

    public static func codex(_ raw: String) throws -> CodexCredentials {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UsageFetchError.credentialsMissing }
        if trimmed.hasPrefix("{") {
            do {
                return try decodeCodexJSON(Data(trimmed.utf8))
            } catch let error as UsageFetchError {
                throw error
            } catch {
                throw UsageFetchError.credentialsMissing
            }
        }
        return CodexCredentials(accessToken: trimmed, accountID: nil)
    }

    public static func grok(_ raw: String, now: Date = Date()) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UsageFetchError.credentialsMissing }
        if trimmed.hasPrefix("{") {
            if let object = try? JSONDecoder().decode(GrokKeyObject.self, from: Data(trimmed.utf8)),
               let key = object.key {
                guard !key.isEmpty else { throw UsageFetchError.credentialsMissing }
                return key
            }
            do {
                return try pickGrokAuthEntry(Data(trimmed.utf8), now: now)
            } catch let error as UsageFetchError {
                throw error
            } catch {
                throw UsageFetchError.credentialsMissing
            }
        }
        return trimmed
    }

    // MARK: - Claude CLI `.credentials.json`

    /// Same shape as AgentDeck's `CredentialsFile` — camelCase only, no
    /// `convertFromSnakeCase`. Refresh tokens (if present) are ignored.
    private struct CredentialsFile: Decodable {
        struct OAuth: Decodable {
            var accessToken: String?
            var expiresAt: Int64?
        }
        var claudeAiOauth: OAuth?
    }

    private static func decodeClaudeJSON(_ data: Data) throws -> ClaudeCredentials {
        let file = try JSONDecoder().decode(CredentialsFile.self, from: data)
        guard let accessToken = file.claudeAiOauth?.accessToken else {
            throw UsageFetchError.credentialsMissing
        }
        return ClaudeCredentials(accessToken: accessToken, expiresAt: file.claudeAiOauth?.expiresAt)
    }

    // MARK: - Codex CLI `auth.json`

    /// `.convertFromSnakeCase` lets one set of property names accept both
    /// `access_token`/`account_id` (the CLI's on-disk shape) and camelCase.
    /// Deliberately has NO explicit `CodingKeys` raw values: adding e.g.
    /// `case accessToken = "access_token"` would make `.convertFromSnakeCase`
    /// convert the JSON key first and then fail to match.
    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            var accessToken: String?
            var accountId: String?
        }
        var tokens: Tokens?
    }

    private static func decodeCodexJSON(_ data: Data) throws -> CodexCredentials {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let auth = try decoder.decode(AuthFile.self, from: data)
        guard let accessToken = auth.tokens?.accessToken else {
            throw UsageFetchError.credentialsMissing
        }
        return CodexCredentials(accessToken: accessToken, accountID: auth.tokens?.accountId)
    }

    // MARK: - Grok CLI `auth.json`

    private struct GrokKeyObject: Decodable {
        var key: String?
    }

    private struct GrokAuthEntry: Decodable {
        var key: String?
        var expiresAt: String?
    }

    /// Unexpired pool else all; newest `expires_at` wins; a missing date
    /// sorts as newest. Expired entries are still returned if that's all
    /// there is, so the server can 401 → `.tokenExpired`. Copied from
    /// AgentDeck `GrokUsageFetcher.readCredentials`.
    private static func pickGrokAuthEntry(_ data: Data, now: Date) throws -> String {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try decoder.decode([String: GrokAuthEntry].self, from: data)

        struct Candidate {
            var key: String
            var expiresAt: Date?
        }
        let candidates: [Candidate] = entries.values.compactMap { entry in
            guard let key = entry.key, !key.isEmpty else { return nil }
            return Candidate(key: key, expiresAt: ISO8601Dates.parse(entry.expiresAt))
        }
        guard !candidates.isEmpty else {
            throw UsageFetchError.credentialsMissing
        }

        let unexpired = candidates.filter { candidate in
            guard let expiresAt = candidate.expiresAt else { return true }
            return expiresAt > now
        }
        let pool = unexpired.isEmpty ? candidates : unexpired
        let chosen = pool.max { a, b in
            (a.expiresAt ?? .distantFuture) < (b.expiresAt ?? .distantFuture)
        }!
        return chosen.key
    }
}
