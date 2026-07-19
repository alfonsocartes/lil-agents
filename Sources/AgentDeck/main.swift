import AppKit

// Menu-bar-less, Dock-less agent app: the only surface is the floating overlay.
// `.accessory` activation policy is the runtime equivalent of LSUIElement.
// Process start is already on the main thread, so assuming main-actor isolation
// here is safe and lets us construct the @MainActor AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
