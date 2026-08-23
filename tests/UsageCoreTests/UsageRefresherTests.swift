import Foundation
import Testing
@testable import UsageCore

@Suite struct UsageRefresherTests {
    private let usage = ProviderUsage(
        session: UsageWindow(percent: 40, resetsAt: nil),
        weekly: nil,
        fetchedAt: fixedNow
    )

    @Test func applyEnabledFlagsHidesDisabledWithoutFetching() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = SnapshotStore(directory: dir)
        try store.save(UsageSnapshot(
            claude: ProviderSnapshot(
                enabled: true, usage: usage, lastAttemptAt: fixedNow,
                retryAfterUntil: fixedNow.addingTimeInterval(30)
            ),
            grok: .empty,
            codex: ProviderSnapshot(enabled: true, usage: usage, lastAttemptAt: fixedNow)
        ))
        let provider = StubUsageProvider([.success(usage)])
        let refresher = UsageRefresher(
            snapshotStore: store,
            tokens: MemoryTokenStore([.codex: "tok"]),
            claudeProvider: provider,
            now: { fixedNow }
        )

        let snapshot = await refresher.applyEnabledFlags(
            UsageSettings(claudeEnabled: true, grokEnabled: false, codexEnabled: false)
        )
        #expect(snapshot.claude.enabled == true)
        #expect(snapshot.claude.lastAttemptAt == fixedNow)
        #expect(snapshot.codex.enabled == false)
        #expect(snapshot.codex.usage == usage)
        #expect(snapshot.codex.lastAttemptAt == nil)
        #expect(provider.callCount == 0)
        #expect(store.load().codex.enabled == false)
    }

    @Test func disabledSkipsFetchAndKeepsLastUsage() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = SnapshotStore(directory: dir)
        try store.save(UsageSnapshot(
            claude: ProviderSnapshot(enabled: true, usage: usage, lastError: nil, lastAttemptAt: fixedNow),
            grok: .empty,
            codex: .empty
        ))
        let provider = StubUsageProvider([.success(usage)])
        let tokens = MemoryTokenStore([.claude: "tok"])
        let refresher = UsageRefresher(
            snapshotStore: store,
            tokens: tokens,
            claudeProvider: provider,
            now: { fixedNow }
        )

        let snapshot = await refresher.refreshAll(settings: UsageSettings(claudeEnabled: false))
        #expect(snapshot.claude.enabled == false)
        #expect(snapshot.claude.usage == usage)
        #expect(snapshot.claude.lastAttemptAt == nil)
        #expect(snapshot.claude.retryAfterUntil == nil)
        #expect(provider.callCount == 0)
    }

    @Test func reEnableAfterDisableFetchesImmediately() async throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = SnapshotStore(directory: dir)
        try store.save(UsageSnapshot(
            claude: ProviderSnapshot(
                enabled: true,
                usage: usage,
                lastError: nil,
                lastAttemptAt: fixedNow,
                retryAfterUntil: fixedNow.addingTimeInterval(120)
            ),
            grok: .empty,
            codex: .empty
        ))
        let provider = StubUsageProvider([.success(usage)])
        let clock = TestClock(fixedNow)
        let refresher = UsageRefresher(
            snapshotStore: store,
            tokens: MemoryTokenStore([.claude: "tok"]),
            claudeProvider: provider,
            now: { clock.now }
        )

        _ = await refresher.refreshAll(settings: UsageSettings(claudeEnabled: false), minAge: 60)
        #expect(provider.callCount == 0)

        let snapshot = await refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(provider.callCount == 1)
        #expect(snapshot.claude.enabled == true)
        #expect(snapshot.claude.usage == usage)
        #expect(snapshot.claude.lastAttemptAt == fixedNow)
        #expect(snapshot.claude.retryAfterUntil == nil)
    }

    @Test func successWritesAvailable() async {
        let env = makeEnv(claude: StubUsageProvider([.success(usage)]))
        defer { cleanup(env.dir) }

        let snapshot = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(snapshot.claude.enabled == true)
        #expect(snapshot.claude.usage == usage)
        #expect(snapshot.claude.lastError == nil)
        #expect(snapshot.claude.lastAttemptAt == fixedNow)
        #expect(snapshot.claude.retryAfterUntil == nil)
        #expect(env.claude.callCount == 1)
        #expect(env.store.load() == snapshot)
    }

    @Test func failThenFailKeepsUnavailable() async {
        let env = makeEnv(claude: StubUsageProvider([
            .failure(.network("a")),
            .failure(.network("b")),
        ]))
        defer { cleanup(env.dir) }

        let first = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(first.claude.usage == nil)
        #expect(first.claude.lastError == .network("a"))
        #expect(env.claude.callCount == 1)

        env.clock.advance(61)
        let second = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(second.claude.usage == nil)
        #expect(second.claude.lastError == .network("b"))
        #expect(env.claude.callCount == 2)
    }

    @Test func successThenFailKeepsUsageAndLastError() async {
        let env = makeEnv(claude: StubUsageProvider([
            .success(usage),
            .failure(.network("boom")),
        ]))
        defer { cleanup(env.dir) }

        let first = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(first.claude.usage == usage)
        #expect(first.claude.lastError == nil)

        env.clock.advance(61)
        let second = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(second.claude.usage == usage)
        #expect(second.claude.lastError == .network("boom"))
        #expect(env.claude.callCount == 2)
    }

    @Test func minAgeThrottlesIncludingAfterFailures() async {
        let env = makeEnv(claude: StubUsageProvider([
            .failure(.network("down")),
            .success(usage),
        ]))
        defer { cleanup(env.dir) }

        _ = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(env.claude.callCount == 1)

        _ = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(env.claude.callCount == 1)

        env.clock.advance(61)
        let later = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(env.claude.callCount == 2)
        #expect(later.claude.usage == usage)
        #expect(later.claude.lastError == nil)
    }

    @Test func retryAfterGateBlocksEvenAfterMinAge() async {
        let env = makeEnv(claude: StubUsageProvider([
            .failure(.rateLimited(retryAfter: 120)),
            .success(usage),
        ]))
        defer { cleanup(env.dir) }

        let first = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(env.claude.callCount == 1)
        #expect(first.claude.lastError == .rateLimited(retryAfter: 120))
        #expect(first.claude.retryAfterUntil == fixedNow.addingTimeInterval(120))

        // Past the 60s minAge but still within the 120s Retry-After window.
        env.clock.advance(90)
        _ = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(env.claude.callCount == 1)

        env.clock.advance(60)   // total +150s
        let later = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(env.claude.callCount == 2)
        #expect(later.claude.usage == usage)
        #expect(later.claude.retryAfterUntil == nil)
    }

    @Test func tokenExpiredStillThrottlesUntilRefreshNow() async {
        let env = makeEnv(claude: StubUsageProvider([
            .failure(.tokenExpired),
            .success(usage),
        ]))
        defer { cleanup(env.dir) }

        let first = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(first.claude.lastError == .tokenExpired)
        #expect(env.claude.callCount == 1)

        _ = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(env.claude.callCount == 1)

        let forced = await env.refresher.refreshNow(settings: UsageSettings(claudeEnabled: true))
        #expect(env.claude.callCount == 2)
        #expect(forced.claude.usage == usage)
        #expect(forced.claude.lastError == nil)
    }

    @Test func refreshNowBypassesRetryAfterSoANewTokenCanFetch() async {
        let env = makeEnv(claude: StubUsageProvider([
            .failure(.rateLimited(retryAfter: 120)),
            .success(usage),
        ]))
        defer { cleanup(env.dir) }

        _ = await env.refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(env.claude.callCount == 1)

        let forced = await env.refresher.refreshNow(settings: UsageSettings(claudeEnabled: true))
        #expect(env.claude.callCount == 2)
        #expect(forced.claude.usage == usage)
        #expect(forced.claude.retryAfterUntil == nil)
    }

    @Test func defaultMinAgeIsTwentyMinutes() {
        #expect(UsageRefresher.defaultMinAge == 20 * 60)
    }

    @Test func credentialsMissingDoesNotNetwork() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let store = SnapshotStore(directory: dir)
        let provider = StubUsageProvider([.success(usage)])
        let refresher = UsageRefresher(
            snapshotStore: store,
            tokens: MemoryTokenStore(),
            claudeProvider: provider,
            now: { fixedNow }
        )

        let snapshot = await refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(snapshot.claude.enabled == true)
        #expect(snapshot.claude.usage == nil)
        #expect(snapshot.claude.lastError == .credentialsMissing)
        #expect(provider.callCount == 0)
    }

    @Test func productionPathParsesTokenAndFetches() async {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let tokens = MemoryTokenStore([
            .claude: #"{"claudeAiOauth": {"accessToken": "tok-123", "expiresAt": 9999999999999}}"#
        ])
        let transport = TransportSpy([.success(status: 200, body: Data(#"{"five_hour": {"utilization": 62.5}}"#.utf8))])
        let refresher = UsageRefresher(
            snapshotStore: SnapshotStore(directory: dir),
            tokens: tokens,
            now: { fixedNow },
            transport: transport.handle
        )

        let snapshot = await refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(transport.callCount == 1)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(snapshot.claude.usage?.session?.percent == 62.5)
        #expect(snapshot.claude.lastError == nil)
    }

    @Test func productionPathHonorsClaudeLocalExpiryWithoutNetwork() async {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let expiredMs = Int64(fixedNow.timeIntervalSince1970 * 1000) - 1000
        let tokens = MemoryTokenStore([
            .claude: #"{"claudeAiOauth": {"accessToken": "tok-123", "expiresAt": \#(expiredMs)}}"#
        ])
        let transport = TransportSpy([.success(status: 200, body: Data("{}".utf8))])
        let refresher = UsageRefresher(
            snapshotStore: SnapshotStore(directory: dir),
            tokens: tokens,
            now: { fixedNow },
            transport: transport.handle
        )

        let snapshot = await refresher.refreshAll(settings: UsageSettings(claudeEnabled: true), minAge: 60)
        #expect(transport.callCount == 0)
        #expect(snapshot.claude.lastError == .tokenExpired)
        #expect(snapshot.claude.usage == nil)
    }

    private struct Env {
        var dir: URL
        var store: SnapshotStore
        var clock: TestClock
        var claude: StubUsageProvider
        var refresher: UsageRefresher
    }

    private func makeEnv(claude: StubUsageProvider) -> Env {
        let dir = makeTempDir()
        let store = SnapshotStore(directory: dir)
        let clock = TestClock(fixedNow)
        let tokens = MemoryTokenStore([.claude: "tok"])
        let refresher = UsageRefresher(
            snapshotStore: store,
            tokens: tokens,
            claudeProvider: claude,
            now: { clock.now }
        )
        return Env(dir: dir, store: store, clock: clock, claude: claude, refresher: refresher)
    }
}
