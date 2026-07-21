import Foundation

/// Fetches Codex/ChatGPT usage from the unofficial wham/usage endpoint,
/// reusing the `codex` CLI's own `~/.codex/auth.json`. Same v1 read-only
/// contract as `ClaudeUsageFetcher`: never writes credentials, never
/// refreshes tokens — an expired/rejected token surfaces as `.tokenExpired`.
///
/// Plain `struct` (no Keychain seam, so no once-per-launch cache to guard —
/// unlike `ClaudeUsageFetcher` this one doesn't need class identity).
struct CodexUsageFetcher: UsageProviding, Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// `~/.codex` by default. Test seam AND the reason this isn't read from
    /// `$CODEX_HOME`: a Finder-launched GUI app never inherits shell
    /// exports, so honoring that env var at runtime would silently diverge
    /// from what a user who set it in their shell profile expects — it's a
    /// CLI/test concern only. Tests point this at a temp dir.
    let codexHomeURL: @Sendable () -> URL

    /// HTTP transport. Test seam: production wraps
    /// `URLSession.shared.data(for:)`; tests inject a stub returning canned
    /// `(Data, HTTPURLResponse)` pairs — no real network in tests.
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Clock. Test seam: production is `Date()`. Used to turn an HTTP-date
    /// `Retry-After` into a delta-seconds interval.
    let now: @Sendable () -> Date

    init(
        codexHomeURL: @escaping @Sendable () -> URL = CodexUsageFetcher.defaultCodexHomeURL,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.codexHomeURL = codexHomeURL
        self.transport = transport
        self.now = now
    }

    static func defaultCodexHomeURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    // MARK: - UsageProviding

    func fetchUsage() async throws -> ProviderUsage {
        let credentials = try readCredentials()

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        // Only sent when auth.json actually has an account id — a bare
        // access token with no account_id is a normal auth.json shape, not
        // an error (see `readCredentials`).
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The plan pins Claude's User-Agent to the exact reference value
        // (`claude-code/2.1.0`) but doesn't specify one for Codex — this
        // string is a reasonable placeholder for an otherwise-required
        // header, not a verified value.
        request.setValue("codex-cli/agentdeck-usage", forHTTPHeaderField: "User-Agent")

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

    // MARK: - Credentials (~/.codex/auth.json)

    private struct Credentials {
        var accessToken: String
        var accountID: String?
    }

    /// `.convertFromSnakeCase` decoding lets ONE set of property names accept
    /// BOTH `access_token`/`account_id` (the CLI's actual on-disk shape) and
    /// `accessToken`/`accountId` (camelCase, in case a future CLI version or
    /// a test fixture uses it) — snake_case keys get converted to camelCase
    /// before matching, and already-camelCase keys (no underscores) pass
    /// through untouched. Deliberately has NO explicit `CodingKeys` raw
    /// values: adding e.g. `case accessToken = "access_token"` would make
    /// `.convertFromSnakeCase` convert the JSON key first and then try to
    /// match it against the literal string `"access_token"` — which an
    /// already-converted `"accessToken"` JSON key would NOT match, silently
    /// losing the token. Letting the synthesized coding keys equal the
    /// property names is what makes both input shapes actually work.
    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            var accessToken: String?
            var accountId: String?
        }
        var tokens: Tokens?
    }

    private static func decodeAuth(_ data: Data) throws -> AuthFile {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AuthFile.self, from: data)
    }

    /// Missing file, unparseable JSON, or a `tokens` object with no
    /// `access_token` (including the API-key-only shape `{"OPENAI_API_KEY":
    /// "…"}`, which has no `tokens` object at all) all map to the same
    /// `.credentialsMissing` — a non-goal for v1 per the plan.
    private func readCredentials() throws -> Credentials {
        let url = codexHomeURL().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let auth = try? Self.decodeAuth(data),
              let accessToken = auth.tokens?.accessToken
        else {
            throw UsageFetchError.credentialsMissing
        }
        return Credentials(accessToken: accessToken, accountID: auth.tokens?.accountId)
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
    /// slot they arrived in, since the plan calls out that the two can be
    /// swapped. An absent `primary_window` is the normal Codex shape (v1
    /// only surfaces a weekly percent per the plan), not an error; a window
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

    // MARK: - Error mapping (identical to ClaudeUsageFetcher's)

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
