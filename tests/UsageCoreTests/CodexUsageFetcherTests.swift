import Foundation
import Testing
@testable import UsageCore

private struct DummyError: Error {}

private func makeFetcher(
    credentials: @escaping @Sendable () throws -> CodexCredentials = { CodexCredentials(accessToken: "tok-abc") },
    transport: TransportSpy,
    now: Date = fixedNow
) -> CodexUsageFetcher {
    CodexUsageFetcher(credentials: credentials, transport: transport.handle, now: { now })
}

private let weeklyOnlyBody = """
{"rate_limit": {"primary_window": {"used_percent": 30, "reset_at": 1700003600, "limit_window_seconds": 604800}}}
"""

// MARK: - Response decoding

@Suite struct CodexUsageDecodingTests {
    private func fetch(body: String, credentials: CodexCredentials = CodexCredentials(accessToken: "tok-abc")) async throws -> ProviderUsage {
        let transport = TransportSpy([.success(status: 200, body: Data(body.utf8))])
        let fetcher = makeFetcher(credentials: { credentials }, transport: transport)
        return try await fetcher.fetchUsage()
    }

    @Test func weeklyOnlyResponseLeavesSessionNil() async throws {
        let usage = try await fetch(body: weeklyOnlyBody)
        #expect(usage.session == nil)
        #expect(usage.weekly?.percent == 30)
    }

    @Test func classifiesBySwappedLimitWindowSecondsNotSlotPosition() async throws {
        // Weekly limit reported in the PRIMARY slot, session limit in
        // SECONDARY — classification must key off `limit_window_seconds`,
        // not which JSON field the window arrived in.
        let usage = try await fetch(body: """
        {"rate_limit": {
          "primary_window": {"used_percent": 41, "reset_at": 1700100000, "limit_window_seconds": 604800},
          "secondary_window": {"used_percent": 62, "reset_at": 1700010000, "limit_window_seconds": 18000}
        }}
        """)
        #expect(usage.weekly?.percent == 41)
        #expect(usage.session?.percent == 62)
    }

    @Test func resetAtIsParsedAsEpochSeconds() async throws {
        let usage = try await fetch(body: weeklyOnlyBody)
        #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_700_003_600))
    }

    @Test func unmatchedLimitWindowSecondsIsIgnoredNotGuessed() async throws {
        let usage = try await fetch(body: """
        {"rate_limit": {
          "primary_window": {"used_percent": 80, "reset_at": 1700003600, "limit_window_seconds": 10800},
          "secondary_window": {"used_percent": 10, "reset_at": 1700100000, "limit_window_seconds": 604800}
        }}
        """)
        #expect(usage.session == nil)
        #expect(usage.weekly?.percent == 10)
    }

    @Test func emptyObjectDecodesToNilWindows() async throws {
        let usage = try await fetch(body: "{}")
        #expect(usage.session == nil)
        #expect(usage.weekly == nil)
    }
}

// MARK: - Fetch policy / error mapping

@Suite struct CodexUsageFetcherTests {
    @Test func requestUsesOfficialHeaderSet() async throws {
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        _ = try await makeFetcher(transport: transport).fetchUsage()
        let request = transport.requests.first
        #expect(request?.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request?.httpMethod == "GET")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-abc")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == "codex-cli/agentdeck-usage")
        #expect(request?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    @Test func missingAccountIDOmitsHeader() async throws {
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = makeFetcher(credentials: { CodexCredentials(accessToken: "tok-abc") }, transport: transport)
        _ = try await fetcher.fetchUsage()
        #expect(transport.requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    @Test func presentAccountIDSetsHeader() async throws {
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = makeFetcher(
            credentials: { CodexCredentials(accessToken: "tok-abc", accountID: "acct-1") },
            transport: transport
        )
        _ = try await fetcher.fetchUsage()
        #expect(transport.requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
    }

    @Test func credentialsClosureThrowingNonUsageErrorMapsToCredentialsMissingWithoutNetwork() async throws {
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = makeFetcher(credentials: { throw DummyError() }, transport: transport)
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
