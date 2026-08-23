import BackgroundTasks
import Observation
import UsageCore
import WidgetKit

@MainActor
@Observable
final class RefreshController {
    nonisolated static let refreshTaskIdentifier = "com.wandity.lilagents.refresh"

    private let refresher: UsageRefresher
    var snapshot: UsageSnapshot

    init() {
        let store = AppGroup.snapshotStore
        self.refresher = UsageRefresher(snapshotStore: store, tokens: KeychainTokenStore())
        self.snapshot = store.load()
    }

    func refreshNow() async {
        snapshot = await runRefresh { await refresher.refreshNow(settings: $0) }
    }

    func refreshAll() async {
        snapshot = await runRefresh { await refresher.refreshAll(settings: $0) }
    }

    /// Persist the toggle first so widgets hide a provider immediately,
    /// then fetch. Handoff only auto-enables providers the user has never
    /// toggled — an explicit off is not flipped back on by a leftover token.
    private func runRefresh(_ fetch: (UsageSettings) async -> UsageSnapshot) async -> UsageSnapshot {
        importHandoffTokens()
        let settings = EnabledSettings.settings
        snapshot = await refresher.applyEnabledFlags(settings)
        WidgetCenter.shared.reloadAllTimelines()
        let result = await fetch(settings)
        WidgetCenter.shared.reloadAllTimelines()
        return result
    }

    /// If lil agents copied tokens into iCloud Keychain, turn those
    /// providers on so widgets show them without a second tap.
    private func importHandoffTokens() {
        let store = KeychainTokenStore()
        for kind in ProviderKind.allCases {
            guard HandoffEnablement.shouldAutoEnable(
                explicitSetting: EnabledSettings.explicitEnabled(kind)
            ) else { continue }
            if let raw = try? store.load(kind: kind), !raw.isEmpty {
                EnabledSettings.set(true, kind: kind)
            }
        }
    }

    nonisolated static func registerBackgroundTask() {
        _ = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskIdentifier,
            using: nil
        ) { task in
            handleBackground(task)
        }
    }

    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated private static func handleBackground(_ task: BGTask) {
        scheduleBackgroundRefresh()
        let box = BGTaskBox(task)
        let work = Task {
            let refresher = UsageRefresher(
                snapshotStore: AppGroup.snapshotStore,
                tokens: KeychainTokenStore()
            )
            _ = await refresher.refreshAll(settings: EnabledSettings.settings)
            WidgetCenter.shared.reloadAllTimelines()
            box.complete(true)
        }
        task.expirationHandler = {
            work.cancel()
            box.complete(false)
        }
    }
}

/// BGTask isn't Sendable; the scheduler hands it to a background queue.
private final class BGTaskBox: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var finished = false

    init(_ task: BGTask) { self.task = task }

    func complete(_ success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        task.setTaskCompleted(success: success)
    }
}
