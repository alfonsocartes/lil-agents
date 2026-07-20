import AppKit
import Combine
import Sparkle

/// The menu bar presence for lil agents: a status item whose icon color reflects
/// whether any session is waiting for the user, plus a menu listing the sessions
/// and controls for the floating overlay.
///
/// Icon states:
///   • none      — nothing needs you: a monochrome (template) outline that adapts
///                 to the menu bar appearance.
///   • waiting   — a session finished its turn and awaits your prompt: blue dot.
///   • approval  — a session is blocked on a permission prompt: orange alert.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: SessionStore
    private let awake: StayAwakeController
    private let updaterController: SPUStandardUpdaterController
    private let onToggleOverlay: () -> Void
    private let isOverlayVisible: () -> Bool
    private let onOpenSettings: () -> Void

    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore,
         awake: StayAwakeController,
         updaterController: SPUStandardUpdaterController,
         onToggleOverlay: @escaping () -> Void,
         isOverlayVisible: @escaping () -> Bool,
         onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.awake = awake
        self.updaterController = updaterController
        self.onToggleOverlay = onToggleOverlay
        self.isOverlayVisible = isOverlayVisible
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        updateIcon()
        // Re-render the icon when sessions change OR when stay-awake toggles.
        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        awake.$isAwake
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        button.image = AttentionIcon.image(attention: store.attention, isAwake: awake.isAwake)
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        let n = store.sessions.count
        if n == 0 { return "lil agents — no active sessions" }
        switch store.attention {
        case .needsInput: return "lil agents — a session needs your input"
        case .idle:       return "lil agents — a session is idle"
        case .working:    return "lil agents — \(n) working"
        case .none:       return "lil agents — no active sessions"
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Hide/Show overlay up top for discoverability. Show the ⌥⌘J shortcut as
        // plain text rather than a real key equivalent — the global Carbon hotkey
        // already handles ⌥⌘J, and a functional key equivalent here would fire a
        // SECOND toggle whenever this menu is open.
        let toggleTop = NSMenuItem(
            title: (isOverlayVisible() ? "Hide overlay" : "Show overlay") + "   ⌥⌘J",
            action: #selector(toggleOverlay),
            keyEquivalent: ""
        )
        toggleTop.target = self
        menu.addItem(toggleTop)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        if store.sessions.isEmpty {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for session in store.sessions {
                let item = NSMenuItem(
                    title: "\(dot(for: session.status))  \(session.label)",
                    action: #selector(jump(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session   // struct is boxed into Any?
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let stayAwake = NSMenuItem(
            title: "Stay awake (lid closed)",
            action: #selector(toggleAwake),
            keyEquivalent: ""
        )
        stayAwake.target = self
        stayAwake.state = awake.isAwake ? .on : .off
        menu.addItem(stayAwake)

        menu.addItem(.separator())

        // Sparkle enables/disables this item automatically based on update-check
        // state, so no explicit `isEnabled` handling is needed here.
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        menu.addItem(checkForUpdates)

        menu.addItem(.separator())

        let uninstall = NSMenuItem(
            title: "Uninstall lil agents…",
            action: #selector(uninstall(_:)),
            keyEquivalent: ""
        )
        uninstall.target = self
        menu.addItem(uninstall)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit lil agents", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func jump(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        TerminalJumpers.jump(session.jumpTarget)
    }

    @objc private func toggleOverlay() { onToggleOverlay() }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func toggleAwake() { awake.toggle() }

    @objc private func uninstall(_ sender: NSMenuItem) { Uninstaller.promptAndUninstall() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Helpers

    private func dot(for status: SessionStatus) -> String {
        switch status {
        case .working:         return "🟢"
        case .idle:            return "🟡"
        case .waitingApproval: return "🔴"
        }
    }
}
