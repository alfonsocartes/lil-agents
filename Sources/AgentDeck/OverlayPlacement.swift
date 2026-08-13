import Foundation

/// Pure geometry for re-deriving the overlay panel's on-screen frame.
///
/// Why this exists: `FloatingPanel` persists its frame via
/// `setFrameAutosaveName("AgentDeckPanel")`, and `OverlayController.show()`
/// used to just `orderFrontRegardless()` that saved frame — no re-derivation
/// at all. Two things conspire to strand it off-screen:
///
/// 1. The user unplugs a display, moves to a different one, or the panel was
///    last saved on a display that's since been reconfigured. The saved
///    frame still exists, but the screen under it doesn't (or doesn't
///    anymore), and `orderFrontRegardless` doesn't know or care — it just
///    shows the window wherever its frame says, even fully off every
///    connected screen.
/// 2. While the panel is hidden, `NSHostingView`'s `sizingOptions` resizes
///    the window to fit its content keeping the TOP-LEFT corner fixed. A
///    growing session list walks the frame's origin downward — confirmed by
///    probe: an empty panel at `(0, 55, 180, 65)` drifted to `(0, -54, 180,
///    174)` after five rows were added while hidden. AppKit's
///    `constrainFrameRect` then moves *and* shrinks the frame the next time
///    it's shown, and that drifted, shrunk frame gets autosaved right back —
///    so the drift compounds across hide/show cycles instead of correcting
///    itself.
///
/// The fix is to treat the saved frame as a *hint*, not a destination:
/// re-validate it against the screen the user is actually on every time the
/// panel is shown, and only move it when it's no longer usable there. This
/// type is the pure geometry half of that — no `NSWindow`/`NSScreen`
/// involved, so it can be exercised headlessly and exhaustively rather than
/// only by eyeballing a real panel across real displays.
enum OverlayPlacement {
    /// The frame the overlay should occupy so it is fully visible on the
    /// screen the user is currently working on.
    ///
    /// - Parameters:
    ///   - panel: the panel's current frame, in AppKit's bottom-left-origin
    ///     global coordinate space.
    ///   - screens: `visibleFrame` of every connected screen.
    ///   - active: `visibleFrame` of the screen the user is on. In practice
    ///     this is an element of `screens`, but this function doesn't require
    ///     that — the caller may pass a screen that's since been unplugged
    ///     while working out where to land instead.
    /// - Returns: an integral frame fully contained in `active`.
    static func resolvedFrame(panel: CGRect, screens: [CGRect], active: CGRect) -> CGRect {
        // Rule 1: never move a panel the user deliberately positioned on the
        // screen they're currently looking at. This is the overwhelmingly
        // common case (show/hide on the same display) and it must be a
        // no-op, or every toggle would visibly jitter the panel.
        if active.contains(panel) {
            return panel
        }

        // Rule 2: work out which screen the panel "was" on, so a move to the
        // active screen can preserve where on that screen the user put it
        // (top-right stays top-right, a corner drag stays in that corner)
        // rather than just recentering or re-anchoring blindly.
        let source = screens.max { lhs, rhs in
            lhs.intersection(panel).area < rhs.intersection(panel).area
        }

        guard let source, source.intersects(panel) else {
            // The panel doesn't overlap any known screen at all — there's no
            // "was" to preserve. Anchor top-right of the active screen, 20pt
            // inset from both edges, mirroring FloatingPanel's original
            // `positionTopRight()` intent for a fresh panel.
            let inset: CGFloat = 20
            let width = min(panel.width, active.width)
            let height = min(panel.height, active.height)
            let x = active.maxX - width - inset
            let y = active.maxY - height - inset
            return clamp(CGRect(x: x, y: y, width: width, height: height), to: active)
        }

        // Rule 3: preserve the panel's proportional position within its
        // source screen. Map the origin's free-space offset (how far it sits
        // between the source screen's near edge and far edge, as a fraction
        // of the space it had to move in) onto the same fraction of the
        // active screen's free space.
        let sourceFreeWidth = source.width - panel.width
        let sourceFreeHeight = source.height - panel.height
        let fractionX = sourceFreeWidth > 0 ? (panel.minX - source.minX) / sourceFreeWidth : 0
        let fractionY = sourceFreeHeight > 0 ? (panel.minY - source.minY) / sourceFreeHeight : 0

        let activeFreeWidth = active.width - panel.width
        let activeFreeHeight = active.height - panel.height
        let x = active.minX + fractionX * activeFreeWidth
        let y = active.minY + fractionY * activeFreeHeight

        return clamp(CGRect(x: x, y: y, width: panel.width, height: panel.height), to: active)
    }

    /// Rule 4/5: shrink to fit (a panel taller/wider than the destination
    /// screen must not overflow it), then clamp the origin so the whole rect
    /// sits inside `active`, then round so the panel never lands on a
    /// half-point and blurs against the pixel grid.
    private static func clamp(_ rect: CGRect, to active: CGRect) -> CGRect {
        let width = min(rect.width, active.width)
        let height = min(rect.height, active.height)

        var x = rect.minX
        x = max(x, active.minX)
        x = min(x, active.maxX - width)

        var y = rect.minY
        y = max(y, active.minY)
        y = min(y, active.maxY - height)

        return CGRect(
            x: x.rounded(),
            y: y.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
