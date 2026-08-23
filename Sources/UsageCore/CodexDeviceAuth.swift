import Foundation

public struct DeviceCodeChallenge: Equatable, Sendable {
    public var userCode: String
    public var verificationURL: URL
    public var expiresIn: TimeInterval
}

public enum CodexDeviceAuth {
    public struct Pending: Sendable {
        public var userCode: String
        public var verificationURL: URL
        public var deviceAuthID: String
        public var interval: TimeInterval
    }

    /// POST `{issuer}/api/accounts/deviceauth/usercode` — official Codex
    /// `login --device-auth`. ChatGPT must have device-code login enabled.
    public static func start(
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Pending {
        let url = URL(string: "\(OAuthClients.codexIssuer)/api/accounts/deviceauth/usercode")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": OAuthClients.codexID])

        let (data, http) = try await OAuthHTTP.send(request, transport: transport)
        if http.statusCode == 404 {
            throw OAuthLoginError.denied("Device code login is off in ChatGPT → Settings → Security.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthLoginError.badResponse("HTTP \(http.statusCode)")
        }
        let object = try OAuthHTTP.jsonObject(data)
        let userCode = (object["user_code"] as? String) ?? (object["usercode"] as? String)
        let deviceAuthID = object["device_auth_id"] as? String
        guard let userCode, let deviceAuthID, !userCode.isEmpty, !deviceAuthID.isEmpty else {
            throw OAuthLoginError.badResponse("missing user_code")
        }
        let interval: TimeInterval
        if let s = object["interval"] as? Double { interval = s }
        else if let s = object["interval"] as? Int { interval = TimeInterval(s) }
        else if let s = object["interval"] as? String, let v = TimeInterval(s) { interval = v }
        else { interval = 5 }
        let verify = URL(string: "\(OAuthClients.codexIssuer)/codex/device")!
        return Pending(
            userCode: userCode,
            verificationURL: verify,
            deviceAuthID: deviceAuthID,
            interval: max(1, interval)
        )
    }

    public static func poll(
        pending: Pending,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() },
        maxWait: TimeInterval = 15 * 60
    ) async throws -> OAuthTokens {
        let url = URL(string: "\(OAuthClients.codexIssuer)/api/accounts/deviceauth/token")!
        let deadline = now().addingTimeInterval(maxWait)
        while now() < deadline {
            if Task.isCancelled { throw OAuthLoginError.cancelled }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": pending.deviceAuthID,
                "user_code": pending.userCode,
            ])
            let (data, http) = try await OAuthHTTP.send(request, transport: transport)
            if (200..<300).contains(http.statusCode) {
                return try await exchange(pollBody: data, transport: transport, now: now())
            }
            if http.statusCode == 403 || http.statusCode == 404 {
                await sleep(pending.interval)
                continue
            }
            throw OAuthLoginError.badResponse("HTTP \(http.statusCode)")
        }
        throw OAuthLoginError.timedOut
    }

    private static func exchange(
        pollBody: Data,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        now: Date
    ) async throws -> OAuthTokens {
        let object = try OAuthHTTP.jsonObject(pollBody)
        guard let code = object["authorization_code"] as? String,
              let verifier = object["code_verifier"] as? String else {
            throw OAuthLoginError.badResponse("device poll missing authorization_code")
        }
        let redirect = "\(OAuthClients.codexIssuer)/deviceauth/callback"
        var request = URLRequest(url: URL(string: "\(OAuthClients.codexIssuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirect),
            ("client_id", OAuthClients.codexID),
            ("code_verifier", verifier),
        ])
        let (data, http) = try await OAuthHTTP.send(request, transport: transport)
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthLoginError.badResponse("HTTP \(http.statusCode)")
        }
        return try parseTokenJSON(data, now: now)
    }
}
