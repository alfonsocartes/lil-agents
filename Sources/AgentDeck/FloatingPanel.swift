import AppKit
import SwiftUI

/// A non-activating, always-on-top panel that floats over every Space and full-
/// screen app. Clicking it never steals key focus from the terminal underneath.
final class FloatingPanel<Content: View>: NSPanel {
    init(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let hosting = NSHostingView(rootView: content)
        // Let the SwiftUI content drive the window size so the panel hugs the
        // session list (and shrinks/grows as sessions come and go).
        hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        contentView = hosting

        setFrameAutosaveName("AgentDeckPanel")
        if frameAutosaveName.isEmpty || frame.origin == .zero {
            positionTopRight()
        }
    }

    /// A borderless-ish panel can still be key so its controls (toggle) work.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - frame.width - 20
        let y = visible.maxY - frame.height - 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
