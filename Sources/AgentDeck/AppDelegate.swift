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
    private var lifecycle: SessionLifecycleCoordinator?
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

        // Reconcile hooks with their owning process before starting the
        // listener. The resolver is shared so EventListener can fingerprint a
        // PID before replying, while the observer can re-check that same
        // fingerprint after its dispatch source is activated.
        let processResolver = DarwinProcessIdentityResolver()
        let processObserver = DispatchProcessExitObserver(resolver: processResolver)
        let lifecycle = SessionLifecycleCoordinator(
            store: store,
            processObserver: processObserver
        )
        self.lifecycle = lifecycle

        // Background-agent visibility is a user setting (Settings → Sessions).
        // Read through a closure so the coordinator stays independent of the
        // settings layer, and retire the rows immediately when it is switched
        // off rather than leaving them until each one ends.
        let settings = services.settings
        lifecycle.showsBackgroundSessions = { [weak settings] in
            settings?.showBackgroundSessions ?? false
        }
        settings.onShowBackgroundSessionsChange = { [weak lifecycle] isShown in
            guard !isShown else { return }
            lifecycle?.dropBackgroundSessions()
        }

        // Start the event listener.
        let listener = EventListener(
            lifecycle: lifecycle,
            processResolver: processResolver,
            token: token
        )
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

        // Offer to enable launch-at-login once, the first time the app has
        // ever run. Silent on the AGENTDECK_NO_INSTALL smoke-test path (see
        // the hook-install block above) for the same reason: a modal alert
        // would hang a headless/scripted run waiting on user input.
        promptForLoginItemIfNeeded()

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

    /// Shows the one-shot "start at login?" alert on the very first launch,
    /// if launch-at-login is available and not already enabled. No-op on
    /// every later launch — `consumeFirstLaunchPrompt()` returns true at
    /// most once, ever.
    private func promptForLoginItemIfNeeded() {
        // Never prompt on the smoke-test path — a modal here would hang a
        // headless/scripted run waiting on input that will never come.
        guard ProcessInfo.processInfo.environment["AGENTDECK_NO_INSTALL"] == nil else { return }
        guard services.loginItem.consumeFirstLaunchPrompt() else { return }

        // The app is `.accessory`, so without activating first the alert can
        // open behind other apps.
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = "Start lil agents at login?"
        alert.informativeText = "lil agents watches your sessions in the background — it's only useful when it's already running. It stays in the menu bar; no window opens."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            services.loginItem.isEnabled = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reverts the kernel SleepDisabled flag. Must always run.
        services.awake.appWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
