import Foundation
import Testing
@testable import UsageCore

private struct DummyError: Error {}

private let futureExpiresAtMs: Int64 = 9_999_999_999_999

private func validCredentials(expiresAtMs: Int64? = futureExpiresAtMs) -> ClaudeCredentials {
    ClaudeCredentials(accessToken: "tok-123", expiresAt: expiresAtMs)
}

private func makeFetcher(
    credentials: @escaping @Sendable () throws -> ClaudeCredentials = { validCredentials() },
    transport: TransportSpy,
    now: Date = fixedNow
) -> ClaudeUsageFetcher {
    ClaudeUsageFetcher(credentials: credentials, transport: transport.handle, now: { now })
}

// MARK: - Response decoding

@Suite struct ClaudeUsageDecodingTests {
    private func fetch(body: String) async throws -> ProviderUsage {
        let transport = TransportSpy([.success(status: 200, body: Data(body.utf8))])
        return try await makeFetcher(transport: transport).fetchUsage()
    }

    @Test func fullResponseDecodesFiveHourAndSevenDay() async throws {
        let usage = try await fetch(body: """
        {
          "five_hour": {"utilization": 62.5, "resets_at": "2023-11-14T22:13:20.123Z"},
          "seven_day": {"utilization": 41, "resets_at": "2023-11-17T09:00:00Z"}
        }
        """)
        #expect(usage.session?.percent == 62.5)
        #expect(usage.weekly?.percent == 41)
        #expect(usage.session?.resetsAt != nil)
        #expect(usage.weekly?.resetsAt != nil)
    }

    @Test func limitsFallbackUsesPercentFieldAndPrefersActiveIgnoringUnknownKinds() async throws {
        let usage = try await fetch(body: """
        {
          "limits": [
            {"kind": "session", "percent": 30, "is_active": false, "resets_at": "2023-11-14T22:13:20Z"},
            {"kind": "session", "percent": 55, "is_active": true, "resets_at": "2023-11-14T23:00:00Z"},
            {"kind": "weekly_all", "percent": 20.5, "is_active": true, "resets_at": "2023-11-17T09:00:00Z"},
            {"kind": "weekly_scoped", "percent": 99, "is_active": true},
            {"kind": "totally_unknown", "percent": 5, "is_active": true}
          ]
        }
        """)
        #expect(usage.session?.percent == 55)     // active entry wins over the inactive one
        #expect(usage.weekly?.percent == 20.5)     // weekly_all only — weekly_scoped/unknown ignored
    }

    @Test func flatWindowsPreferredOverConflictingLimits() async throws {
        let usage = try await fetch(body: """
        {
          "five_hour": {"utilization": 10, "resets_at": "2023-11-14T22:13:20Z"},
          "seven_day": {"utilization": 11, "resets_at": "2023-11-17T09:00:00Z"},
          "limits": [
            {"kind": "session", "percent": 90, "is_active": true},
            {"kind": "weekly_all", "percent": 91, "is_active": true}
          ]
        }
        """)
        #expect(usage.session?.percent == 10)
        #expect(usage.weekly?.percent == 11)
    }

    @Test func integerPercentsDecodeAsWellAsFractional() async throws {
        let usage = try await fetch(body: """
        {"five_hour": {"utilization": 62, "resets_at": "2023-11-14T22:13:20Z"}}
        """)
        #expect(usage.session?.percent == 62)
    }

    @Test func isoDatesParseWithAndWithoutFractionalSeconds() async throws {
        let usage = try await fetch(body: """
        {
          "five_hour": {"utilization": 10, "resets_at": "2023-11-14T22:13:20.500Z"},
          "seven_day": {"utilization": 20, "resets_at": "2023-11-17T09:00:00Z"}
        }
        """)

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]

        #expect(usage.session?.resetsAt == withFractional.date(from: "2023-11-14T22:13:20.500Z"))
        #expect(usage.weekly?.resetsAt == withoutFractional.date(from: "2023-11-17T09:00:00Z"))
    }

    @Test func emptyObjectDecodesToNilWindows() async throws {
        let usage = try await fetch(body: "{}")
        #expect(usage.session == nil)
        #expect(usage.weekly == nil)
    }
}

// MARK: - Fetch policy / error mapping

@Suite struct ClaudeUsageFetcherTests {
    @Test func requestUsesOfficialHeaderSet() async throws {
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        _ = try await makeFetcher(transport: transport).fetchUsage()
        let request = transport.requests.first
        #expect(request?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request?.httpMethod == "GET")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.0")
    }

    @Test func credentialsClosureThrowingNonUsageErrorMapsToCredentialsMissingWithoutNetwork() async throws {
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = makeFetcher(credentials: { throw DummyError() }, transport: transport)
        await expectError(fetcher, .credentialsMissing)
        #expect(transport.callCount == 0)
    }

    @Test func credentialsClosureThrowingUsageFetchErrorRethrowsWithoutNetwork() async throws {
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = makeFetcher(credentials: { throw UsageFetchError.credentialsMissing }, transport: transport)
        await expectError(fetcher, .credentialsMissing)
        #expect(transport.callCount == 0)
    }

    @Test func localExpiryShortCircuitsWithoutCallingTransport() async throws {
        let expiredMs = Int64(fixedNow.timeIntervalSince1970 * 1000) - 1000   // 1s before `now`
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = makeFetcher(credentials: { validCredentials(expiresAtMs: expiredMs) }, transport: transport)
        await expectError(fetcher, .tokenExpired)
        #expect(transport.callCount == 0)
    }

    @Test(arguments: [401, 403]) func authErrorStatusesMapToTokenExpired(status: Int) async throws {
        let transport = TransportSpy([.success(status: status, body: Data())])
        let fetcher = makeFetcher(transport: transport)
        await expectError(fetcher, .tokenExpired)
    }

    @Test func rateLimitedParsesDeltaSecondsRetryAfter() async throws {
        let transport = TransportSpy([.success(status: 429, headers: ["Retry-After": "30"], body: Data())])
        let fetcher = makeFetcher(transport: transport)
        await expectError(fetcher, .rateLimited(retryAfter: 30))
    }

    @Test func rateLimitedParsesHTTPDateRetryAfterRelativeToInjectedNow() async throws {
        let retryDate = fixedNow.addingTimeInterval(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: retryDate)

        let transport = TransportSpy([.success(status: 429, headers: ["Retry-After": header], body: Data())])
        let fetcher = makeFetcher(transport: transport)
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .rateLimited")
        } catch let error as UsageFetchError {
            guard case .rateLimited(let retryAfter) = error, let retryAfter else {
                Issue.record("expected .rateLimited with a non-nil retryAfter, got \(error)")
                return
            }
            #expect(abs(retryAfter - 60) < 1)
        }
    }

    @Test func otherNonSuccessStatusMapsToBadResponse() async throws {
        let transport = TransportSpy([.success(status: 500, body: Data())])
        let fetcher = makeFetcher(transport: transport)
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .badResponse")
        } catch let error as UsageFetchError {
            guard case .badResponse = error else {
                Issue.record("expected .badResponse, got \(error)")
                return
            }
        }
    }

    private func expectError(_ fetcher: ClaudeUsageFetcher, _ expected: UsageFetchError) async {
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected \(expected)")
        } catch let error as UsageFetchError {
            #expect(error == expected)
        } catch {
            Issue.record("expected UsageFetchError, got \(error)")
        }
    }
}
