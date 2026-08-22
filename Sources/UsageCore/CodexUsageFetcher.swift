import Foundation

// Copied from AgentDeck CodexUsageFetcher.swift, 2026-08-22; keep decode in sync.
// Credentials are injected (no `~/.codex/auth.json` reads).

public struct CodexCredentials: Equatable, Sendable {
    public var accessToken: String
    public var accountID: String?

    public init(accessToken: String, accountID: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public struct CodexUsageFetcher: UsageProviding, Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let credentials: @Sendable () throws -> CodexCredentials
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let now: @Sendable () -> Date

    public init(
        credentials: @escaping @Sendable () throws -> CodexCredentials,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let credentials: CodexCredentials
        do {
            credentials = try self.credentials()
        } catch let error as UsageFetchError {
            throw error
        } catch {
            throw UsageFetchError.credentialsMissing
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        // Only sent when credentials actually have an account id — a bare
        // access token with no account_id is a normal shape, not an error.
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli/agentdeck-usage", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await HTTPRetryAfter.perform(request, transport: transport)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.badResponse("non-HTTP response")
        }
        try HTTPRetryAfter.validate(response: http, now: now())

        let decoded = try Self.decode(data)
        let (session, weekly) = Self.classify(decoded)
        return ProviderUsage(session: session, weekly: weekly, fetchedAt: now())
    }

    // MARK: - Response decoding (tolerant — every field optional)

    /// Wire shape of `GET /backend-api/wham/usage`. Every field optional:
    /// this is an undocumented endpoint, so a missing/renamed field degrades
    /// to "no data for that window" rather than failing the whole decode.
    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            var usedPercent: Double?
            var resetAt: Double?             // epoch-SECONDS; Int or Double literal, both decode fine
            var limitWindowSeconds: Double?
        }
        struct RateLimit: Decodable {
            var primaryWindow: Window?
            var secondaryWindow: Window?
        }
        var rateLimit: RateLimit?
    }

    private static func decode(_ data: Data) throws -> UsageResponse {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw UsageFetchError.badResponse("decode failed: \(error)")
        }
    }

    /// Classifies `primary_window`/`secondary_window` into session/weekly by
    /// `limit_window_seconds` (~5h = 18,000s, ~7d = 604,800s) — NOT by which
    /// slot they arrived in, since the two can be swapped. An absent
    /// `primary_window` is the normal Codex shape, not an error; a window
    /// whose `limit_window_seconds` matches neither bucket is silently
    /// ignored rather than guessed at.
    private static func classify(_ response: UsageResponse) -> (session: UsageWindow?, weekly: UsageWindow?) {
        var session: UsageWindow?
        var weekly: UsageWindow?
        for raw in [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow] {
            guard let raw, let usedPercent = raw.usedPercent, let limitSeconds = raw.limitWindowSeconds else { continue }
            let resetsAt = raw.resetAt.map { Date(timeIntervalSince1970: $0) }
            let window = UsageWindow(percent: usedPercent, resetsAt: resetsAt)
            if isApproximately(limitSeconds, target: 18_000) {
                session = window
            } else if isApproximately(limitSeconds, target: 604_800) {
                weekly = window
            }
        }
        return (session, weekly)
    }

    private static func isApproximately(_ value: Double, target: Double, tolerance: Double = 0.1) -> Bool {
        abs(value - target) <= target * tolerance
    }
}
