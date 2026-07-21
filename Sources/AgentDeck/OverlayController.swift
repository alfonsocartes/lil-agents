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
@MainActor
@Observable
final class OverlayController {
    /// Whether the overlay panel is currently on screen.
    private(set) var isVisible: Bool = false

    private let store: SessionStore
    private let usage: UsageStore
    private var panel: FloatingPanel<OverlayView>?

    init(store: SessionStore, usage: UsageStore) {
        self.store = store
        self.usage = usage
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Kick off a refresh every time the overlay is raised, throttled by
        // `refreshIfStale`'s own `lastAttemptAt`/`retryAfterUntil` gates so
        // repeated toggling never spams either provider's API.
        usage.refreshIfStale()
        // `orderFrontRegardless` (not `makeKeyAndOrderFront`) — the overlay must
        // never steal key focus from the terminal underneath.
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    private func makePanel() -> FloatingPanel<OverlayView> {
        // FloatingPanel's init calls setFrameAutosaveName("AgentDeckPanel"),
        // which is what persists the user's dragged position across launches.
        FloatingPanel(content: OverlayView(store: store, usage: usage))
    }
}
