import Foundation
import Synchronization

/// Fetches Claude's usage snapshot from the unofficial OAuth usage endpoint,
/// reusing the same on-disk credentials (and, as a fallback, Keychain item)
/// the `claude` CLI itself writes. v1 is strictly read-only: this type never
/// writes credentials and never calls a token-refresh endpoint — an
/// expired/rejected token surfaces as `.tokenExpired` ("run `claude` to sign
/// in"), full stop.
///
/// A `final class` (not the plain `struct` most DI-seam types in this app
/// use) so the Keychain denial flag below can live on an INSTANCE-level
/// `Mutex` rather than a `static` one: the seam-injected instance in
/// ClaudeUsageFetcherTests must exercise the exact same flag a production
/// instance would, and a `static` flag would leak state across unrelated
/// tests/instances. Every stored property is either an immutable `let` of a
/// `Sendable` closure/value type or lives inside a `Mutex`, so `Sendable`
/// conformance below is checked, not asserted — no `@unchecked Sendable`
/// (see EventListener.swift for the identical pattern).
final class ClaudeUsageFetcher: UsageProviding, Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Where `~/.claude/.credentials.json` lives. Test seam: production
    /// reads the real per-user file; tests point this at a file inside a
    /// temp dir (HookInstallerTests' `withTempHome` pattern) so a run never
    /// touches the developer's actual credentials.
    let credentialsFileURL: @Sendable () -> URL

    /// Reads the CLI's Keychain item (generic password, service `"Claude
    /// Code-credentials"`) and returns its raw JSON payload, or `nil` on any
    /// failure/absence. Test seam: production shells out to the `security`
    /// command-line tool (see `defaultKeychainRead()` below for why); tests
    /// inject a spy that never touches the real Keychain and can simulate an
    /// absent/unreadable item.
    let keychainRead: @Sendable () -> Data?

    /// HTTP transport. Test seam: production wraps
    /// `URLSession.shared.data(for:)`; tests inject a stub returning canned
    /// `(Data, HTTPURLResponse)` pairs — no real network in tests.
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Clock. Test seam: production is `Date()`. Used for the local
    /// `expiresAt` short-circuit and to turn an HTTP-date `Retry-After` into
    /// a delta-seconds interval.
    let now: @Sendable () -> Date

    /// Set once `keychainRead()` has returned `nil` (item genuinely absent or
    /// otherwise unreadable) — see `credentials()` below for why a denial,
    /// and only a denial, is cached for this instance's whole lifetime.
    private let keychainDenied = Mutex<Bool>(false)

    init(
        credentialsFileURL: @escaping @Sendable () -> URL = ClaudeUsageFetcher.defaultCredentialsFileURL,
        keychainRead: @escaping @Sendable () -> Data? = ClaudeUsageFetcher.defaultKeychainRead,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialsFileURL = credentialsFileURL
        self.keychainRead = keychainRead
        self.transport = transport
        self.now = now
    }

    static func defaultCredentialsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// Production Keychain read. Deliberately does NOT call `SecItemCopyMatching`
    /// in-process: the `claude` CLI writes this item via `security
    /// add-generic-password -U`, which leaves it with a partition list
    /// containing only `apple-tool:` — an in-process `SecItemCopyMatching`
    /// call is a different client than the item's ACL expects, so macOS pops
    /// a Keychain password prompt, and the item is deleted/recreated on every
    /// `claude` logout/login, wiping any manual partition-list fix. Instead
    /// this shells out to `/usr/bin/security find-generic-password -w`: the
    /// client the OS sees is the Apple-signed `security` tool itself, which
    /// is always in the fresh item's ACL (it's the creator) and always
    /// passes the `apple-tool:` partition check — silent forever, survives
    /// re-login, independent of this app's own code signature.
    ///
    /// Bounded by a watchdog so a hung `security` process (e.g. some future
    /// macOS surfacing a dialog after all) can never block `fetchUsage()`
    /// indefinitely; a timeout is treated the same as any other failure and
    /// returns `nil`.
    static func defaultKeychainRead() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", "Claude Code-credentials"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe   // attached (not inherited) and ignored

        do {
            try process.run()
        } catch {
            return nil
        }

        // Watchdog: the read is expected to be silent, but guarantee this
        // function always returns within a bounded time regardless.
        let timedOut = Mutex(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning {
                timedOut.withLock { $0 = true }
                process.terminate()
            }
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard !timedOut.withLock({ $0 }), process.terminationStatus == 0 else { return nil }

        let trimmed = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }

        // `-w` prints the raw payload when it's valid printable text, but
        // falls back to a hex dump when it isn't — decode that case back
        // into raw bytes rather than returning the hex string itself.
        if !trimmed.hasPrefix("{"), trimmed.allSatisfy({ $0.isHexDigit }) {
            return hexDecode(trimmed)
        }
        return Data(trimmed.utf8)
    }

    /// Decodes a hex string (pairs of hex digits) into raw bytes — used for
    /// `security find-generic-password -w`'s hex-dump fallback when the
    /// stored payload isn't valid printable text. Returns `nil` on an
    /// odd-length string or any unparseable byte pair.
    private static func hexDecode(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    // MARK: - UsageProviding

    func fetchUsage() async throws -> ProviderUsage {
        let credentials = try credentials()

        // Local expiry short-circuit: `expiresAt` is epoch-MILLISECONDS.
        // Checked BEFORE any network call so an already-dead token never
        // costs a round trip.
        if let expiresAt = credentials.expiresAt,
           Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) <= now() {
            throw UsageFetchError.tokenExpired
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        // Full header set mirrored from the reference implementation this
        // endpoint was verified against (see the plan) — cheap insurance on
        // an undocumented route.
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.badResponse("non-HTTP response")
        }
        try Self.validate(response: http, now: now())

        let decoded = try Self.decode(data)
        return Self.providerUsage(from: decoded, fetchedAt: now())
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

    // MARK: - Credentials

    private struct Credentials {
        var accessToken: String
        var expiresAt: Int64?   // epoch-ms
    }

    /// File-first credential read, with a Keychain fallback. Reading the
    /// file never prompts anything, so it's attempted on every single fetch;
    /// the Keychain path shells out to Apple's `security` tool (see
    /// `defaultKeychainRead()`), which passes the item's `apple-tool:`
    /// partition silently and needs no user grant — so a SUCCESSFUL read is
    /// NOT cached and is re-attempted on every `fetchUsage()` call, which
    /// matters because the `claude` CLI rotates the access token in place
    /// and `UsageStore` polls every 300s; a cached token would go stale. A
    /// `nil` result, by contrast, IS cached for this instance's whole
    /// lifetime and never retried — purely defense-in-depth against the edge
    /// case where the item is genuinely absent, at the cost of a transient
    /// absence at the first fetch sticking as "missing" until the app is
    /// relaunched (an acceptable tradeoff: the alternative is hammering
    /// `security` every 300s for an item that isn't coming back this run).
    private func credentials() throws -> Credentials {
        if let data = try? Data(contentsOf: credentialsFileURL()),
           let credentials = try? Self.decodeCredentials(data) {
            return credentials
        }
        guard let data = keychainData(), let credentials = try? Self.decodeCredentials(data) else {
            throw UsageFetchError.credentialsMissing
        }
        return credentials
    }

    private func keychainData() -> Data? {
        if keychainDenied.withLock({ $0 }) { return nil }
        let result = keychainRead()
        if result == nil {
            keychainDenied.withLock { $0 = true }
        }
        return result
    }

    private struct CredentialsFile: Decodable {
        struct OAuth: Decodable {
            var accessToken: String?
            var expiresAt: Int64?
        }
        var claudeAiOauth: OAuth?
    }

    private static func decodeCredentials(_ data: Data) throws -> Credentials {
        let file = try JSONDecoder().decode(CredentialsFile.self, from: data)
        guard let accessToken = file.claudeAiOauth?.accessToken else {
            throw UsageFetchError.credentialsMissing
        }
        return Credentials(accessToken: accessToken, expiresAt: file.claudeAiOauth?.expiresAt)
    }

    // MARK: - Response decoding (tolerant — every field optional)

    /// Wire shape of `GET /api/oauth/usage`. Every field is optional: this is
    /// an undocumented endpoint, so a missing/renamed field degrades to "no
    /// data for that window" rather than failing the whole decode.
    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            // `Double` accepts BOTH integer ("62") and fractional ("62.5")
            // JSON number literals — JSONDecoder parses either into a Double
            // transparently, so no separate Int/Double union type is needed.
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

    /// Builds the `ProviderUsage` the store consumes: the flat
    /// `five_hour`/`seven_day` objects are preferred when present; the
    /// `limits[]` array (which uses `percent`, not `utilization`) is the
    /// fallback when they're absent.
    private static func providerUsage(from response: UsageResponse, fetchedAt: Date) -> ProviderUsage {
        let session = window(from: response.fiveHour) ?? windowFromLimits(response.limits, kind: "session")
        let weekly = window(from: response.sevenDay) ?? windowFromLimits(response.limits, kind: "weekly_all")
        return ProviderUsage(session: session, weekly: weekly, fetchedAt: fetchedAt)
    }

    private static func window(from raw: UsageResponse.Window?) -> UsageWindow? {
        guard let raw, let utilization = raw.utilization else { return nil }
        return UsageWindow(percent: utilization, resetsAt: parseDate(raw.resetsAt))
    }

    /// Picks the `limits[]` entry for `kind` ("session" or "weekly_all" —
    /// "weekly_scoped" and anything else is an unknown kind and is ignored
    /// entirely, per the plan). Multiple entries can share a `kind`; the one
    /// with `is_active == true` wins when present, otherwise the first match.
    private static func windowFromLimits(_ limits: [UsageResponse.Limit]?, kind: String) -> UsageWindow? {
        guard let limits else { return nil }
        let matches = limits.filter { $0.kind == kind }
        guard let chosen = matches.first(where: { $0.isActive == true }) ?? matches.first,
              let percent = chosen.percent
        else { return nil }
        return UsageWindow(percent: percent, resetsAt: parseDate(chosen.resetsAt))
    }

    // MARK: - Date parsing (ISO 8601, with then without fractional seconds)

    // `ISO8601DateFormatter` isn't `Sendable`, so these are built fresh per
    // call rather than cached as statics (which Swift 6 strict concurrency
    // rightly refuses for a mutable-looking global) — cheap enough at usage-
    // fetch frequency (a handful of dates per fetch, at most every 5
    // minutes) that a cache isn't worth a `Mutex` wrapper here.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: string)
    }

    // MARK: - Error mapping

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

    /// `Retry-After` is either a bare delta-seconds integer OR an RFC 1123
    /// HTTP-date (e.g. `"Wed, 21 Oct 2015 07:28:00 GMT"`) — parsed as a
    /// delta from the injected `now` in the latter case.
    private static func parseRetryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let header, !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return seconds }
        if let date = makeHTTPDateFormatter().date(from: header) {
            return date.timeIntervalSince(now)
        }
        return nil
    }

    // Same non-`Sendable`-static concern as the ISO 8601 formatters above —
    // built fresh per call.
    private static func makeHTTPDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }
}
