import Foundation

/// Composition root for the long-lived objects the UI needs.
///
/// Held as a *stored property* on `AppDelegate` (`let services = AppServices()`),
/// not built inside `applicationDidFinishLaunching`: a future `MenuBarExtra`
/// renders its label before `applicationDidFinishLaunching` runs, so anything
/// constructed there would still be nil when the menu first draws.
///
/// These instances must never be re-created by a SwiftUI `@State`/`@StateObject`
/// in the `App` struct — that would produce a second `SessionStore`, separate
/// from the one `EventListener` writes into, and the menu would silently render
/// empty. Views receive the instances owned here.
///
/// `EventListener`, `Notifier` and `HotKeyCenter` deliberately stay private to
/// `AppDelegate`: no view needs them.
@MainActor
final class AppServices {
    /// Live session state; the single instance `EventListener` writes into.
    let store = SessionStore()

    /// Notification preferences, persisted to `UserDefaults`.
    let settings = AppSettings()

    /// Stay-awake (lid-closed) control backing the menu item.
    let awake = StayAwakeController()

    /// The floating overlay panel plus its push-based visibility state.
    let overlay: OverlayController

    /// Sparkle auto-updater, retained for the app's lifetime.
    let updater = UpdaterController()

    /// Flips the app between `.accessory` and `.regular` around the SwiftUI
    /// `Settings` scene so the settings window comes frontmost with a menu bar
    /// in this Dock-less app. Installs its `NSWindow.willCloseNotification`
    /// observer at construction, so it must be alive for the app's lifetime.
    let activationPolicy = ActivationPolicyController()

    init() {
        overlay = OverlayController(store: store)
    }
}
