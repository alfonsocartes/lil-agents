import Foundation
import Synchronization
import Testing
@testable import AgentDeck

// MARK: - Stub provider

/// Canned, ordered `UsageProviding` stub: each call to `fetchUsage()` returns
/// the next configured result, repeating the last one for any call beyond
/// the list's length. `Mutex`-backed (never `@unchecked Sendable`), mirroring
/// `TransportSpy`/`KeychainSpy` in TestSupport.swift.
private final class StubUsageProvider: UsageProviding, Sendable {
    enum StubResult {
        case success(ProviderUsage)
        case failure(UsageFetchError)
    }

    private struct State {
        var callCount = 0
        var results: [StubResult]
    }

    private let state: Mutex<State>

    init(_ results: [StubResult]) {
        state = Mutex(State(results: results))
    }

    var callCount: Int { state.withLock { $0.callCount } }

    func fetchUsage() async throws -> ProviderUsage {
        let result = state.withLock { s -> StubResult? in
            guard !s.results.isEmpty else { return nil }
            let index = min(s.callCount, s.results.count - 1)
            let picked = s.results[index]
            s.callCount += 1
            return picked
        }
        guard let result else { throw UsageFetchError.credentialsMissing }
        switch result {
        case .success(let usage): return usage
        case .failure(let error): throw error
        }
    }
}

// MARK: - Test helpers

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// `AppSettings` persists straight to `UserDefaults.standard` with no
/// injectable override (see AppSettings.swift — it has no seam like
/// HookInstaller's `homeDirectoryOverride`). Explicitly seeding both usage
/// keys before constructing means every test starts from a KNOWN state
/// regardless of what a previous test run left behind in this process's
/// defaults domain.
@MainActor
private func makeSettings(claudeEnabled: Bool = false, codexEnabled: Bool = false) -> AppSettings {
    UserDefaults.standard.set(claudeEnabled, forKey: "usage.claudeEnabled")
    UserDefaults.standard.set(codexEnabled, forKey: "usage.codexEnabled")
    return AppSettings()
}

/// Polls `condition` via `Task.yield()` until it's true or `timeout` elapses.
/// Needed because `UsageStore`'s settings-reactivity hops through a
/// `Task { @MainActor }` (see `armSettingsObservation`), so there's no single
/// awaitable to hang an assertion off of after toggling a setting — this is
/// the same "await the effect, not a specific task" tradeoff any
/// Observation-driven side effect forces on its tests. On timeout this just
/// returns; the assertion that follows fails with a clear actual-vs-expected
/// diff instead of hanging.
@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return }
        await Task.yield()
    }
}

@MainActor
private func settle(_ yields: Int = 30) async {
    for _ in 0..<yields { await Task.yield() }
}

/// `waitUntil { provider.callCount >= N }` alone races `performFetch`: the
/// stub increments its call count and throws/returns SYNCHRONOUSLY inside
/// `fetchUsage()`, but the `try await provider.fetchUsage()` call site still
/// crosses an async boundary, so the poller can observe the new call count
/// one hop before the store finishes writing the resulting state. Waiting
/// for "N calls AND no longer `.loading`" closes that gap.
private func isLoading(_ state: ProviderUsageState) -> Bool {
    if case .loading = state { return true }
    return false
}

// MARK: - Tests

@MainActor
@Suite struct UsageStoreTests {
    @Test func startsDisabledWhenBothTogglesAreOff() {
        let settings = makeSettings()
        let store = UsageStore(settings: settings, claudeProvider: StubUsageProvider([]), codexProvider: StubUsageProvider([]))
        #expect(store.claude == .disabled)
        #expect(store.codex == .disabled)
    }

    @Test func enablingAfterConstructionTransitionsToAvailable() async {
        let settings = makeSettings()
        let usage = ProviderUsage(session: UsageWindow(percent: 40, resetsAt: nil), weekly: nil, fetchedAt: fixedNow)
        let provider = StubUsageProvider([.success(usage)])
        let store = UsageStore(settings: settings, claudeProvider: provider, codexProvider: StubUsageProvider([]))
        #expect(store.claude == .disabled)

        settings.claudeUsageEnabled = true
        await waitUntil { store.claude == .available(usage) }
        #expect(store.claude == .available(usage))
    }

    @Test func disablingAfterAvailableReturnsToDisabled() async {
        let settings = makeSettings(claudeEnabled: true)
        let usage = ProviderUsage(session: nil, weekly: nil, fetchedAt: fixedNow)
        let provider = StubUsageProvider([.success(usage)])
        let store = UsageStore(settings: settings, claudeProvider: provider, codexProvider: StubUsageProvider([]))

        await store.refresh()
        #expect(store.claude == .available(usage))

        settings.claudeUsageEnabled = false
        await waitUntil { store.claude == .disabled }
        #expect(store.claude == .disabled)
    }

    @Test func successThenFailureBecomesStaleKeepingLastUsage() async {
        let settings = makeSettings(claudeEnabled: true)
        let usage = ProviderUsage(session: UsageWindow(percent: 40, resetsAt: nil), weekly: nil, fetchedAt: fixedNow)
        let provider = StubUsageProvider([.success(usage), .failure(.network("boom"))])
        let store = UsageStore(settings: settings, claudeProvider: provider, codexProvider: StubUsageProvider([]))

        await store.refresh()
        #expect(store.claude == .available(usage))

        await store.refresh()
        guard case .stale(let last, let error) = store.claude else {
            Issue.record("expected .stale, got \(store.claude)")
            return
        }
        #expect(last == usage)
        #expect(error == .network("boom"))
    }

    @Test func failureFirstBecomesUnavailable() async {
        let settings = makeSettings(claudeEnabled: true)
        let provider = StubUsageProvider([.failure(.credentialsMissing)])
        let store = UsageStore(settings: settings, claudeProvider: provider, codexProvider: StubUsageProvider([]))

        await store.refresh()
        #expect(store.claude == .unavailable(.credentialsMissing))
    }

    @Test func refreshIfStaleThrottlesViaLastAttemptAtIncludingAfterFailures() async {
        let settings = makeSettings()   // start disabled; enable below once `now` is wired up
        var clock = fixedNow
        let provider = StubUsageProvider([
            .failure(.network("down")),
            .failure(.network("down")),
            .success(ProviderUsage(session: nil, weekly: nil, fetchedAt: fixedNow)),
        ])
        let store = UsageStore(settings: settings, claudeProvider: provider, codexProvider: StubUsageProvider([]))
        store.now = { clock }

        settings.claudeUsageEnabled = true
        await waitUntil { provider.callCount >= 1 && !isLoading(store.claude) }
        await settle()   // let the launching `refresh(_:)` call finish clearing its task slot
        #expect(provider.callCount == 1)
        #expect(store.claude == .unavailable(.network("down")))

        // Same instant, well under the 60s default `minAge`: must NOT re-fetch,
        // even though the last attempt FAILED and left no `ProviderUsage` to
        // throttle against via `fetchedAt` alone.
        store.refreshIfStale()
        await settle()
        #expect(provider.callCount == 1)

        // Past `minAge`: fires again (still fails).
        clock = clock.addingTimeInterval(61)
        store.refreshIfStale()
        await waitUntil { provider.callCount >= 2 && !isLoading(store.claude) }
        await settle()   // see the comment above the first `settle()` in this test
        #expect(provider.callCount == 2)
        #expect(store.claude == .unavailable(.network("down")))

        // Past `minAge` again: fires a third time, now succeeding.
        clock = clock.addingTimeInterval(61)
        store.refreshIfStale()
        await waitUntil { provider.callCount >= 3 && !isLoading(store.claude) }
        #expect(provider.callCount == 3)
        if case .available = store.claude {} else {
            Issue.record("expected .available, got \(store.claude)")
        }
    }

    @Test func retryAfterGateSuppressesRefreshIfStaleUntilItElapses() async {
        let settings = makeSettings()
        var clock = fixedNow
        let provider = StubUsageProvider([
            .failure(.rateLimited(retryAfter: 120)),
            .success(ProviderUsage(session: nil, weekly: nil, fetchedAt: fixedNow)),
        ])
        let store = UsageStore(settings: settings, claudeProvider: provider, codexProvider: StubUsageProvider([]))
        store.now = { clock }

        settings.claudeUsageEnabled = true
        await waitUntil { provider.callCount >= 1 && !isLoading(store.claude) }
        await settle()   // let the launching `refresh(_:)` call finish clearing its task slot
        #expect(provider.callCount == 1)
        #expect(store.claude == .unavailable(.rateLimited(retryAfter: 120)))

        // Past the default 60s `minAge` but still WELL WITHIN the 120s
        // Retry-After window: the rate-limit gate must still suppress it.
        clock = clock.addingTimeInterval(90)
        store.refreshIfStale()
        await settle()
        #expect(provider.callCount == 1)

        // Past both the 120s Retry-After window AND `minAge`: fires again.
        clock = clock.addingTimeInterval(60)   // total +150s
        store.refreshIfStale()
        await waitUntil { provider.callCount >= 2 && !isLoading(store.claude) }
        #expect(provider.callCount == 2)
    }

    @Test func concurrentRefreshCallsDedupeToOneProviderInvocation() async {
        let settings = makeSettings(claudeEnabled: true)
        let usage = ProviderUsage(session: nil, weekly: nil, fetchedAt: fixedNow)
        let provider = StubUsageProvider([.success(usage)])
        let store = UsageStore(settings: settings, claudeProvider: provider, codexProvider: StubUsageProvider([]))

        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        #expect(provider.callCount == 1)
        #expect(store.claude == .available(usage))
    }
}
