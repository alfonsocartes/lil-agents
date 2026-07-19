import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let awake = StayAwakeController()
    private let hotKeys = HotKeyCenter()
    private var listener: EventListener?
    private var panel: NSPanel?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure our support dir exists.
        try? FileManager.default.createDirectory(at: AgentDeck.supportDir, withIntermediateDirectories: true)

        // Start the event listener.
        let listener = EventListener(store: store)
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

        // Menu bar presence: color-changing icon + session menu. Kept alongside
        // the floating overlay (the user wants both surfaces).
        menuBar = MenuBarController(
            store: store,
            awake: awake,
            onToggleOverlay: { [weak self] in self?.toggleOverlay() },
            isOverlayVisible: { [weak self] in self?.panel?.isVisible ?? false }
        )

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
