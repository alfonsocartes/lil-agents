import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller. Owns the single
/// `SPUStandardUpdaterController` instance for the app's lifetime; AppDelegate
/// retains this and hands the underlying controller to MenuBarController so
/// the "Check for Updates…" menu item can target it directly (Sparkle enables/
/// disables that item automatically based on update-check state).
@MainActor
final class UpdaterController {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
