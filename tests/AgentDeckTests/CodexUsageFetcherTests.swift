import Foundation
import Testing
@testable import AgentDeck

// MARK: - Shared fixtures

/// Writes `~/.codex/auth.json`-shaped `contents` into a fresh `.codex`
/// subdirectory of `dir` and returns the `.codex` directory URL — what
/// `codexHomeURL` should be pointed at. Mirrors HookInstallerTests' temp-dir
/// pattern so a run never touches the developer's real `~/.codex`.
private func writeCodexAuth(_ contents: String, in dir: URL) -> URL {
    let codexHome = dir.appendingPathComponent(".codex", isDirectory: true)
    try! FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try! Data(contents.utf8).write(to: codexHome.appendingPathComponent("auth.json"))
    return codexHome
}

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - auth.json + response decoding

@Suite struct CodexUsageDecodingTests {
    private func fetch(auth: String, body: String, dir: URL) async throws -> ProviderUsage {
        let codexHome = writeCodexAuth(auth, in: dir)
        let transport = TransportSpy([.success(status: 200, body: Data(body.utf8))])
        let fetcher = CodexUsageFetcher(codexHomeURL: { codexHome }, transport: transport.handle, now: { fixedNow })
        return try await fetcher.fetchUsage()
    }

    private let weeklyOnlyBody = """
    {"rate_limit": {"primary_window": {"used_percent": 30, "reset_at": 1700003600, "limit_window_seconds": 604800}}}
    """

    @Test func snakeCaseAuthJSONDecodes() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let usage = try await fetch(
            auth: #"{"tokens": {"access_token": "tok-abc", "account_id": "acct-1"}}"#,
            body: weeklyOnlyBody, dir: dir
        )
        #expect(usage.weekly?.percent == 30)
    }

    @Test func camelCaseAuthJSONDecodes() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let usage = try await fetch(
            auth: #"{"tokens": {"accessToken": "tok-abc", "accountId": "acct-1"}}"#,
            body: weeklyOnlyBody, dir: dir
        )
        #expect(usage.weekly?.percent == 30)
    }

    @Test func apiKeyOnlyAuthJSONMapsToCredentialsMissing() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let codexHome = writeCodexAuth(#"{"OPENAI_API_KEY": "sk-abc123"}"#, in: dir)
        let transport = TransportSpy([.success(status: 200, body: Data(weeklyOnlyBody.utf8))])
        let fetcher = CodexUsageFetcher(codexHomeURL: { codexHome }, transport: transport.handle, now: { fixedNow })
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .credentialsMissing")
        } catch let error as UsageFetchError {
            #expect(error == .credentialsMissing)
        }
        #expect(transport.callCount == 0)   // never even reaches the network
    }

    @Test func weeklyOnlyResponseLeavesSessionNil() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let usage = try await fetch(
            auth: #"{"tokens": {"access_token": "tok-abc"}}"#, body: weeklyOnlyBody, dir: dir
        )
        #expect(usage.session == nil)
        #expect(usage.weekly?.percent == 30)
    }

    @Test func classifiesBySwappedLimitWindowSecondsNotSlotPosition() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        // Weekly limit reported in the PRIMARY slot, session limit in
        // SECONDARY — classification must key off `limit_window_seconds`,
        // not which JSON field the window arrived in.
        let usage = try await fetch(
            auth: #"{"tokens": {"access_token": "tok-abc"}}"#,
            body: """
            {"rate_limit": {
              "primary_window": {"used_percent": 41, "reset_at": 1700100000, "limit_window_seconds": 604800},
              "secondary_window": {"used_percent": 62, "reset_at": 1700010000, "limit_window_seconds": 18000}
            }}
            """,
            dir: dir
        )
        #expect(usage.weekly?.percent == 41)
        #expect(usage.session?.percent == 62)
    }

    @Test func resetAtIsParsedAsEpochSeconds() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let usage = try await fetch(
            auth: #"{"tokens": {"access_token": "tok-abc"}}"#, body: weeklyOnlyBody, dir: dir
        )
        #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_700_003_600))
    }
}

// MARK: - Fetch policy / error mapping

@Suite struct CodexUsageFetcherTests {
    @Test func homeDirOverrideSeamIsRespected() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let codexHome = writeCodexAuth(#"{"tokens": {"access_token": "tok-abc"}}"#, in: dir)
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = CodexUsageFetcher(codexHomeURL: { codexHome }, transport: transport.handle, now: { fixedNow })
        _ = try await fetcher.fetchUsage()
        #expect(transport.callCount == 1)   // reading from the overridden home succeeded
    }

    @Test func missingAccountIDOmitsHeader() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let codexHome = writeCodexAuth(#"{"tokens": {"access_token": "tok-abc"}}"#, in: dir)   // no account_id
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = CodexUsageFetcher(codexHomeURL: { codexHome }, transport: transport.handle, now: { fixedNow })
        _ = try await fetcher.fetchUsage()
        #expect(transport.requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    @Test func presentAccountIDSetsHeader() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let codexHome = writeCodexAuth(#"{"tokens": {"access_token": "tok-abc", "account_id": "acct-1"}}"#, in: dir)
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = CodexUsageFetcher(codexHomeURL: { codexHome }, transport: transport.handle, now: { fixedNow })
        _ = try await fetcher.fetchUsage()
        #expect(transport.requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
    }

    @Test func missingAuthFileMapsToCredentialsMissing() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        // `.codex` directory is never created here.
        let codexHome = dir.appendingPathComponent(".codex", isDirectory: true)
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let fetcher = CodexUsageFetcher(codexHomeURL: { codexHome }, transport: transport.handle, now: { fixedNow })
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
        let codexHome = writeCodexAuth(#"{"tokens": {"access_token": "tok-abc"}}"#, in: dir)
        let transport = TransportSpy([.success(status: status, body: Data())])
        let fetcher = CodexUsageFetcher(codexHomeURL: { codexHome }, transport: transport.handle, now: { fixedNow })
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .tokenExpired")
        } catch let error as UsageFetchError {
            #expect(error == .tokenExpired)
        }
    }

    @Test func rateLimitedParsesDeltaSecondsRetryAfter() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let codexHome = writeCodexAuth(#"{"tokens": {"access_token": "tok-abc"}}"#, in: dir)
        let transport = TransportSpy([.success(status: 429, headers: ["Retry-After": "15"], body: Data())])
        let fetcher = CodexUsageFetcher(codexHomeURL: { codexHome }, transport: transport.handle, now: { fixedNow })
        do {
            _ = try await fetcher.fetchUsage()
            Issue.record("expected .rateLimited")
        } catch let error as UsageFetchError {
            #expect(error == .rateLimited(retryAfter: 15))
        }
    }
}
