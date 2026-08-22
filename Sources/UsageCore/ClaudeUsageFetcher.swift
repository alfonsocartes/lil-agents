import Foundation

// Copied from AgentDeck ClaudeUsageFetcher.swift, 2026-08-22; keep decode in sync.
// Credentials are injected (no `~/.claude` / Keychain reads).

public struct ClaudeCredentials: Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Int64? // epoch-ms

    public init(accessToken: String, expiresAt: Int64? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public struct ClaudeUsageFetcher: UsageProviding, Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let credentials: @Sendable () throws -> ClaudeCredentials
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let now: @Sendable () -> Date

    public init(
        credentials: @escaping @Sendable () throws -> ClaudeCredentials,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let credentials: ClaudeCredentials
        do {
            credentials = try self.credentials()
        } catch let error as UsageFetchError {
            throw error
        } catch {
            throw UsageFetchError.credentialsMissing
        }

        // Local expiry short-circuit: `expiresAt` is epoch-MILLISECONDS.
        // Checked BEFORE any network call so an already-dead token never
        // costs a round trip.
        if let expiresAt = credentials.expiresAt,
           Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) <= now() {
            throw UsageFetchError.tokenExpired
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await HTTPRetryAfter.perform(request, transport: transport)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.badResponse("non-HTTP response")
        }
        try HTTPRetryAfter.validate(response: http, now: now())

        let decoded = try Self.decode(data)
        return Self.providerUsage(from: decoded, fetchedAt: now())
    }

    // MARK: - Response decoding (tolerant — every field optional)

    /// Wire shape of `GET /api/oauth/usage`. Every field is optional: this is
    /// an undocumented endpoint, so a missing/renamed field degrades to "no
    /// data for that window" rather than failing the whole decode.
    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            // `Double` accepts BOTH integer ("62") and fractional ("62.5")
            // JSON number literals.
            var utilization: Double?
            var resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        struct Limit: Decodable {
            var percent: Double?
            var kind: String?
            var resetsAt: String?
            var isActive: Bool?

            enum CodingKeys: String, CodingKey {
                case percent
                case kind
                case resetsAt = "resets_at"
                case isActive = "is_active"
            }
        }

        var fiveHour: Window?
        var sevenDay: Window?
        var limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }
    }

    private static func decode(_ data: Data) throws -> UsageResponse {
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageFetchError.badResponse("decode failed: \(error)")
        }
    }

    /// Flat `five_hour`/`seven_day` objects are preferred when present; the
    /// `limits[]` array (which uses `percent`, not `utilization`) is the
    /// fallback when they're absent.
    private static func providerUsage(from response: UsageResponse, fetchedAt: Date) -> ProviderUsage {
        let session = window(from: response.fiveHour) ?? windowFromLimits(response.limits, kind: "session")
        let weekly = window(from: response.sevenDay) ?? windowFromLimits(response.limits, kind: "weekly_all")
        return ProviderUsage(session: session, weekly: weekly, fetchedAt: fetchedAt)
    }

    private static func window(from raw: UsageResponse.Window?) -> UsageWindow? {
        guard let raw, let utilization = raw.utilization else { return nil }
        return UsageWindow(percent: utilization, resetsAt: ISO8601Dates.parse(raw.resetsAt))
    }

    /// Picks the `limits[]` entry for `kind` ("session" or "weekly_all" —
    /// "weekly_scoped" and anything else is an unknown kind and is ignored
    /// entirely). Multiple entries can share a `kind`; the one with
    /// `is_active == true` wins when present, otherwise the first match.
    private static func windowFromLimits(_ limits: [UsageResponse.Limit]?, kind: String) -> UsageWindow? {
        guard let limits else { return nil }
        let matches = limits.filter { $0.kind == kind }
        guard let chosen = matches.first(where: { $0.isActive == true }) ?? matches.first,
              let percent = chosen.percent
        else { return nil }
        return UsageWindow(percent: percent, resetsAt: ISO8601Dates.parse(chosen.resetsAt))
    }
}
