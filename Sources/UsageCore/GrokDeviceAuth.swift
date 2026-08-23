import Foundation

public enum GrokDeviceAuth {
    public struct Pending: Sendable {
        public var userCode: String
        public var verificationURL: URL
        public var deviceCode: String
        public var interval: TimeInterval
        public var expiresIn: TimeInterval
    }

    /// RFC 8628 against `auth.x.ai` — same as `grok login --device-auth`.
    public static func start(
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Pending {
        var request = URLRequest(url: OAuthClients.grokDevice)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok-cli/lil-usage", forHTTPHeaderField: "User-Agent")
        request.httpBody = FormURLEncoder.encode([
            ("client_id", OAuthClients.grokID),
            ("scope", OAuthClients.grokScopes),
            ("referrer", "grok-build"),
        ])
        let (data, http) = try await OAuthHTTP.send(request, transport: transport)
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthLoginError.badResponse("HTTP \(http.statusCode)")
        }
        let object = try OAuthHTTP.jsonObject(data)
        guard let deviceCode = object["device_code"] as? String,
              let userCode = object["user_code"] as? String,
              !deviceCode.isEmpty, !userCode.isEmpty else {
            throw OAuthLoginError.badResponse("missing device_code")
        }
        let uriString = (object["verification_uri_complete"] as? String)
            ?? (object["verification_uri"] as? String)
            ?? "https://accounts.x.ai/oauth2/device"
        guard let uri = URL(string: uriString) else {
            throw OAuthLoginError.badResponse("bad verification_uri")
        }
        let interval = (object["interval"] as? Double) ?? Double((object["interval"] as? Int) ?? 5)
        let expires = (object["expires_in"] as? Double) ?? Double((object["expires_in"] as? Int) ?? 900)
        return Pending(
            userCode: userCode,
            verificationURL: uri,
            deviceCode: deviceCode,
            interval: max(1, interval),
            expiresIn: expires
        )
    }

    public static func poll(
        pending: Pending,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> OAuthTokens {
        let deadline = now().addingTimeInterval(pending.expiresIn)
        var interval = pending.interval
        while now() < deadline {
            if Task.isCancelled { throw OAuthLoginError.cancelled }
            await sleep(interval)
            var request = URLRequest(url: OAuthClients.grokToken)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = FormURLEncoder.encode([
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("device_code", pending.deviceCode),
                ("client_id", OAuthClients.grokID),
            ])
            let (data, http) = try await OAuthHTTP.send(request, transport: transport)
            if (200..<300).contains(http.statusCode) {
                return try parseTokenJSON(data, now: now())
            }
            let object = (try? OAuthHTTP.jsonObject(data)) ?? [:]
            let error = object["error"] as? String
            if error == "authorization_pending" { continue }
            if error == "slow_down" {
                interval += 5
                continue
            }
            if error == "access_denied" {
                throw OAuthLoginError.denied("Access denied")
            }
            if error == "expired_token" {
                throw OAuthLoginError.timedOut
            }
            throw OAuthLoginError.badResponse(error ?? "HTTP \(http.statusCode)")
        }
        throw OAuthLoginError.timedOut
    }
}
