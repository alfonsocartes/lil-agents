import AppKit
import Observation
import SwiftUI

/// Owns the floating overlay panel and publishes its visibility.
///
/// Visibility used to be read back from `panel.isVisible` through a closure at
/// `menuNeedsUpdate` time — pull-based, which only works because `NSMenu`
/// rebuilds itself on every open. `@Observable isVisible` is push-based, so a
/// SwiftUI menu can observe it directly.
///
/// The panel is built lazily on first `show()` and exactly once: ordering a
/// window front while the app delegate is still being constructed is flaky.
///
/// `show()` re-derives the panel's placement (via `FloatingPanel.present()`,
/// see `OverlayPlacement`) instead of trusting whatever frame was last
/// autosaved: the panel can go stale while hidden — its frame drifts as the
/// session list grows/shrinks off-screen, and its saved position may sit on
/// a display the user has since disconnected or moved away from. Without
/// re-deriving, the hotkey and the menu-bar toggle both order the panel
/// front exactly where it was, which can be nowhere visible.
@MainActor
@Observable
final class OverlayController {
    /// Whether the overlay panel is currently on screen.
    private(set) var isVisible: Bool = false

    private let store: SessionStore
    private let usage: UsageStore
    private var panel: FloatingPanel<OverlayView>?

    /// Token for the screen-parameters observer, torn down in `deinit`.
    private var screenParametersObserver: (any NSObjectProtocol)?

    init(store: SessionStore, usage: UsageStore) {
        self.store = store
        self.usage = usage

        // Display arrangement changes (a monitor unplugged, resolution
        // changed, Space/Spaces reconfigured) can strand a HIDDEN panel on a
        // screen that no longer exists — the exact case `show()` alone can't
        // catch, since it doesn't run until the user next toggles. Reclamp
        // proactively instead of waiting for that.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.reclampToScreens()
            }
        }
    }

    // `isolated deinit`, matching HotKeyCenter's rationale: the property
    // being torn down here is @MainActor state, so nonisolated deinit
    // (the default for an @MainActor class) can't reach it.
    isolated deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Kick off a refresh every time the overlay is raised, throttled by
        // `refreshIfStale`'s own `lastAttemptAt`/`retryAfterUntil` gates so
        // repeated toggling never spams either provider's API.
        usage.refreshIfStale()
        panel.present()
        syncVisibility()
        // One line of evidence if this ever recurs: whether the panel
        // actually ended up visible/on the active Space, and where.
        NSLog("AgentDeck overlay show: visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) frame=\(NSStringFromRect(panel.frame)) screens=\(NSScreen.screens.count)")
    }

    func hide() {
        panel?.orderOut(nil)
        syncVisibility()
    }

    func toggle() {
        // Branch on the panel's REAL state, not the cached flag, so a panel
        // that's visible-but-not-where-the-user-is (the bug this file
        // exists to fix) can never invert the menu's "Show/Hide" click into
        // a hide.
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    /// Reads `isVisible` back from the panel rather than assuming — the
    /// panel is the source of truth, not whichever call just ran.
    private func syncVisibility() {
        isVisible = panel?.isVisible ?? false
    }

    private func makePanel() -> FloatingPanel<OverlayView> {
        // FloatingPanel's init calls setFrameAutosaveName("AgentDeckPanel"),
        // which is what persists the user's dragged position across launches.
        FloatingPanel(content: OverlayView(store: store, usage: usage))
    }
}
