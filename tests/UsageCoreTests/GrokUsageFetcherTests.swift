import Foundation
import Testing
@testable import UsageCore

private struct DummyError: Error {}

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

private func makeFetcher(
    accessToken: @escaping @Sendable () throws -> String = { "tok-grok" },
    transport: TransportSpy,
    now: Date = fixedNow
) -> GrokUsageFetcher {
    GrokUsageFetcher(accessToken: accessToken, transport: transport.handle, now: { now })
}

// MARK: - Response decoding

@Suite struct GrokUsageDecodingTests {
    private func fetch(body: String, transport: TransportSpy? = nil) async throws -> (ProviderUsage, TransportSpy) {
        let spy = transport ?? TransportSpy([.success(status: 200, body: Data(body.utf8))])
        let fetcher = makeFetcher(transport: spy)
        return (try await fetcher.fetchUsage(), spy)
    }

    @Test func creditsWeeklyShapeUsesCreditUsagePercentAndPeriodEnd() async throws {
        let (usage, spy) = try await fetch(body: creditsWeeklyBody)
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
        let body = """
        {"config": {"monthlyLimit": {"val": 0}, "used": {"val": 466}, "onDemandCap": {"val": 0}}}
        """
        let (usage, spy) = try await fetch(body: body)
        #expect(usage.weekly == nil)
        #expect(usage.session == nil)
        #expect(spy.callCount == 1)
    }

    @Test func grokBuildProductUsageIsUsedWhenCreditPercentIsAbsent() async throws {
        // Distinct from creditUsagePercent so preferring the wrong source fails.
        let body = """
        {"config": {"currentPeriod": {"end": "2026-08-29T00:00:00+00:00"}, "productUsage": [{"product": "GrokBuild", "usagePercent": 40}, {"product": "Other", "usagePercent": 99}]}}
        """
        let (usage, _) = try await fetch(body: body)
        #expect(usage.weekly?.percent == 40)
        #expect(usage.session == nil)
        #expect(usage.weekly?.resetsAt == isoDate("2026-08-29T00:00:00+00:00"))
    }

    @Test func creditUsagePercentWinsOverGrokBuild() async throws {
        let body = """
        {"config": {"creditUsagePercent": 2, "productUsage": [{"product": "GrokBuild", "usagePercent": 40}], "currentPeriod": {"end": "2026-08-29T00:00:00+00:00"}}}
        """
        let (usage, _) = try await fetch(body: body)
        #expect(usage.weekly?.percent == 2)
    }

    @Test func usedAndLimitAreFallbackWhenCreditPercentIsAbsent() async throws {
        let (usage, _) = try await fetch(body: openUsageBody)
        #expect(usage.weekly?.percent == 4277.0 / 60000.0 * 100)
        #expect(usage.session == nil)
        #expect(usage.weekly?.resetsAt == isoDate("2026-06-01T00:00:00+00:00"))
    }

    @Test func snakeCaseBodyDecodesNestedVal() async throws {
        let body = """
        {"config": {"monthly_limit": {"val": 60000}, "used": {"val": 4277}, "billing_period_end": "2026-06-01T00:00:00+00:00"}}
        """
        let (usage, _) = try await fetch(body: body)
        #expect(usage.weekly?.percent == 4277.0 / 60000.0 * 100)
        #expect(usage.weekly?.resetsAt == isoDate("2026-06-01T00:00:00+00:00"))
    }

    @Test func camelCaseBodyDecodesNestedVal() async throws {
        let body = """
        {"config": {"monthlyLimit": {"val": 60000}, "used": {"val": 4277}, "billingPeriodEnd": "2026-06-01T00:00:00+00:00"}}
        """
        let (usage, _) = try await fetch(body: body)
        #expect(usage.weekly?.percent == 4277.0 / 60000.0 * 100)
        #expect(usage.weekly?.resetsAt == isoDate("2026-06-01T00:00:00+00:00"))
    }

    @Test func fractionalValDecodesAsDouble() async throws {
        let body = """
        {"config": {"monthlyLimit": {"val": 60000.0}, "used": {"val": 4277.5}, "billingPeriodEnd": "2026-06-01T00:00:00+00:00"}}
        """
        let (usage, _) = try await fetch(body: body)
        #expect(usage.weekly?.percent == 4277.5 / 60000.0 * 100)
    }
}

// MARK: - Fetch policy / error mapping

@Suite struct GrokUsageFetcherTests {
    @Test func credentialsClosureThrowingNonUsageErrorMapsToCredentialsMissingWithoutNetwork() async throws {
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = makeFetcher(accessToken: { throw DummyError() }, transport: transport)
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .credentialsMissing")
        } catch let error as UsageFetchError {
            #expect(error == .credentialsMissing)
        }
        #expect(transport.callCount == 0)
    }

    @Test(arguments: [401, 403]) func authErrorStatusesMapToTokenExpired(status: Int) async throws {
        let transport = TransportSpy([.success(status: status, body: Data())])
        let fetcher = makeFetcher(transport: transport)
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .tokenExpired")
        } catch let error as UsageFetchError {
            #expect(error == .tokenExpired)
        }
    }

    @Test func rateLimitedParsesDeltaSecondsRetryAfter() async throws {
        let transport = TransportSpy([.success(status: 429, headers: ["Retry-After": "15"], body: Data())])
        let fetcher = makeFetcher(transport: transport)
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .rateLimited")
        } catch let error as UsageFetchError {
            #expect(error == .rateLimited(retryAfter: 15))
        }
    }
}
