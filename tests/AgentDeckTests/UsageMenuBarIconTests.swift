import AppKit
import Testing
@testable import AgentDeck

/// Covers `UsageMenuBarIcon.image(rows:darkAppearance:)`'s size contract.
/// The invariants that matter:
/// - The usage block is ALWAYS 21pt tall — two stacked 10.5pt rows, or one
///   full-height single-provider cell (the iStat idiom: a lone row grows
///   into the whole item, it doesn't float as a sliver) — comfortably
///   inside the ~22pt menu bar, and constant across provider toggles.
/// - Width never changes with row CONTENTS — digits, placeholders, urgency,
///   appearance — only the mode's fixed metrics (glyph box + spacing +
///   "100%"-sized text slot) matter, so data can never make the status item
///   jitter. The one-row and two-row MODES may differ in width (different
///   font sizes); that's a Settings change, not jitter.
/// - Empty rows produce nil, never a blank image.
/// The image is deliberately NOT a template (explicit white/black/urgency
/// paint instead — see the type's doc comment), so that is asserted too.
/// Drawing itself isn't exercised — `size`/`isTemplate` are set eagerly and
/// are what callers rely on.
@Suite struct UsageMenuBarIconTests {
    @Test func twoRowsProduceFullBlockHeightNonTemplateImage() {
        let rows = [
            UsageMenuBarIcon.Row(symbolName: "sparkles", text: "62%", percent: 62, dimmed: false),
            UsageMenuBarIcon.Row(
                symbolName: "chevron.left.forwardslash.chevron.right",
                text: "30%",
                percent: 30,
                dimmed: false
            ),
        ]
        let image = UsageMenuBarIcon.image(rows: rows, darkAppearance: true)
        #expect(image?.size.height == 21)
        #expect(image?.isTemplate == false)
    }

    /// Single-provider mode: the lone row owns the full 21pt block instead
    /// of rendering as a half-height sliver — same item height as two-row
    /// mode, so toggling a provider never changes the item's height.
    @Test func singleRowOwnsTheFullBlockHeight() {
        let rows = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "62%", percent: 62, dimmed: false)]
        let image = UsageMenuBarIcon.image(rows: rows, darkAppearance: false)
        #expect(image?.size.height == 21)
    }

    @Test func emptyRowsReturnsNil() {
        #expect(UsageMenuBarIcon.image(rows: [], darkAppearance: true) == nil)
    }

    @Test func widthIsFixedRegardlessOfDigitCountAndAppearance() {
        let shortRow = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "7%", percent: 7, dimmed: false)]
        let longRow = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "100%", percent: 100, dimmed: false)]
        let shortImage = UsageMenuBarIcon.image(rows: shortRow, darkAppearance: true)
        let longImage = UsageMenuBarIcon.image(rows: longRow, darkAppearance: false)
        #expect(shortImage?.size.width == longImage?.size.width)
    }

    /// The placeholder state ("--", nil percent) must occupy the exact same
    /// footprint as live data at any urgency tier — data arriving, going
    /// stale, or crossing 90% can never move the item. Exercised in two-row
    /// mode so it also pins the stacked metrics path (the digit-count test
    /// above covers single-row mode).
    @Test func widthIsFixedAcrossPlaceholderAndUrgencyStates() {
        func rows(text: String, percent: Double?) -> [UsageMenuBarIcon.Row] {
            [
                UsageMenuBarIcon.Row(symbolName: "sparkles", text: text, percent: percent, dimmed: percent == nil),
                UsageMenuBarIcon.Row(
                    symbolName: "chevron.left.forwardslash.chevron.right",
                    text: text,
                    percent: percent,
                    dimmed: percent == nil
                ),
            ]
        }
        let placeholderImage = UsageMenuBarIcon.image(rows: rows(text: "--", percent: nil), darkAppearance: true)
        let criticalImage = UsageMenuBarIcon.image(rows: rows(text: "95%", percent: 95), darkAppearance: true)
        #expect(placeholderImage?.size.width == criticalImage?.size.width)
    }
}
