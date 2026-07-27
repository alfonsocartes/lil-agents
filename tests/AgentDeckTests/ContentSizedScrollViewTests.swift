import Foundation
import SwiftUI
import Testing
@testable import AgentDeck

/// The clamp rule behind both scrollable session lists. SwiftUI layout itself
/// isn't unit-testable here, but the decision that makes the container behave
/// (hug the content, then cap) is pure arithmetic and worth pinning: getting it
/// backwards either leaves dead space under a short list or lets a long one
/// push the menu's actions off screen again.
@Suite struct ContentSizedScrollViewTests {
    private func height(content: CGFloat, max: CGFloat = 320) -> CGFloat {
        ContentSizedScrollView<EmptyView>.height(forContent: content, maxHeight: max)
    }

    @Test func shortContentIsHuggedRatherThanPaddedToTheCap() {
        #expect(height(content: 86) == 86)
    }

    @Test func contentAtExactlyTheCapIsNotClamped() {
        #expect(height(content: 320) == 320)
    }

    @Test func tallContentIsCappedSoWhateverFollowsStaysOnScreen() {
        #expect(height(content: 1_200) == 320)
    }

    /// Before the first geometry callback the content measures zero. Reporting
    /// the full allowance instead would make the overlay panel — which sizes
    /// its window to this content and grows from a bottom-left origin — jump
    /// upward past the menu bar on every empty-to-populated transition, not
    /// just once at launch, because the empty and populated states are
    /// separate view identities that each start unmeasured.
    @Test func unmeasuredContentReportsZeroRatherThanReservingTheAllowance() {
        #expect(height(content: 0) == 0)
    }
}
