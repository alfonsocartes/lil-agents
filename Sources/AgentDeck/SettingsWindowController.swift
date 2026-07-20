import AppKit
import SwiftUI

/// Owns the single Settings window, created lazily on first `show()` and
/// reused on every subsequent open (never leaks a second window).
///
/// This is an accessory (`LSUIElement`) app with no Dock icon, so a plain
/// `NSWindow` can't reliably become key/frontmost on its own. `show()`
/// temporarily flips the app to `.regular` so the window can activate and
/// take focus normally; closing the window reverts to `.accessory` so the
/// app goes back to having no Dock presence. This mirrors the manual
/// activation-policy handling in main.swift, just scoped to the window's
/// lifetime instead of the whole app's.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: SettingsView(settings: settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "lil agents Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false   // we reuse this window; don't let AppKit deallocate it on close
        window.delegate = self
        // Center only on first creation; on reopen we keep wherever the user
        // last moved it (the window is reused, not recreated).
        window.center()
        return window
    }

    // Revert to accessory (no Dock icon) once the settings window is gone,
    // so the app returns to its normal menu-bar-only presence.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
