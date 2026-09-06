import SwiftUI

/// A vertical `ScrollView` that hugs its content until `maxHeight`, then caps
/// and scrolls.
///
/// A bare `ScrollView` is greedy along its scroll axis: given a `maxHeight` it
/// takes all of it whether or not the content needs it, which would leave a
/// slab of dead space under one or two session rows. Both surfaces here size
/// themselves to their content — the menu-bar dropdown is a `MenuBarExtra`
/// window and the overlay is an `NSPanel` whose `NSHostingView` uses
/// `intrinsicContentSize` — so the scroll view has to report the smaller of
/// "what the content needs" and "what we allow" instead.
///
/// Measured with `onGeometryChange` rather than a `PreferenceKey`: the
/// preference variant's closure is `@Sendable` on this SDK, which makes writing
/// back to `@State` awkward for no benefit.
struct ContentSizedScrollView<Content: View>: View {
    /// The tallest the list may grow before it starts scrolling.
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .frame(height: Self.height(forContent: contentHeight, maxHeight: maxHeight))
        // Only advertise scrollability when there is something below the fold.
        // A permanently visible scroller on a two-row list reads as chrome.
        .scrollIndicators(contentHeight > maxHeight ? .visible : .automatic)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Hug the content until it exceeds `maxHeight`, then clamp.
    ///
    /// `internal static` so the rule is unit-testable without instantiating a
    /// view: this is the whole behavioral contract of the type.
    static func height(forContent contentHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        // Before the first geometry callback the content measures 0, and this
        // deliberately reports 0 rather than claiming the full allowance.
        //
        // Claiming it is the more expensive error, and not a one-time launch
        // cost: OverlayView renders its empty state and its list as separate
        // if/else branches, so they have different structural identity and
        // every empty -> non-empty transition builds a FRESH instance of this
        // view with `contentHeight` back at 0. Since FloatingPanel sizes the
        // window to its content and NSWindow grows from its bottom-left
        // origin, reserving `maxHeight` for that frame shoots the panel up
        // past the menu bar before it collapses back — each time the session
        // count returns to zero and comes back. Under-reporting for one frame
        // in a container that only ever grows is invisible by comparison.
        min(contentHeight, maxHeight)
    }
}
