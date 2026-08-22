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
        snapshot = await refresher.refreshNow(settings: EnabledSettings.settings)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func refreshAll() async {
        snapshot = await refresher.refreshAll(settings: EnabledSettings.settings)
        WidgetCenter.shared.reloadAllTimelines()
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
