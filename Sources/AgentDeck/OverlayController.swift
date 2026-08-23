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
/// The panel is built lazily on first `show()`: ordering a window front
/// while the app delegate is still being constructed is flaky.
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

    /// User intent, independent of AppKit's `isVisible`. WindowServer can
    /// order the panel out on a Mission Control space switch without the
    /// user having hidden it.
    private var wantsVisible = false

    /// Token for the screen-parameters observer, torn down in `deinit`.
    private var screenParametersObserver: (any NSObjectProtocol)?

    /// Token for the active-Space observer, torn down in `deinit`.
    private var activeSpaceObserver: (any NSObjectProtocol)?

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

        // Must be NSWorkspace's center, not NotificationCenter.default —
        // that's where activeSpaceDidChange is posted.
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsVisible else { return }
                // Rejoin in place — present() would re-home onto NSScreen.main.
                self.panel?.rejoinSpaces()
                self.syncVisibility()
                if let panel = self.panel {
                    NSLog("AgentDeck overlay space change: visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) frame=\(NSStringFromRect(panel.frame))")
                }
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
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
    }

    func show() {
        wantsVisible = true
        var panel = panel ?? makePanel()
        self.panel = panel
        // Kick off a refresh every time the overlay is raised, throttled by
        // `refreshIfStale`'s own `lastAttemptAt`/`retryAfterUntil` gates so
        // repeated toggling never spams either provider's API.
        usage.refreshIfStale()
        panel.present()
        // Recreate only when present() left a panel that isn't actually on
        // screen. `isOnActiveSpace` is a stale WindowServer query for an
        // offscreen panel and must not drive this — space membership is
        // present()'s internal retry.
        if !panel.isVisible || !OverlayPlacement.isDisplayable(panel.frame) {
            // Defense-in-depth for a WindowServer-zombie panel. present() +
            // resolvedFrame already handle the 0-size autosave case, so the
            // replacement won't come back 0-height.
            NSLog("AgentDeck overlay show: recreating visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) frame=\(NSStringFromRect(panel.frame)) screens=\(NSScreen.screens.count)")
            panel.orderOut(nil)
            panel = makePanel()
            self.panel = panel
            panel.present()
        }
        syncVisibility()
        // One line of evidence if this ever recurs: whether the panel
        // actually ended up visible/on the active Space, and where.
        NSLog("AgentDeck overlay show: visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) frame=\(NSStringFromRect(panel.frame)) screens=\(NSScreen.screens.count)")
    }

    func hide() {
        wantsVisible = false
        panel?.orderOut(nil)
        syncVisibility()
    }

    func toggle() {
        // Hide only when the user wants it showing AND it's actually in
        // front of them. A stranded desktop copy while the user is in
        // fullscreen is `isVisible` to AppKit but not on the active Space;
        // treating that as showing would invert Show into Hide.
        if let panel, wantsVisible, isShowingWhereTheUserIs(panel) {
            hide()
        } else {
            show()
        }
    }

    /// Reads showing-where-the-user-is back from the panel rather than
    /// assuming — so the menu says "Show overlay" when the panel isn't
    /// actually in front of the user (including stuck on another Space).
    private func syncVisibility() {
        isVisible = panel.map { isShowingWhereTheUserIs($0) } ?? false
    }

    private func isShowingWhereTheUserIs(_ panel: FloatingPanel<OverlayView>) -> Bool {
        OverlayPlacement.isShowingWhereTheUserIs(
            isVisible: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace,
            frame: panel.frame
        )
    }

    private func makePanel() -> FloatingPanel<OverlayView> {
        // FloatingPanel's init calls setFrameAutosaveName("AgentDeckPanel"),
        // which is what persists the user's dragged position across launches.
        FloatingPanel(content: OverlayView(store: store, usage: usage))
    }
}
