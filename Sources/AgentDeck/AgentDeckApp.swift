import SwiftUI

/// SwiftUI entry point. Core setup (listener, hotkey, hooks, overlay) still
/// happens in `AppDelegate`; the menu-bar presence is now the SwiftUI
/// `MenuBarExtra` scene below — the first surface of the AppKit→SwiftUI
/// migration.
///
/// The objects handed to the scene come from `appDelegate.services`, a stored
/// property that exists before `applicationDidFinishLaunching`: a `MenuBarExtra`
/// renders its label as soon as the scene is built, so the store/overlay/awake
/// it observes must already exist. Re-creating them here as `@StateObject`
/// would fork a second `SessionStore` from the one the listener writes into and
/// the menu would render empty.
@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                store: appDelegate.services.store,
                awake: appDelegate.services.awake,
                overlay: appDelegate.services.overlay,
                updater: appDelegate.services.updater,
                onOpenSettings: { appDelegate.services.settingsWindow.show() }
            )
        } label: {
            StatusIconLabel(
                store: appDelegate.services.store,
                awake: appDelegate.services.awake
            )
        }
        .menuBarExtraStyle(.window)
    }
}
