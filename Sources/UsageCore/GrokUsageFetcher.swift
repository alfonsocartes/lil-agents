import Foundation

// Copied from AgentDeck GrokUsageFetcher.swift, 2026-08-22; keep decode in sync.
// Token is injected (no `~/.grok/auth.json` reads, no GrokCLIHome).

public struct GrokUsageFetcher: UsageProviding, Sendable {
    private static let usageURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private let accessToken: @Sendable () throws -> String
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let now: @Sendable () -> Date

    public init(
        accessToken: @escaping @Sendable () throws -> String,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accessToken = accessToken
        self.transport = transport
        self.now = now
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let accessToken: String
        do {
            accessToken = try self.accessToken()
        } catch let error as UsageFetchError {
            throw error
        } catch {
            throw UsageFetchError.credentialsMissing
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        // Without this, `format=credits` omits `creditUsagePercent` for
        // SuperGrok unified-billing accounts (the TUI's weekly limit).
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok-cli/agentdeck-usage", forHTTPHeaderField: "User-Agent")

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

    /// Wire shape of `GET /v1/billing`. Every field optional: this is an
    /// undocumented endpoint, so a missing/renamed field degrades to "no
    /// data for that window" rather than failing the whole decode. `val`
    /// is nested (`{"val": 466}`) and may be int or float; `Double`
    /// accepts both JSON number shapes.
    private struct UsageResponse: Decodable {
        struct NumericVal: Decodable {
            var val: Double?
        }
        struct Period: Decodable {
            var end: String?
        }
        struct ProductUsage: Decodable {
            var product: String?
            var usagePercent: Double?
        }
        struct Config: Decodable {
            var creditUsagePercent: Double?
            var currentPeriod: Period?
            var productUsage: [ProductUsage]?
            var monthlyLimit: NumericVal?
            var used: NumericVal?
            var billingPeriodEnd: String?
        }
        var config: Config?
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

    /// Prefers `creditUsagePercent` from `format=credits` (the TUI's
    /// "Weekly limit"). Falls back to GrokBuild `productUsage`, then
    /// `used`/`monthlyLimit`. `session` is always nil. Missing sources
    /// leave weekly nil — never fake 0%.
    private static func classify(_ response: UsageResponse) -> (session: UsageWindow?, weekly: UsageWindow?) {
        let config = response.config
        let resetsAt = ISO8601Dates.parse(config?.currentPeriod?.end)
            ?? ISO8601Dates.parse(config?.billingPeriodEnd)

        let grokBuildPercent = config?.productUsage?
            .first { $0.product == "GrokBuild" }?
            .usagePercent

        let percent: Double?
        if let credit = config?.creditUsagePercent {
            percent = min(100, max(0, credit))
        } else if let grokBuildPercent {
            percent = min(100, max(0, grokBuildPercent))
        } else if let used = config?.used?.val,
                  let monthlyLimit = config?.monthlyLimit?.val,
                  monthlyLimit > 0 {
            percent = min(100, max(0, used / monthlyLimit * 100))
        } else {
            percent = nil
        }
        guard let percent else { return (nil, nil) }
        return (nil, UsageWindow(percent: percent, resetsAt: resetsAt))
    }
}
