import Foundation

public struct UsageSettings: Equatable, Sendable {
    public var claudeEnabled: Bool
    public var grokEnabled: Bool
    public var codexEnabled: Bool

    public init(claudeEnabled: Bool = false, grokEnabled: Bool = false, codexEnabled: Bool = false) {
        self.claudeEnabled = claudeEnabled
        self.grokEnabled = grokEnabled
        self.codexEnabled = codexEnabled
    }
}

/// iOS counterpart to AgentDeck's `UsageStore` without Observation/timer.
/// Fetches enabled providers concurrently, persists a token-free snapshot.
public actor UsageRefresher {
    public static let defaultMinAge: TimeInterval = 20 * 60

    private let snapshotStore: SnapshotStore
    private let tokens: any TokenStoring
    private let claudeProvider: (any UsageProviding)?
    private let grokProvider: (any UsageProviding)?
    private let codexProvider: (any UsageProviding)?
    private let now: @Sendable () -> Date
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Test-friendly: inject `any UsageProviding` per kind. Production leaves
    /// providers nil and builds real fetchers from `TokenStoring` + `TokenParsing`.
    public init(
        snapshotStore: SnapshotStore,
        tokens: any TokenStoring,
        claudeProvider: (any UsageProviding)? = nil,
        grokProvider: (any UsageProviding)? = nil,
        codexProvider: (any UsageProviding)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) {
        self.snapshotStore = snapshotStore
        self.tokens = tokens
        self.claudeProvider = claudeProvider
        self.grokProvider = grokProvider
        self.codexProvider = codexProvider
        self.now = now
        self.transport = transport
    }

    /// User-initiated refresh (host appear, pull-to-refresh, token paste).
    /// Bypasses `minAge` / lastAttemptAt so a newly pasted token is fetched
    /// immediately; still honors an unexpired 429 `retryAfterUntil`.
    public func refreshNow(settings: UsageSettings) async -> UsageSnapshot {
        await refreshAll(settings: settings, minAge: 0)
    }

    public func refreshAll(settings: UsageSettings, minAge: TimeInterval = UsageRefresher.defaultMinAge) async -> UsageSnapshot {
        let snapshot = snapshotStore.load()
        let current = now()
        async let claude = refreshSlot(
            kind: .claude, enabled: settings.claudeEnabled, prior: snapshot.claude,
            minAge: minAge, current: current
        )
        async let grok = refreshSlot(
            kind: .grok, enabled: settings.grokEnabled, prior: snapshot.grok,
            minAge: minAge, current: current
        )
        async let codex = refreshSlot(
            kind: .codex, enabled: settings.codexEnabled, prior: snapshot.codex,
            minAge: minAge, current: current
        )
        let result = UsageSnapshot(claude: await claude, grok: await grok, codex: await codex)
        try? snapshotStore.save(result)
        return result
    }

    private func refreshSlot(
        kind: ProviderKind,
        enabled: Bool,
        prior: ProviderSnapshot,
        minAge: TimeInterval,
        current: Date
    ) async -> ProviderSnapshot {
        if !enabled {
            var slot = prior
            slot.enabled = false
            // Keep last-known usage, but drop throttle gates so a re-enable
            // fetches immediately (Mac UsageStore clears lastAttemptAt /
            // retryAfterUntil on disable).
            slot.lastAttemptAt = nil
            slot.retryAfterUntil = nil
            return slot
        }

        let raw: String?
        do {
            raw = try tokens.load(kind: kind)
        } catch {
            return credentialsMissing(prior: prior)
        }
        guard let raw else {
            return credentialsMissing(prior: prior)
        }
        do {
            switch kind {
            case .claude: _ = try TokenParsing.claude(raw)
            case .codex: _ = try TokenParsing.codex(raw)
            case .grok: _ = try TokenParsing.grok(raw, now: current)
            }
        } catch {
            return credentialsMissing(prior: prior)
        }

        if let retryUntil = prior.retryAfterUntil, current < retryUntil {
            var slot = prior
            slot.enabled = true
            return slot
        }
        if let last = prior.lastAttemptAt, current.timeIntervalSince(last) < minAge {
            var slot = prior
            slot.enabled = true
            return slot
        }

        let provider: any UsageProviding
        if let injected = injectedProvider(for: kind) {
            provider = injected
        } else {
            do {
                provider = try makeFetcher(kind: kind, raw: raw, current: current)
            } catch {
                return credentialsMissing(prior: prior)
            }
        }

        do {
            let usage = try await provider.fetchUsage()
            return ProviderSnapshot(
                enabled: true,
                usage: usage,
                lastError: nil,
                lastAttemptAt: current,
                retryAfterUntil: nil
            )
        } catch let error as UsageFetchError {
            return failed(prior: prior, error: error, current: current)
        } catch {
            return failed(prior: prior, error: .network(String(describing: error)), current: current)
        }
    }

    private func credentialsMissing(prior: ProviderSnapshot) -> ProviderSnapshot {
        var slot = prior
        slot.enabled = true
        slot.lastError = .credentialsMissing
        return slot
    }

    private func failed(prior: ProviderSnapshot, error: UsageFetchError, current: Date) -> ProviderSnapshot {
        var slot = prior
        slot.enabled = true
        slot.lastError = error
        slot.lastAttemptAt = current
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            slot.retryAfterUntil = current.addingTimeInterval(retryAfter)
        }
        return slot
    }

    private func injectedProvider(for kind: ProviderKind) -> (any UsageProviding)? {
        switch kind {
        case .claude: return claudeProvider
        case .grok: return grokProvider
        case .codex: return codexProvider
        }
    }

    private func makeFetcher(kind: ProviderKind, raw: String, current: Date) throws -> any UsageProviding {
        let clock = now
        let transport = self.transport
        switch kind {
        case .claude:
            let credentials = try TokenParsing.claude(raw)
            return ClaudeUsageFetcher(credentials: { credentials }, transport: transport, now: clock)
        case .codex:
            let credentials = try TokenParsing.codex(raw)
            return CodexUsageFetcher(credentials: { credentials }, transport: transport, now: clock)
        case .grok:
            let token = try TokenParsing.grok(raw, now: current)
            return GrokUsageFetcher(accessToken: { token }, transport: transport, now: clock)
        }
    }
}
