import Foundation

public struct ClaudeOAuthStart: Equatable, Sendable {
    public var authorizationURL: URL
    public var pkce: PKCE
}

public enum ClaudeOAuth {
    /// Safari opens this URL. After login, Anthropic shows a code to paste
    /// (`code#state`) — the same headless path Claude Code uses on SSH/WSL.
    public static func start(pkce: PKCE = .generate()) -> ClaudeOAuthStart {
        var components = URLComponents(url: OAuthClients.claudeAuthorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: OAuthClients.claudeID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: OAuthClients.claudeRedirect),
            URLQueryItem(name: "scope", value: OAuthClients.claudeScopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return ClaudeOAuthStart(authorizationURL: components.url!, pkce: pkce)
    }

    /// `pasted` is the page's `code#state` blob, or a bare code.
    public static func exchange(
        pasted: String,
        pkce: PKCE,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthLoginError.badResponse("empty code") }
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0]
        let state = parts.count > 1 ? parts[1] : pkce.state

        var request = URLRequest(url: OAuthClients.claudeToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OAuthClients.claudeRedirect,
            "client_id": OAuthClients.claudeID,
            "code_verifier": pkce.verifier,
            "state": state,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await OAuthHTTP.send(request, transport: transport)
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthLoginError.badResponse("HTTP \(http.statusCode)")
        }
        return try parseTokenJSON(data, now: now)
    }
}

func parseTokenJSON(_ data: Data, now: Date) throws -> OAuthTokens {
    let object = try OAuthHTTP.jsonObject(data)
    let access = (object["access_token"] as? String) ?? (object["accessToken"] as? String)
    guard let access, !access.isEmpty else {
        throw OAuthLoginError.badResponse("missing access_token")
    }
    let refresh = (object["refresh_token"] as? String) ?? (object["refreshToken"] as? String)
    let expires: Date?
    if let seconds = object["expires_in"] as? Double {
        expires = now.addingTimeInterval(seconds)
    } else if let seconds = object["expires_in"] as? Int {
        expires = now.addingTimeInterval(TimeInterval(seconds))
    } else {
        expires = nil
    }
    let idToken = (object["id_token"] as? String) ?? (object["idToken"] as? String)
    let account = idToken.flatMap(JWTPayload.chatgptAccountID)
    return OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: expires, accountID: account)
}
