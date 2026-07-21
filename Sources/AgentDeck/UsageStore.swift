import Foundation
import Observation

/// Identifies which of the store's two provider slots an internal operation
/// is about. `UsageProviding` itself carries no such identity (see
/// UsageProvider.swift) — this is the store-private key used to index the
/// per-provider task/throttle/gate maps below.
private enum UsageProviderKind: Hashable {
    case claude
    case codex
}

/// Holds each provider's usage lifecycle and drives polling. Mirrors
/// `SessionStore`'s shape (main-actor `@Observable`, injectable clock, a
/// `Timer` the UI never touches directly) but adds two things SessionStore
/// doesn't need: awaitable, deduplicated fetches (`refresh()`), and settings
/// reactivity (enabling/disabling a provider from the Settings window must
/// start/stop its polling without an app relaunch).
@MainActor
@Observable
final class UsageStore {
    private(set) var claude: ProviderUsageState = .disabled
    private(set) var codex: ProviderUsageState = .disabled

    /// Test seam: the store's clock — mirrors `SessionStore.now`. Production
    /// default (`Date()`) leaves behavior unchanged; tests set this to
    /// advance time deterministically when exercising the `refreshIfStale`
    /// throttle and the 429 `retryAfterUntil` gate.
    var now: () -> Date = { Date() }

    private let settings: AppSettings
    private let claudeProvider: any UsageProviding
    private let codexProvider: any UsageProviding

    /// In-flight fetch per provider. `refresh()`/`refreshIfStale()` both
    /// route through `refresh(_:)` below, which checks this before starting
    /// a new fetch — a second caller awaits the SAME task rather than firing
    /// a redundant request.
    private var tasks: [UsageProviderKind: Task<Void, Never>] = [:]

    /// Recorded on EVERY fetch attempt, success or failure — unlike
    /// `ProviderUsage.fetchedAt`, which only exists after a SUCCESS, this is
    /// what lets `refreshIfStale` throttle retries for a provider that's
    /// currently `.loading` or `.unavailable` (no successful fetch to time
    /// against yet).
    private var lastAttemptAt: [UsageProviderKind: Date] = [:]

    /// Set from a 429's `Retry-After` on failure, cleared on the next
    /// success. `refreshIfStale` treats "now before this" as an additional
    /// gate on top of `lastAttemptAt`/`minAge`, so a rate-limited provider
    /// backs off for the server-specified window even if that's longer than
    /// `minAge`.
    private var retryAfterUntil: [UsageProviderKind: Date] = [:]

    /// Bumped every time `refresh(_:)` starts a NEW task for a provider.
    /// Lets the launching call's cleanup (see `refresh(_:)`) tell whether
    /// `tasks[kind]` still refers to ITS task by the time it resumes, or
    /// whether a disable-then-re-enable raced in and started a newer one —
    /// `Task` isn't `Equatable`, so an identity comparison isn't otherwise
    /// available.
    private var taskGeneration: [UsageProviderKind: Int] = [:]

    private var timer: Timer?

    init(
        settings: AppSettings,
        claudeProvider: any UsageProviding = ClaudeUsageFetcher(),
        codexProvider: any UsageProviding = CodexUsageFetcher()
    ) {
        self.settings = settings
        self.claudeProvider = claudeProvider
        self.codexProvider = codexProvider
        applyEnabledState()
        armSettingsObservation()
    }

    // MARK: - Public API

    /// Refreshes both enabled providers and awaits their completion — tests
    /// can `await store.refresh()` and then assert on `claude`/`codex`
    /// deterministically, rather than polling. Disabled providers are
    /// no-ops.
    func refresh() async {
        async let claudeDone: Void = refresh(.claude)
        async let codexDone: Void = refresh(.codex)
        _ = await (claudeDone, codexDone)
    }

    /// Fire-and-forget refresh, gated per provider on `lastAttemptAt` (so a
    /// provider isn't hammered on every call site that happens to invoke
    /// this — e.g. `OverlayController.show()`) AND `retryAfterUntil` (so a
    /// 429'd provider honors its server-specified backoff even if `minAge`
    /// would otherwise allow a retry sooner). Disabled providers are
    /// skipped entirely — never even recorded in `lastAttemptAt`.
    func refreshIfStale(minAge: TimeInterval = 60) {
        for kind in [UsageProviderKind.claude, .codex] {
            guard isEnabled(kind) else { continue }
            let current = now()
            if let retryUntil = retryAfterUntil[kind], current < retryUntil { continue }
            if let last = lastAttemptAt[kind], current.timeIntervalSince(last) < minAge { continue }
            Task { await self.refresh(kind) }
        }
    }

    // MARK: - Per-provider fetch (dedup + state transitions)

    private func refresh(_ kind: UsageProviderKind) async {
        guard isEnabled(kind) else { return }
        if let existing = tasks[kind] {
            await existing.value
            return
        }
        let generation = (taskGeneration[kind] ?? 0) + 1
        taskGeneration[kind] = generation
        let task = Task { [weak self] in
            // `guard let self` (rather than `self?.performFetch(kind)`)
            // keeps the closure's return type `Void` — `self?.method()`
            // would make it `Void?`, giving `Task<Void?, Never>` instead of
            // the `Task<Void, Never>` the `tasks` dictionary declares.
            guard let self else { return }
            await self.performFetch(kind)
        }
        tasks[kind] = task
        await task.value
        // Only clear the slot if it's still OUR task's generation — a
        // second caller that arrived while this task was in flight already
        // returned via the `existing` branch above and never reaches here,
        // but a disable-then-re-enable that raced in while we were
        // suspended above may have already replaced `tasks[kind]` with a
        // newer task; blindly nil-ing it out here would break dedup for
        // that newer fetch.
        if taskGeneration[kind] == generation { tasks[kind] = nil }
    }

    private func performFetch(_ kind: UsageProviderKind) async {
        lastAttemptAt[kind] = now()
        // Captured BEFORE flipping to `.loading` below — `.loading` itself
        // carries no usage, so grabbing it after would lose the prior
        // snapshot a failure needs to fall back to (`.stale` vs
        // `.unavailable`).
        let priorUsage = currentState(kind).usage
        setState(kind, .loading)
        do {
            let usage = try await provider(for: kind).fetchUsage()
            // A disable that raced in while the fetch was in flight already
            // cancelled this task and set `.disabled` directly — don't let
            // a late-arriving result resurrect `.available` over that.
            guard !Task.isCancelled else { return }
            retryAfterUntil[kind] = nil
            setState(kind, .available(usage))
        } catch let error as UsageFetchError {
            guard !Task.isCancelled else { return }
            handleFailure(kind, error: error, priorUsage: priorUsage)
        } catch {
            guard !Task.isCancelled else { return }
            handleFailure(kind, error: .network(String(describing: error)), priorUsage: priorUsage)
        }
    }

    private func handleFailure(_ kind: UsageProviderKind, error: UsageFetchError, priorUsage: ProviderUsage?) {
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            retryAfterUntil[kind] = now().addingTimeInterval(retryAfter)
        }
        if let priorUsage {
            setState(kind, .stale(priorUsage, error))
        } else {
            setState(kind, .unavailable(error))
        }
    }

    // MARK: - Enabled-state / timer

    /// Recomputes both providers' `.disabled`/`.loading` state from the
    /// current settings, starts/stops each provider's fetch accordingly, and
    /// starts/stops the poll timer. Called once from `init` (so a provider
    /// already enabled at launch starts fetching immediately) and again on
    /// every settings change (see `armSettingsObservation`).
    private func applyEnabledState() {
        updateProviderState(.claude, enabled: settings.claudeUsageEnabled)
        updateProviderState(.codex, enabled: settings.codexUsageEnabled)
        updateTimer()
    }

    private func updateProviderState(_ kind: UsageProviderKind, enabled: Bool) {
        if enabled {
            // Only seed `.loading` on the disabled -> enabled edge; a
            // provider already `.available`/`.stale`/`.unavailable` (e.g.
            // this is just a settings re-arm with no actual toggle change)
            // keeps showing its last state until the kicked-off fetch below
            // resolves.
            if case .disabled = currentState(kind) {
                setState(kind, .loading)
            }
            Task { await self.refresh(kind) }
        } else {
            tasks[kind]?.cancel()
            tasks[kind] = nil
            lastAttemptAt[kind] = nil
            retryAfterUntil[kind] = nil
            setState(kind, .disabled)
        }
    }

    /// 300s poll loop, mirroring SessionStore.swift:65's `Timer` idiom
    /// exactly: `[weak self]` in the timer closure (so the store isn't kept
    /// alive by its own timer) plus an explicit `Task { @MainActor in ... }`
    /// hop, since a `Timer` callback fires off the main actor. Runs only
    /// while at least one provider is enabled, so a fully-disabled
    /// `UsageStore` makes zero network calls, ever.
    private func updateTimer() {
        let shouldRun = settings.claudeUsageEnabled || settings.codexUsageEnabled
        guard shouldRun else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        }
    }

    // MARK: - Settings reactivity

    /// `withObservationTracking`'s `onChange` fires exactly once, at
    /// WILLSET time (old values still visible), so this re-registers itself
    /// on every fire — and the actual re-read + reaction happens after
    /// hopping to a fresh `Task { @MainActor }`, where the NEW values are
    /// visible. Reads ONLY the two toggles in the tracked closure: reading
    /// anything else here would make totally unrelated settings changes
    /// re-trigger provider enable/disable logic for no reason.
    private func armSettingsObservation() {
        withObservationTracking {
            _ = settings.claudeUsageEnabled
            _ = settings.codexUsageEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyEnabledState()
                self?.armSettingsObservation()
            }
        }
    }

    // MARK: - Small per-kind accessors

    private func currentState(_ kind: UsageProviderKind) -> ProviderUsageState {
        switch kind {
        case .claude: return claude
        case .codex: return codex
        }
    }

    private func setState(_ kind: UsageProviderKind, _ state: ProviderUsageState) {
        switch kind {
        case .claude: claude = state
        case .codex: codex = state
        }
    }

    private func provider(for kind: UsageProviderKind) -> any UsageProviding {
        switch kind {
        case .claude: return claudeProvider
        case .codex: return codexProvider
        }
    }

    private func isEnabled(_ kind: UsageProviderKind) -> Bool {
        switch kind {
        case .claude: return settings.claudeUsageEnabled
        case .codex: return settings.codexUsageEnabled
        }
    }
}

#if DEBUG
/// Preview-only stub `UsageProviding`: previews seed `claude`/`codex`
/// directly (see `UsageStore.previewStore` below), so this never actually
/// needs to fetch — it exists only to satisfy `UsageStore.init`'s
/// non-optional provider parameters without touching disk/Keychain/network.
private struct PreviewNoOpUsageProvider: UsageProviding {
    func fetchUsage() async throws -> ProviderUsage {
        throw UsageFetchError.credentialsMissing
    }
}

extension UsageStore {
    /// Preview-only: a store pre-seeded with fixed `claude`/`codex` states,
    /// bypassing the fetch pipeline and settings entirely — mirrors
    /// `SessionStore.previewStore`. Lives in this file so it can reach the
    /// private-set `claude`/`codex` properties. Never compiled into release.
    @MainActor
    static func previewStore(
        claude: ProviderUsageState = .disabled,
        codex: ProviderUsageState = .disabled
    ) -> UsageStore {
        let store = UsageStore(
            settings: AppSettings(),
            claudeProvider: PreviewNoOpUsageProvider(),
            codexProvider: PreviewNoOpUsageProvider()
        )
        store.claude = claude
        store.codex = codex
        return store
    }
}
#endif
