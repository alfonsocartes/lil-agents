import Foundation
import Testing
@testable import AgentDeck

// MARK: - Shared fixtures

/// A syntactically-valid `~/.claude/.credentials.json` payload. `expiresAtMs`
/// defaults far in the future so tests that don't care about expiry never
/// trip the local short-circuit by accident.
private func claudeCredentialsJSON(accessToken: String = "tok-123", expiresAtMs: Int64 = 9_999_999_999_999) -> Data {
    Data("""
    {"claudeAiOauth": {"accessToken": "\(accessToken)", "expiresAt": \(expiresAtMs)}}
    """.utf8)
}

/// Writes `credentials` into a fresh temp dir and returns its file URL,
/// mirroring HookInstallerTests' temp-dir pattern so a run never touches the
/// developer's real `~/.claude/.credentials.json`.
private func writeCredentials(_ credentials: Data, in dir: URL) -> URL {
    let url = dir.appendingPathComponent(".credentials.json")
    try! credentials.write(to: url)
    return url
}

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

// MARK: - Response decoding

@Suite struct ClaudeUsageDecodingTests {
    private func fetch(body: String, dir: URL) async throws -> ProviderUsage {
        let fileURL = writeCredentials(claudeCredentialsJSON(), in: dir)
        let transport = TransportSpy([.success(status: 200, body: Data(body.utf8))])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { fileURL }, keychainRead: { nil }, transport: transport.handle, now: { fixedNow }
        )
        return try await fetcher.fetchUsage()
    }

    @Test func fullResponseDecodesFiveHourAndSevenDay() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let usage = try await fetch(body: """
        {
          "five_hour": {"utilization": 62.5, "resets_at": "2023-11-14T22:13:20.123Z"},
          "seven_day": {"utilization": 41, "resets_at": "2023-11-17T09:00:00Z"}
        }
        """, dir: dir)
        #expect(usage.session?.percent == 62.5)
        #expect(usage.weekly?.percent == 41)
        #expect(usage.session?.resetsAt != nil)
        #expect(usage.weekly?.resetsAt != nil)
    }

    @Test func limitsFallbackUsesPercentFieldAndPrefersActiveIgnoringUnknownKinds() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
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
        """, dir: dir)
        #expect(usage.session?.percent == 55)     // active entry wins over the inactive one
        #expect(usage.weekly?.percent == 20.5)     // weekly_all only — weekly_scoped/unknown ignored
    }

    @Test func integerPercentsDecodeAsWellAsFractional() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let usage = try await fetch(body: """
        {"five_hour": {"utilization": 62, "resets_at": "2023-11-14T22:13:20Z"}}
        """, dir: dir)
        #expect(usage.session?.percent == 62)
    }

    @Test func isoDatesParseWithAndWithoutFractionalSeconds() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let usage = try await fetch(body: """
        {
          "five_hour": {"utilization": 10, "resets_at": "2023-11-14T22:13:20.500Z"},
          "seven_day": {"utilization": 20, "resets_at": "2023-11-17T09:00:00Z"}
        }
        """, dir: dir)

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]

        #expect(usage.session?.resetsAt == withFractional.date(from: "2023-11-14T22:13:20.500Z"))
        #expect(usage.weekly?.resetsAt == withoutFractional.date(from: "2023-11-17T09:00:00Z"))
    }

    @Test func emptyObjectDecodesToNilWindows() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let usage = try await fetch(body: "{}", dir: dir)
        #expect(usage.session == nil)
        #expect(usage.weekly == nil)
    }
}

// MARK: - Fetch policy / error mapping

@Suite struct ClaudeUsageFetcherTests {
    @Test func fileFirstOrderingSkipsKeychainWhenFileExists() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let fileURL = writeCredentials(claudeCredentialsJSON(), in: dir)
        let keychain = KeychainSpy(returning: nil)
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { fileURL }, keychainRead: keychain.read, transport: transport.handle, now: { fixedNow }
        )
        _ = try await fetcher.fetchUsage()
        #expect(keychain.callCount == 0)
    }

    @Test func keychainTriedAtMostOncePerFetcherLifetime() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let missingFileURL = dir.appendingPathComponent("nope.json")   // never written
        let keychain = KeychainSpy(returning: nil)                     // simulates denial/absence
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { missingFileURL }, keychainRead: keychain.read, transport: transport.handle, now: { fixedNow }
        )

        await expectCredentialsMissing(fetcher)
        #expect(keychain.callCount == 1)

        // Second fetch after the first denial must NOT re-prompt.
        await expectCredentialsMissing(fetcher)
        #expect(keychain.callCount == 1)
    }

    @Test func bothFileAndKeychainMissingMapsToCredentialsMissing() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let missingFileURL = dir.appendingPathComponent("nope.json")
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { missingFileURL }, keychainRead: { nil }, transport: transport.handle, now: { fixedNow }
        )
        await expectCredentialsMissing(fetcher)
    }

    @Test func localExpiryShortCircuitsWithoutCallingTransport() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let expiredMs = Int64(fixedNow.timeIntervalSince1970 * 1000) - 1000   // 1s before `now`
        let fileURL = writeCredentials(claudeCredentialsJSON(expiresAtMs: expiredMs), in: dir)
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { fileURL }, keychainRead: { nil }, transport: transport.handle, now: { fixedNow }
        )
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .tokenExpired")
        } catch let error as UsageFetchError {
            #expect(error == .tokenExpired)
        }
        #expect(transport.callCount == 0)
    }

    @Test(arguments: [401, 403]) func authErrorStatusesMapToTokenExpired(status: Int) async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let fileURL = writeCredentials(claudeCredentialsJSON(), in: dir)
        let transport = TransportSpy([.success(status: status, body: Data())])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { fileURL }, keychainRead: { nil }, transport: transport.handle, now: { fixedNow }
        )
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .tokenExpired")
        } catch let error as UsageFetchError {
            #expect(error == .tokenExpired)
        }
    }

    @Test func rateLimitedParsesDeltaSecondsRetryAfter() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let fileURL = writeCredentials(claudeCredentialsJSON(), in: dir)
        let transport = TransportSpy([.success(status: 429, headers: ["Retry-After": "30"], body: Data())])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { fileURL }, keychainRead: { nil }, transport: transport.handle, now: { fixedNow }
        )
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .rateLimited")
        } catch let error as UsageFetchError {
            #expect(error == .rateLimited(retryAfter: 30))
        }
    }

    @Test func rateLimitedParsesHTTPDateRetryAfterRelativeToInjectedNow() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let fileURL = writeCredentials(claudeCredentialsJSON(), in: dir)

        let retryDate = fixedNow.addingTimeInterval(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: retryDate)

        let transport = TransportSpy([.success(status: 429, headers: ["Retry-After": header], body: Data())])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { fileURL }, keychainRead: { nil }, transport: transport.handle, now: { fixedNow }
        )
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
        let dir = makeTempDir(); defer { cleanup(dir) }
        let fileURL = writeCredentials(claudeCredentialsJSON(), in: dir)
        let transport = TransportSpy([.success(status: 500, body: Data())])
        let fetcher = ClaudeUsageFetcher(
            credentialsFileURL: { fileURL }, keychainRead: { nil }, transport: transport.handle, now: { fixedNow }
        )
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

    private func expectCredentialsMissing(_ fetcher: ClaudeUsageFetcher) async {
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .credentialsMissing")
        } catch let error as UsageFetchError {
            #expect(error == .credentialsMissing)
        } catch {
            Issue.record("expected UsageFetchError, got \(error)")
        }
    }
}
