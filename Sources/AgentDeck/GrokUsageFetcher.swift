import Foundation

/// Fetches Grok CLI usage from the unofficial billing endpoint, reusing the
/// `grok` CLI's own `~/.grok/auth.json`. Same v1 read-only contract as
/// `ClaudeUsageFetcher`/`CodexUsageFetcher`: never writes credentials, never
/// refreshes tokens — an expired/rejected token surfaces as `.tokenExpired`.
///
/// Plain `struct` (no Keychain seam, so no once-per-launch cache to guard —
/// unlike `ClaudeUsageFetcher` this one doesn't need class identity).
struct GrokUsageFetcher: UsageProviding, Sendable {
    private static let usageURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    /// Grok CLI home (`$GROK_HOME` or `~/.grok`). Test seam: tests point this
    /// at a temp dir so a run never reads the developer's `auth.json`.
    let grokHomeURL: @Sendable () -> URL

    /// HTTP transport. Test seam: production wraps
    /// `URLSession.shared.data(for:)`; tests inject a stub returning canned
    /// `(Data, HTTPURLResponse)` pairs — no real network in tests.
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Clock. Test seam: production is `Date()`. Used to pick an unexpired
    /// `auth.json` entry and to turn an HTTP-date `Retry-After` into a
    /// delta-seconds interval.
    let now: @Sendable () -> Date

    init(
        grokHomeURL: @escaping @Sendable () -> URL = GrokUsageFetcher.defaultGrokHomeURL,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.grokHomeURL = grokHomeURL
        self.transport = transport
        self.now = now
    }

    static func defaultGrokHomeURL() -> URL {
        GrokCLIHome.resolve(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    // MARK: - UsageProviding

    func fetchUsage() async throws -> ProviderUsage {
        let accessToken = try readCredentials()

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        // Without this, `format=credits` omits `creditUsagePercent` for
        // SuperGrok unified-billing accounts (the TUI's weekly limit).
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("grok-cli/agentdeck-usage", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.badResponse("non-HTTP response")
        }
        try Self.validate(response: http, now: now())

        let decoded = try Self.decode(data)
        let (session, weekly) = Self.classify(decoded)
        return ProviderUsage(session: session, weekly: weekly, fetchedAt: now())
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport(request)
        } catch let error as URLError {
            throw UsageFetchError.network(error.localizedDescription)
        } catch let error as UsageFetchError {
            throw error
        } catch {
            throw UsageFetchError.network(String(describing: error))
        }
    }

    // MARK: - Credentials (~/.grok/auth.json)

    /// `.convertFromSnakeCase` decoding lets ONE set of property names accept
    /// BOTH `expires_at` (the CLI's actual on-disk shape) and `expiresAt`
    /// (camelCase, in case a future CLI version or a test fixture uses it) —
    /// snake_case keys get converted to camelCase before matching, and
    /// already-camelCase keys (no underscores) pass through untouched.
    /// Deliberately has NO explicit `CodingKeys` raw values: adding e.g.
    /// `case expiresAt = "expires_at"` would make `.convertFromSnakeCase`
    /// convert the JSON key first and then try to match it against the
    /// literal string `"expires_at"` — which an already-converted
    /// `"expiresAt"` JSON key would NOT match, silently losing the date.
    private struct AuthEntry: Decodable {
        var key: String?
        var expiresAt: String?
    }

    private static func decodeAuth(_ data: Data) throws -> [String: AuthEntry] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([String: AuthEntry].self, from: data)
    }

    /// Missing file, unparseable JSON, or an object with no usable `key`
    /// all map to the same `.credentialsMissing`. Expired entries are still
    /// used (newest `expires_at` wins) so the server can 401 →
    /// `.tokenExpired`; v1 never refreshes tokens.
    private func readCredentials() throws -> String {
        let url = grokHomeURL().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let entries = try? Self.decodeAuth(data)
        else {
            throw UsageFetchError.credentialsMissing
        }

        struct Candidate {
            var key: String
            var expiresAt: Date?
        }
        let candidates: [Candidate] = entries.values.compactMap { entry in
            guard let key = entry.key, !key.isEmpty else { return nil }
            return Candidate(key: key, expiresAt: Self.parseDate(entry.expiresAt))
        }
        guard !candidates.isEmpty else {
            throw UsageFetchError.credentialsMissing
        }

        let current = now()
        let unexpired = candidates.filter { candidate in
            guard let expiresAt = candidate.expiresAt else { return true }
            return expiresAt > current
        }
        let pool = unexpired.isEmpty ? candidates : unexpired
        // Newest `expires_at` wins; a missing date sorts as newest so an
        // undated still-valid token is preferred over a dated one.
        let chosen = pool.max { a, b in
            (a.expiresAt ?? .distantFuture) < (b.expiresAt ?? .distantFuture)
        }!
        return chosen.key
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
    /// `used`/`monthlyLimit`. `session` is always nil.
    private static func classify(_ response: UsageResponse) -> (session: UsageWindow?, weekly: UsageWindow?) {
        let config = response.config
        let resetsAt = parseDate(config?.currentPeriod?.end)
            ?? parseDate(config?.billingPeriodEnd)

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

    // MARK: - Date parsing (ISO 8601, with then without fractional seconds)

    // `ISO8601DateFormatter` isn't `Sendable`, so these are built fresh per
    // call rather than cached as statics (which Swift 6 strict concurrency
    // rightly refuses for a mutable-looking global) — cheap enough at usage-
    // fetch frequency that a cache isn't worth a `Mutex` wrapper here.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: string)
    }

    // MARK: - Error mapping (identical to CodexUsageFetcher's)

    private static func validate(response: HTTPURLResponse, now: Date) throws {
        let status = response.statusCode
        if (200..<300).contains(status) { return }
        switch status {
        case 401, 403:
            throw UsageFetchError.tokenExpired
        case 429:
            let retryAfter = parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now)
            throw UsageFetchError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageFetchError.badResponse("HTTP \(status)")
        }
    }

    private static func parseRetryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let header, !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return seconds }
        if let date = makeHTTPDateFormatter().date(from: header) {
            return date.timeIntervalSince(now)
        }
        return nil
    }

    // `DateFormatter` isn't `Sendable`, so this is built fresh per call
    // rather than cached as a static (same reasoning as
    // ClaudeUsageFetcher.swift's identical helper) — cheap at usage-fetch
    // frequency.
    private static func makeHTTPDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }
}
