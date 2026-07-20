import SwiftUI

/// SwiftUI entry point. All real setup still happens in `AppDelegate` — this
/// type exists to own the app lifecycle so later phases can add SwiftUI scenes
/// (a `MenuBarExtra`, a `Settings` window) without a manual `NSApplication`
/// bootstrap.
///
/// The `Settings` scene is a placeholder: a `Settings` scene creates no window
/// until it is explicitly opened, so this adds no user-visible surface today.
/// (The existing AppKit `SettingsWindowController` still owns the real Settings
/// window; a later phase replaces it.)
@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
