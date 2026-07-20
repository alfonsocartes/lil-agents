import AppKit
import SwiftUI

/// Manages the app's activation policy around the SwiftUI `Settings` scene.
///
/// This is an `LSUIElement` (accessory) app: no Dock icon, and its windows
/// can't reliably become key/frontmost or get a menu bar on their own. When
/// Settings opens we flip to `.regular` so the window comes to the front with a
/// menu bar; when it closes we revert to `.accessory` so the app returns to its
/// menu-bar-only presence. This replaces the manual policy flip the old
/// hand-rolled settings-window controller did in its `NSWindowDelegate`.
///
/// We no longer own that window (the `Settings` scene creates and owns it), so
/// instead of an `NSWindowDelegate` we observe `NSWindow.willCloseNotification`
/// and filter to the Settings window by the identifier SwiftUI stamps on it —
/// never reverting for the floating overlay panel or the `MenuBarExtra` window.
@MainActor
final class ActivationPolicyController {
    /// The identifier SwiftUI assigns to the window backing a `Settings` scene.
    /// Matching on it (rather than title or class) keeps the close filter tight:
    /// the overlay `NSPanel` and the `MenuBarExtra` window carry different (or
    /// no) identifiers, so their `willClose` never triggers the revert.
    private static let settingsSceneWindowID = "com_apple_SwiftUI_Settings_window"

    private var closeObserver: NSObjectProtocol?

    init() {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Posted on the main thread (queue: .main); hop onto the main actor
            // to satisfy isolation before touching @MainActor state.
            MainActor.assumeIsolated {
                self?.windowWillClose(notification)
            }
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// Opens Settings and brings it frontmost. `action` is SwiftUI's
    /// `openSettings` environment action; we flip to `.regular` and activate
    /// right after so the window actually takes focus and shows a menu bar in
    /// this accessory app.
    func openSettings(_ action: OpenSettingsAction) {
        action()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == Self.settingsSceneWindowID else { return }

        // Revert to accessory now that Settings is gone. Safe to do
        // unconditionally today because Settings is the *only* surface that ever
        // requests `.regular`. If another surface ever needs `.regular`, gate
        // this on whether any such surface is still open before reverting.
        NSApp.setActivationPolicy(.accessory)
    }
}
