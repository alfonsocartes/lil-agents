import Foundation
import Testing
@testable import AgentDeck

/// Pins the geometry rules behind the "overlay reappears off-screen" fix.
/// `OverlayPlacement` is deliberately `NSWindow`/`NSScreen`-free so these run
/// headlessly and can exercise every rule (identity, cross-screen move,
/// downward drift while hidden, oversized panel, no-intersection fallback,
/// degenerate input) without a real display attached.
@Suite struct OverlayPlacementTests {
    /// A typical laptop display's visible frame, used as "active" almost
    /// everywhere below.
    private let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// A second display, positioned to the right of `screenA` — mirrors a
    /// real two-monitor arrangement (AppKit's global coordinate space is
    /// shared and bottom-left-origin across screens).
    private let screenB = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    private func expectContained(_ rect: CGRect, in active: CGRect) {
        #expect(rect.minX >= active.minX)
        #expect(rect.minY >= active.minY)
        #expect(rect.maxX <= active.maxX)
        #expect(rect.maxY <= active.maxY)
    }

    @Test func panelFullyInsideActiveScreenIsReturnedUnchanged() {
        let panel = CGRect(x: 100, y: 100, width: 180, height: 120)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA], active: screenA)
        #expect(result == panel)
    }

    /// The panel sits in the top-right corner of `screenB`; `screenA` becomes
    /// active (the user moved back to their main display). The mapped result
    /// must land inside `screenA` and keep the same corner — this is the
    /// "proportional position" rule, not a recenter or a blind re-anchor.
    @Test func panelOnASecondScreenMovesToActiveScreenPreservingItsCorner() {
        let panel = CGRect(
            x: screenB.maxX - 200 - 20,
            y: screenB.maxY - 150 - 20,
            width: 200,
            height: 150
        )
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA, screenB], active: screenA)

        expectContained(result, in: screenA)
        // Still (roughly) top-right of the active screen — past the
        // midpoint on both axes.
        #expect(result.maxX > screenA.midX)
        #expect(result.maxY > screenA.midY)
    }

    /// Reproduces the probe measurement from the bug report almost exactly:
    /// a panel that grew while hidden and walked below the screen's bottom
    /// edge. It must come back to rest at the screen's floor, not stay
    /// negative.
    @Test func panelDriftedBelowScreenBottomClampsToTheFloor() {
        let panel = CGRect(x: 0, y: -54, width: 180, height: 174)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA], active: screenA)

        expectContained(result, in: screenA)
        #expect(result.minY == screenA.minY)
    }

    /// A panel taller than the destination screen (e.g. a huge session list
    /// on a laptop's internal display) must shrink to fit rather than spill
    /// off the top or bottom.
    @Test func panelTallerThanTheActiveScreenIsHeightClamped() {
        let panel = CGRect(x: 100, y: 50, width: 180, height: 1_200)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA], active: screenA)

        #expect(result.height == screenA.height)
        expectContained(result, in: screenA)
    }

    /// The panel is nowhere near any known screen (e.g. all its coordinates
    /// come from a display that's long gone). With no "was" to preserve, it
    /// lands top-right of the active screen, 20pt inset — the same corner
    /// `FloatingPanel`'s original `positionTopRight()` used for a fresh
    /// panel.
    @Test func panelIntersectingNoScreenLandsTopRightWithInset() {
        let panel = CGRect(x: 5_000, y: 5_000, width: 200, height: 150)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA], active: screenA)

        let expected = CGRect(
            x: screenA.maxX - 200 - 20,
            y: screenA.maxY - 150 - 20,
            width: 200,
            height: 150
        )
        #expect(result == expected)
        expectContained(result, in: screenA)
    }

    /// Single-screen setup, panel dragged partially off the right edge —
    /// the everyday "resolution changed" case, not a cross-screen move.
    @Test func panelPartiallyOffTheRightEdgeClampsToTheRightEdge() {
        let panel = CGRect(x: 1_400, y: 100, width: 180, height: 120)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA], active: screenA)

        expectContained(result, in: screenA)
        #expect(result.maxX == screenA.maxX)
    }

    /// An empty `screens` array (every display vanished between the last
    /// save and now) must not crash `max(by:)` or divide by zero — it should
    /// degrade to the same "no source screen" top-right fallback.
    @Test func emptyScreensListDoesNotCrashAndStaysContained() {
        let panel = CGRect(x: 5_000, y: 5_000, width: 200, height: 150)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [], active: screenA)

        expectContained(result, in: screenA)
    }

    /// A collapsed (zero-height) frame whose origin is on-screen is not a
    /// user-chosen position — `active.contains` is true for a degenerate
    /// rect, so without a displayable-size floor `resolvedFrame` would
    /// return it unchanged and `present()` would order front a window that
    /// never gets a layout pass.
    @Test func zeroHeightPanelOnScreenIsInflatedToADisplayableSize() {
        let panel = CGRect(x: 100, y: 100, width: 180, height: 0)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA], active: screenA)

        #expect(result.height >= 48)
        #expect(result.width >= 1)
        expectContained(result, in: screenA)
    }

    /// Inflating height at the top edge would otherwise overflow `active`.
    /// The existing clamp must still pull the inflated rect fully on-screen.
    @Test func zeroHeightPanelAtTopEdgeIsClampedOnScreen() {
        let panel = CGRect(x: 100, y: screenA.maxY, width: 180, height: 0)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA], active: screenA)

        #expect(result.height >= 48)
        expectContained(result, in: screenA)
    }

    @Test func zeroWidthPanelIsInflated() {
        let panel = CGRect(x: 100, y: 100, width: 0, height: 40)
        let result = OverlayPlacement.resolvedFrame(panel: panel, screens: [screenA], active: screenA)

        #expect(result.width >= 1)
        expectContained(result, in: screenA)
    }
}

/// `isVisible` is true for a 0-height window and for a window on another
/// Space — neither of those is "in front of the user", so toggle must not
/// treat them as showing.
@Suite struct OverlayVisibilityTests {
    private let realFrame = CGRect(x: 100, y: 100, width: 180, height: 120)
    private let collapsed = CGRect(x: 100, y: 100, width: 180, height: 0)

    @Test func hiddenPanelIsNotShowing() {
        #expect(!OverlayPlacement.isShowingWhereTheUserIs(
            isVisible: false, isOnActiveSpace: true, frame: realFrame
        ))
    }

    @Test func visibleOnActiveSpaceWithRealFrameIsShowing() {
        #expect(OverlayPlacement.isShowingWhereTheUserIs(
            isVisible: true, isOnActiveSpace: true, frame: realFrame
        ))
    }

    @Test func visibleButOffSpaceIsNotShowing() {
        #expect(!OverlayPlacement.isShowingWhereTheUserIs(
            isVisible: true, isOnActiveSpace: false, frame: realFrame
        ))
    }

    @Test func visibleButZeroHeightIsNotShowing() {
        #expect(!OverlayPlacement.isShowingWhereTheUserIs(
            isVisible: true, isOnActiveSpace: true, frame: collapsed
        ))
    }
}
