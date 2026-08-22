import Foundation
import Testing
@testable import AgentDeck

// MARK: - Shared fixtures

/// Writes `~/.grok/auth.json`-shaped `contents` into a fresh `.grok`
/// subdirectory of `dir` and returns the `.grok` directory URL — what
/// `grokHomeURL` should be pointed at. Mirrors CodexUsageFetcherTests so a
/// run never touches the developer's real `~/.grok`.
private func writeGrokAuth(_ contents: String, in dir: URL) -> URL {
    let grokHome = dir.appendingPathComponent(".grok", isDirectory: true)
    try! FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true)
    try! Data(contents.utf8).write(to: grokHome.appendingPathComponent("auth.json"))
    return grokHome
}

private let grokAuthWithFutureExpiry = """
{"https://auth.x.ai::aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": {"key": "tok-grok", "expires_at": "2024-01-01T00:00:00Z", "refresh_token": "refresh-xyz"}}
"""

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private let creditsWeeklyBody = """
{"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-08-22T00:00:00+00:00", "end": "2026-08-29T00:00:00+00:00"}, "creditUsagePercent": 2, "productUsage": [{"product": "GrokBuild", "usagePercent": 2}], "billingPeriodStart": "2026-08-22T00:00:00+00:00", "billingPeriodEnd": "2026-08-29T00:00:00+00:00"}}
"""

private let openUsageBody = """
{"config": {"monthlyLimit": {"val": 60000}, "used": {"val": 4277}, "onDemandCap": {"val": 0}, "billingPeriodStart": "2026-05-01T00:00:00+00:00", "billingPeriodEnd": "2026-06-01T00:00:00+00:00"}}
"""

private func isoDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

// MARK: - auth.json + response decoding

@Suite struct GrokUsageDecodingTests {
    private func fetch(auth: String, body: String, dir: URL, transport: TransportSpy? = nil) async throws -> (ProviderUsage, TransportSpy) {
        let grokHome = writeGrokAuth(auth, in: dir)
        let spy = transport ?? TransportSpy([.success(status: 200, body: Data(body.utf8))])
        let fetcher = GrokUsageFetcher(grokHomeURL: { grokHome }, transport: spy.handle, now: { fixedNow })
        return (try await fetcher.fetchUsage(), spy)
    }

    @Test func creditsWeeklyShapeUsesCreditUsagePercentAndPeriodEnd() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let (usage, spy) = try await fetch(auth: grokAuthWithFutureExpiry, body: creditsWeeklyBody, dir: dir)
        #expect(usage.weekly?.percent == 2)
        #expect(usage.session == nil)
        #expect(usage.weekly?.resetsAt == isoDate("2026-08-29T00:00:00+00:00"))
        #expect(usage.fetchedAt == fixedNow)
        #expect(spy.callCount == 1)
        #expect(spy.requests.first?.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(spy.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-grok")
        #expect(spy.requests.first?.value(forHTTPHeaderField: "X-XAI-Token-Auth") == "xai-grok-cli")
        #expect(spy.requests.first?.value(forHTTPHeaderField: "x-grok-client-mode") == "cli")
        #expect(spy.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(spy.requests.first?.value(forHTTPHeaderField: "User-Agent") == "grok-cli/agentdeck-usage")
    }

    @Test func missingPercentSourcesLeaveWeeklyNil() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let body = """
        {"config": {"monthlyLimit": {"val": 0}, "used": {"val": 466}, "onDemandCap": {"val": 0}}}
        """
        let (usage, spy) = try await fetch(auth: grokAuthWithFutureExpiry, body: body, dir: dir)
        #expect(usage.weekly == nil)
        #expect(usage.session == nil)
        #expect(spy.callCount == 1)
    }

    @Test func usedAndLimitAreFallbackWhenCreditPercentIsAbsent() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let (usage, _) = try await fetch(auth: grokAuthWithFutureExpiry, body: openUsageBody, dir: dir)
        #expect(usage.weekly?.percent == 4277.0 / 60000.0 * 100)
        #expect(usage.session == nil)
        #expect(usage.weekly?.resetsAt == isoDate("2026-06-01T00:00:00+00:00"))
    }

    @Test func snakeCaseBodyDecodesNestedVal() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let body = """
        {"config": {"monthly_limit": {"val": 60000}, "used": {"val": 4277}, "billing_period_end": "2026-06-01T00:00:00+00:00"}}
        """
        let (usage, _) = try await fetch(auth: grokAuthWithFutureExpiry, body: body, dir: dir)
        #expect(usage.weekly?.percent == 4277.0 / 60000.0 * 100)
        #expect(usage.weekly?.resetsAt == isoDate("2026-06-01T00:00:00+00:00"))
    }

    @Test func camelCaseBodyDecodesNestedVal() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let body = """
        {"config": {"monthlyLimit": {"val": 60000}, "used": {"val": 4277}, "billingPeriodEnd": "2026-06-01T00:00:00+00:00"}}
        """
        let (usage, _) = try await fetch(auth: grokAuthWithFutureExpiry, body: body, dir: dir)
        #expect(usage.weekly?.percent == 4277.0 / 60000.0 * 100)
        #expect(usage.weekly?.resetsAt == isoDate("2026-06-01T00:00:00+00:00"))
    }

    @Test func fractionalValDecodesAsDouble() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let body = """
        {"config": {"monthlyLimit": {"val": 60000.0}, "used": {"val": 4277.5}, "billingPeriodEnd": "2026-06-01T00:00:00+00:00"}}
        """
        let (usage, _) = try await fetch(auth: grokAuthWithFutureExpiry, body: body, dir: dir)
        #expect(usage.weekly?.percent == 4277.5 / 60000.0 * 100)
    }
}

// MARK: - Fetch policy / error mapping

@Suite struct GrokUsageFetcherTests {
    @Test func missingAuthFileMapsToCredentialsMissing() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let grokHome = dir.appendingPathComponent(".grok", isDirectory: true)
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = GrokUsageFetcher(grokHomeURL: { grokHome }, transport: transport.handle, now: { fixedNow })
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .credentialsMissing")
        } catch let error as UsageFetchError {
            #expect(error == .credentialsMissing)
        }
        #expect(transport.callCount == 0)
    }

    @Test func authObjectWithNoKeyMapsToCredentialsMissing() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let grokHome = writeGrokAuth(
            #"{"https://auth.x.ai::aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": {"expires_at": "2024-01-01T00:00:00Z", "refresh_token": "refresh-xyz"}}"#,
            in: dir
        )
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = GrokUsageFetcher(grokHomeURL: { grokHome }, transport: transport.handle, now: { fixedNow })
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .credentialsMissing")
        } catch let error as UsageFetchError {
            #expect(error == .credentialsMissing)
        }
        #expect(transport.callCount == 0)
    }

    @Test(arguments: [401, 403]) func authErrorStatusesMapToTokenExpired(status: Int) async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let grokHome = writeGrokAuth(grokAuthWithFutureExpiry, in: dir)
        let transport = TransportSpy([.success(status: status, body: Data())])
        let fetcher = GrokUsageFetcher(grokHomeURL: { grokHome }, transport: transport.handle, now: { fixedNow })
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .tokenExpired")
        } catch let error as UsageFetchError {
            #expect(error == .tokenExpired)
        }
    }

    @Test func rateLimitedParsesDeltaSecondsRetryAfter() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let grokHome = writeGrokAuth(grokAuthWithFutureExpiry, in: dir)
        let transport = TransportSpy([.success(status: 429, headers: ["Retry-After": "15"], body: Data())])
        let fetcher = GrokUsageFetcher(grokHomeURL: { grokHome }, transport: transport.handle, now: { fixedNow })
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .rateLimited")
        } catch let error as UsageFetchError {
            #expect(error == .rateLimited(retryAfter: 15))
        }
    }
}

@Suite struct GrokCLIHomeTests {
    @Test func honorsGROK_HOMEOutsideTheTestHarness() {
        let url = GrokCLIHome.resolve(
            homeDirectory: URL(fileURLWithPath: "/Users/x"),
            environment: ["GROK_HOME": "/opt/grok"],
            isTestHarness: false
        )
        #expect(url.path == "/opt/grok")
    }

    @Test func ignoresGROK_HOMEUnderTheTestHarness() {
        let url = GrokCLIHome.resolve(
            homeDirectory: URL(fileURLWithPath: "/tmp/test-home"),
            environment: ["GROK_HOME": "/opt/grok"],
            isTestHarness: true
        )
        #expect(url.path == "/tmp/test-home/.grok")
    }

    @Test func defaultsToDotGrokWhenUnset() {
        let url = GrokCLIHome.resolve(
            homeDirectory: URL(fileURLWithPath: "/Users/x"),
            environment: [:],
            isTestHarness: false
        )
        #expect(url.path == "/Users/x/.grok")
    }
}
