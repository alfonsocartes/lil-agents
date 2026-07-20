import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let awake = StayAwakeController()
    private let hotKeys = HotKeyCenter()
    private let settings = AppSettings()
    private var listener: EventListener?
    private var panel: NSPanel?
    private var menuBar: MenuBarController?
    private var updater: UpdaterController?
    private var notifier: Notifier?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure our support dir exists.
        try? FileManager.default.createDirectory(at: AgentDeck.supportDir, withIntermediateDirectories: true)

        // Ensure the per-install bearer token exists BEFORE the listener binds,
        // regardless of the AGENTDECK_NO_INSTALL path below — the listener
        // requires it on every request.
        let token = AgentDeck.loadOrCreateToken()

        // Wire the notifier into the store BEFORE the listener starts, so no
        // early hook event can slip through and reach `apply(_:)` with
        // `store.notifier` still nil.
        let notifier = Notifier(settings: settings, sessionLookup: { [weak store] id in
            store?.sessions.first { $0.id == id }
        })
        self.notifier = notifier
        store.notifier = notifier

        // Start the event listener.
        let listener = EventListener(store: store, token: token)
        listener.start()
        self.listener = listener

        // Reflect current sleep state.
        awake.refresh()

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

        // Build the floating overlay (pure session list). Hide/show is driven by
        // the global hotkey and the menu bar; the overlay itself has no chrome.
        let content = OverlayView(store: store)
        let panel = FloatingPanel(content: content)
        panel.orderFrontRegardless()
        self.panel = panel

        // Sparkle auto-updater. Retained for the app's lifetime; its controller
        // is handed to MenuBarController for the "Check for Updates…" item.
        let updater = UpdaterController()
        self.updater = updater

        // Settings window (notification preferences). Retained for the app's
        // lifetime; lazily creates its NSWindow on first show().
        let settingsWindow = SettingsWindowController(settings: settings)
        self.settingsWindow = settingsWindow

        // Menu bar presence: color-changing icon + session menu. Kept alongside
        // the floating overlay (the user wants both surfaces).
        menuBar = MenuBarController(
            store: store,
            awake: awake,
            updaterController: updater.controller,
            onToggleOverlay: { [weak self] in self?.toggleOverlay() },
            isOverlayVisible: { [weak self] in self?.panel?.isVisible ?? false },
            onOpenSettings: { [weak self] in self?.settingsWindow?.show() }
        )

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
            self?.toggleOverlay()
        }
        NSLog("AgentDeck hotkey ⌥⌘J registered: \(registered)")
    }

    private func toggleOverlay() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        awake.appWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
