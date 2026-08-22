import Foundation
import UsageCore
import WidgetKit

enum UsageTimeline {
    static let interval: TimeInterval = 20 * 60
    static let appURL = URL(string: "lilusage://")!

    static func loadAndMaybeRefresh() async -> UsageSnapshot {
        let store = AppGroup.snapshotStore
        let settings = EnabledSettings.settings
        let snapshot = store.load()
        let now = Date()
        guard shouldRefresh(snapshot: snapshot, settings: settings, now: now) else {
            return snapshot
        }
        let refresher = UsageRefresher(snapshotStore: store, tokens: KeychainTokenStore())
        return await refresher.refreshAll(settings: settings)
    }

    static func shouldRefresh(snapshot: UsageSnapshot, settings: UsageSettings, now: Date) -> Bool {
        let tokens = KeychainTokenStore()
        for kind in ProviderKind.allCases {
            guard isEnabled(kind, settings: settings) else { continue }
            let raw = try? tokens.load(kind: kind)
            guard let raw, !raw.isEmpty else { continue }
            let slot = snapshot[kind]
            if let retry = slot.retryAfterUntil, now < retry { continue }
            guard let last = slot.lastAttemptAt else { return true }
            if now.timeIntervalSince(last) >= interval { return true }
        }
        return false
    }

    /// Next wake: earliest per-enabled-provider eligibility, so a 429 on Grok
    /// does not delay Claude, and a late `getTimeline` does not add another
    /// 20 minutes on top of `lastAttemptAt`.
    static func nextUpdate(snapshot: UsageSnapshot, now: Date = Date()) -> Date {
        var candidates: [Date] = []
        for kind in ProviderKind.allCases {
            let slot = snapshot[kind]
            guard slot.enabled else { continue }
            if let retry = slot.retryAfterUntil, retry > now {
                candidates.append(retry)
            } else if let last = slot.lastAttemptAt {
                candidates.append(last.addingTimeInterval(interval))
            } else {
                candidates.append(now.addingTimeInterval(interval))
            }
        }
        let soonest = candidates.min() ?? now.addingTimeInterval(interval)
        return max(soonest, now.addingTimeInterval(60))
    }

    static func isEnabled(_ kind: ProviderKind, settings: UsageSettings) -> Bool {
        switch kind {
        case .claude: settings.claudeEnabled
        case .grok: settings.grokEnabled
        case .codex: settings.codexEnabled
        }
    }
}

struct ProviderEntry: TimelineEntry, Sendable {
    let date: Date
    let kind: ProviderKind
    let snapshot: ProviderSnapshot
}

struct StackEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: UsageSnapshot
    let settings: UsageSettings
}

struct ProviderTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ProviderEntry {
        ProviderEntry(date: Date(), kind: .claude, snapshot: .preview)
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> ProviderEntry {
        await makeEntry(kind: configuration.provider.kind)
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<ProviderEntry> {
        let entry = await makeEntry(kind: configuration.provider.kind)
        let full = AppGroup.snapshotStore.load()
        let next = UsageTimeline.nextUpdate(snapshot: full, now: entry.date)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(kind: ProviderKind) async -> ProviderEntry {
        let snapshot = await UsageTimeline.loadAndMaybeRefresh()
        return ProviderEntry(date: Date(), kind: kind, snapshot: snapshot[kind])
    }
}

struct StackTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StackEntry {
        StackEntry(
            date: Date(),
            snapshot: UsageSnapshot(claude: .preview, grok: .preview, codex: .preview),
            settings: UsageSettings(claudeEnabled: true, grokEnabled: true, codexEnabled: true)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (StackEntry) -> Void) {
        Task {
            completion(await makeEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<StackEntry>) -> Void) {
        Task {
            let entry = await makeEntry()
            let next = UsageTimeline.nextUpdate(snapshot: entry.snapshot, now: entry.date)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func makeEntry() async -> StackEntry {
        let snapshot = await UsageTimeline.loadAndMaybeRefresh()
        return StackEntry(date: Date(), snapshot: snapshot, settings: EnabledSettings.settings)
    }
}

extension ProviderSnapshot {
    static var preview: ProviderSnapshot {
        ProviderSnapshot(
            enabled: true,
            usage: ProviderUsage(
                session: UsageWindow(percent: 62, resetsAt: Date().addingTimeInterval(3 * 3600)),
                weekly: UsageWindow(percent: 41, resetsAt: Date().addingTimeInterval(4 * 86400)),
                fetchedAt: Date()
            )
        )
    }
}
