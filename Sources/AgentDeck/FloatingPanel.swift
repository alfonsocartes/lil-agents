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
        level = .screenSaver
        collectionBehavior = Self.overlayBehavior
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
        // Floor so NSHostingView can't hug a 0-height window after inflate:
        // ContentSizedScrollView reports 0 until onGeometryChange commits,
        // and sizingOptions includes .intrinsicContentSize. Empty hint is
        // ~this tall; the session list grows above it.
        minSize = NSSize(width: 180, height: 48)
        // We reuse this panel. The NSWindow default would let a close()
        // (Escape on a key panel, etc.) tear the window-server connection
        // while OverlayController still holds the object.
        isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: content)
        // Let the SwiftUI content drive the window size so the panel hugs the
        // session list (and shrinks/grows as sessions come and go).
        hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        contentView = hosting

        setFrameAutosaveName("AgentDeckPanel")
        // `frame.origin == .zero` misses a 0-height frame with a real origin
        // — the autosaved collapsed state. Reset that to the init size so
        // `positionTopRight` has something displayable to place.
        if !OverlayPlacement.isDisplayable(frame) {
            setFrame(NSRect(x: 0, y: 0, width: 260, height: 120), display: false)
            positionTopRight()
        } else if frameAutosaveName.isEmpty || frame.origin == .zero {
            positionTopRight()
        }
    }

    /// A borderless-ish panel can still be key so its controls (toggle) work.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // `.floating` / `.statusBar` sit below full-screen content. `.screenSaver`
    // plus `.canJoinAllApplications` (distinct collection-behavior group from
    // `.fullScreenAuxiliary`) is what joins other apps' fullscreen Spaces.
    // Do not combine `.canJoinAllSpaces` with `.moveToActiveSpace`.
    // Computed: a stored `static let` isn't allowed on a generic type.
    private static var overlayBehavior: NSWindow.CollectionBehavior {
        [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
        ]
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - frame.width - 20
        let y = visible.maxY - frame.height - 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Re-assert Space membership without moving the frame.
    func rejoinSpaces() {
        applyOverlayBehavior()
        orderFrontRegardless()
        if !isOnActiveSpace {
            applyOverlayBehavior()
            orderFrontRegardless()
        }
    }

    /// Orders the panel front, re-deriving everything that can have gone
    /// stale while it was hidden. This is the single entry point for showing
    /// the panel — see `OverlayPlacement`'s doc comment for the full story
    /// of why a plain `orderFrontRegardless()` on the autosaved frame isn't
    /// enough: the frame can drift off-screen while hidden, and the panel's
    /// Space membership can be silently dropped by the window server across
    /// full-screen transitions and display reconfiguration.
    ///
    /// Space-change re-assertion without moving the frame is `rejoinSpaces()`.
    func present() {
        applyOverlayBehavior()

        if let activeScreen = FloatingPanel.currentScreen() {
            let resolved = OverlayPlacement.resolvedFrame(
                panel: frame,
                screens: NSScreen.screens.map(\.visibleFrame),
                active: activeScreen.visibleFrame
            )
            if resolved != frame {
                setFrame(resolved, display: true)
            }
        }

        // `orderFrontRegardless` (not `makeKeyAndOrderFront`) — the overlay must
        // never steal key focus from the terminal underneath.
        orderFrontRegardless()

        if !isOnActiveSpace {
            applyOverlayBehavior()
            orderFrontRegardless()
        }
    }

    private func applyOverlayBehavior() {
        // Don't assign `[]` first — that's Default and ejects the window from
        // the current fullscreen Space.
        level = .screenSaver
        collectionBehavior = Self.overlayBehavior
    }

    /// Pulls the panel back onto a live screen after a display arrangement
    /// change (an external monitor unplugged, resolution changed, etc.) —
    /// exactly the case that otherwise strands the panel on a screen that no
    /// longer exists until the next `present()`. Applied unconditionally,
    /// visible or not, because a hidden panel is precisely the one nobody
    /// notices has drifted until they toggle it and nothing appears.
    ///
    /// Unlike `present()`, this must NOT jump the panel to wherever the user
    /// currently has focus — a display change happening while the user is
    /// working on an unrelated screen shouldn't relocate a panel that's
    /// otherwise fine. So the "active" screen here is whichever live screen
    /// the panel itself still overlaps most, falling back to the same
    /// current-screen resolution `present()` uses only when the panel's own
    /// screen is gone entirely.
    func reclampToScreens() {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let mostOverlapped = visibleFrames
            .filter { $0.intersects(frame) }
            .max { lhs, rhs in
                let lhsArea = lhs.intersection(frame).width * lhs.intersection(frame).height
                let rhsArea = rhs.intersection(frame).width * rhs.intersection(frame).height
                return lhsArea < rhsArea
            }
        guard let active = mostOverlapped ?? FloatingPanel.currentScreen()?.visibleFrame else { return }

        let resolved = OverlayPlacement.resolvedFrame(panel: frame, screens: visibleFrames, active: active)
        if resolved != frame {
            setFrame(resolved, display: false)
        }
    }

    /// "Where the user is", for placement purposes: `NSScreen.main` (for a
    /// background accessory app this resolves to the screen holding the
    /// frontmost app's key window, which is the right proxy), falling back
    /// to the screen under the mouse, falling back to the first connected
    /// screen. `nil` only when there are no screens at all, in which case
    /// callers skip repositioning and just order front.
    private static func currentScreen() -> NSScreen? {
        NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.screens.first
    }
}
