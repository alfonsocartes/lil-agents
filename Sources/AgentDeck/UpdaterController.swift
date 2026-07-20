import AppKit
import Combine
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller. Owns the single
/// `SPUStandardUpdaterController` instance for the app's lifetime; AppDelegate
/// retains this and hands it to the SwiftUI menu content so "Check for
/// Updates…" can target it directly.
///
/// `MenuBarExtra` loses `NSMenuItem`'s automatic target/action validation, so
/// there's no built-in graying-out of "Check for Updates…" while a check is
/// already in flight or unavailable. `canCheckForUpdates` mirrors Sparkle's
/// own `SPUUpdater.canCheckForUpdates` KVO property via the documented
/// Combine bridge so a SwiftUI row can `.disabled(!updater.canCheckForUpdates)`.
///
/// Deliberately NOT migrated to `@Observable`: `canCheckForUpdates` is fed by
/// Sparkle's KVO publisher via `assign(to: &$canCheckForUpdates)`, which is a
/// Combine `@Published` projection with no `@Observable` equivalent. Rebuilding
/// that bridge (e.g. hand-rolled KVO observation) would buy nothing here, so
/// this one class stays on `ObservableObject`.
@MainActor
final class UpdaterController: ObservableObject {
    let controller: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
