import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Composition root. A STORED property on purpose: a later `MenuBarExtra`
    /// renders its label before `applicationDidFinishLaunching` runs, so these
    /// objects must already exist by delegate-construction time.
    let services = AppServices()

    // Not exposed via AppServices — no view needs them.
    private let hotKeys = HotKeyCenter()
    private var listener: EventListener?
    private var notifier: Notifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-less, Dock-less agent app: the only surfaces are the status
        // item and the floating overlay. `LSUIElement` covers the bundled app,
        // but the unbundled `swift run` dev loop has no Info.plist and would
        // otherwise take a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        let store = services.store

        // Ensure our support dir exists.
        try? FileManager.default.createDirectory(at: AgentDeck.supportDir, withIntermediateDirectories: true)

        // Ensure the per-install bearer token exists BEFORE the listener binds,
        // regardless of the AGENTDECK_NO_INSTALL path below — the listener
        // requires it on every request.
        let token = AgentDeck.loadOrCreateToken()

        // Wire the notifier into the store BEFORE the listener starts, so no
        // early hook event can slip through and reach `apply(_:)` with
        // `store.notifier` still nil. Notifier's init also installs the
        // UNUserNotificationCenter delegate, so a notification tap is caught
        // from this point on.
        let notifier = Notifier(settings: services.settings, sessionLookup: { [weak store] id in
            store?.sessions.first { $0.id == id }
        })
        self.notifier = notifier
        store.notifier = notifier

        // Start the event listener.
        let listener = EventListener(store: store, token: token)
        listener.start()
        self.listener = listener

        // Reflect current sleep state.
        services.awake.refresh()

        // Install/refresh CLI hooks every launch. install() is idempotent and
        // self-healing (upsertGroups repairs any stale/broken prior entries), so
        // running it unconditionally keeps config correct across app updates.
        // Set AGENTDECK_NO_INSTALL=1 to skip touching ~/.claude and ~/.codex
        // (used for smoke-testing the listener/UI without altering real config).
        if ProcessInfo.processInfo.environment["AGENTDECK_NO_INSTALL"] == nil {
            // Off the main thread — install() does file reads, JSON parsing and
            // atomic writes we don't want blocking launch.
            Task.detached(priority: .utility) {
                do { try HookInstaller.install(port: AgentDeck.port) }
                catch { NSLog("AgentDeck hook install failed: \(error)") }
            }
        }

        // Show the floating overlay (pure session list). Hide/show is driven by
        // the global hotkey and the menu bar; the overlay itself has no chrome.
        // OverlayController builds the panel lazily, here on first show.
        services.overlay.show()

        // The menu bar presence is the SwiftUI `MenuBarExtra` scene in
        // `AgentDeckApp` (status icon + session dropdown); the legacy
        // NSStatusItem/NSMenu implementation has been removed. Settings is now
        // the SwiftUI `Settings` scene, opened via the `openSettings` action
        // with `services.activationPolicy` handling frontmost-ness.

        // Ask for notification permission once at launch. NSLog reports the
        // outcome; harmless to call on every launch — the system only
        // actually prompts the user the first time.
        notifier.requestAuthorization()

        // Global toggle hotkey: ⌥⌘J (Option-Command-J). Deliberately avoids the
        // ⌃⌥⌘ "hyper" combos that Vivid claims, and J is rarely bound in iTerm2.
        // Carbon hotkeys need no Accessibility permission and fire from any app.
        let registered = hotKeys.register(
            keyCode: UInt32(kVK_ANSI_J),
            modifiers: UInt32(optionKey | cmdKey)
        ) { [weak self] in
            self?.services.overlay.toggle()
        }
        NSLog("AgentDeck hotkey ⌥⌘J registered: \(registered)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reverts the kernel SleepDisabled flag. Must always run.
        services.awake.appWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
