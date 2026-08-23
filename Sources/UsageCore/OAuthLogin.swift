import Foundation

/// Unofficial CLI public clients. Same IDs every third-party tool uses.
/// They can change; treat a 400/invalid_client as "sign in again".
enum OAuthClients {
    static let claudeID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Same constants as Claude Code 2.1.240 (`bHu` / `Qti` / `DVs`).
    static let claudeAuthorize = URL(string: "https://claude.com/cai/oauth/authorize")!
    static let claudeToken = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let claudeRedirect = "https://platform.claude.com/oauth/code/callback"
    static let claudeScopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    static let codexID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let codexIssuer = "https://auth.openai.com"

    static let grokID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let grokDevice = URL(string: "https://auth.x.ai/oauth2/device/code")!
    static let grokToken = URL(string: "https://auth.x.ai/oauth2/token")!
    static let grokScopes = "openid profile email offline_access grok-cli:access api:access"
}

public struct OAuthTokens: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var accountID: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, accountID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
    }
}

public enum OAuthLoginError: Error, Equatable {
    case cancelled
    case timedOut
    case denied(String)
    case badResponse(String)
    case network(String)
}

enum OAuthHTTP {
    static func send(
        _ request: URLRequest,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            throw OAuthLoginError.network(error.localizedDescription)
        } catch let error as OAuthLoginError {
            throw error
        } catch {
            throw OAuthLoginError.network(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuthLoginError.badResponse("non-HTTP response")
        }
        return (data, http)
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthLoginError.badResponse("expected JSON object")
        }
        return object
    }
}

public enum CredentialBlob {
    static func claude(_ tokens: OAuthTokens) -> String {
        var oauth: [String: Any] = ["accessToken": tokens.accessToken]
        if let refresh = tokens.refreshToken { oauth["refreshToken"] = refresh }
        if let expires = tokens.expiresAt {
            oauth["expiresAt"] = Int64(expires.timeIntervalSince1970 * 1000)
        }
        return json(["claudeAiOauth": oauth])
    }

    static func codex(_ tokens: OAuthTokens) -> String {
        var inner: [String: Any] = ["access_token": tokens.accessToken]
        if let refresh = tokens.refreshToken { inner["refresh_token"] = refresh }
        if let account = tokens.accountID { inner["account_id"] = account }
        return json(["tokens": inner])
    }

    static func grok(_ tokens: OAuthTokens) -> String {
        let key = "https://auth.x.ai::\(OAuthClients.grokID)"
        var entry: [String: Any] = ["key": tokens.accessToken]
        if let refresh = tokens.refreshToken { entry["refresh_token"] = refresh }
        if let expires = tokens.expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            entry["expires_at"] = formatter.string(from: expires)
        }
        return json([key: entry])
    }

    public static func encode(_ tokens: OAuthTokens, kind: ProviderKind) -> String {
        switch kind {
        case .claude: claude(tokens)
        case .codex: codex(tokens)
        case .grok: grok(tokens)
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
