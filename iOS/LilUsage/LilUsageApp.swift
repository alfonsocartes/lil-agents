import SwiftUI

@main
struct LilUsageApp: App {
    @State private var refresh: RefreshController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _refresh = State(initialValue: RefreshController())
        RefreshController.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(refresh)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refresh.refreshAll() }
                RefreshController.scheduleBackgroundRefresh()
            }
        }
    }
}
