import AppKit
import Testing
@testable import AgentDeck

/// Covers `UsageMenuBarIcon.image(rows:darkAppearance:)`'s size contract:
/// row count drives height directly (9pt per row), and the width never
/// changes with the digits in the text — only the fixed metrics (glyph box +
/// spacing + "100%"-sized slot) matter. The image is deliberately NOT a
/// template (explicit white/black paint instead — see the type's doc
/// comment), so that is asserted too. Drawing itself isn't exercised (the
/// drawingHandler only runs when the image is actually rasterized) —
/// `size`/`isTemplate` are set eagerly and are what callers rely on.
@Suite struct UsageMenuBarIconTests {
    @Test func twoRowsProduceDoubleHeightNonTemplateImage() {
        let rows = [
            UsageMenuBarIcon.Row(symbolName: "sparkles", text: "62%", dimmed: false),
            UsageMenuBarIcon.Row(symbolName: "chevron.left.forwardslash.chevron.right", text: "30%", dimmed: false),
        ]
        let image = UsageMenuBarIcon.image(rows: rows, darkAppearance: true)
        #expect(image?.size.height == 18)
        #expect(image?.isTemplate == false)
    }

    @Test func singleRowProducesOneRowHeight() {
        let rows = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "62%", dimmed: false)]
        let image = UsageMenuBarIcon.image(rows: rows, darkAppearance: false)
        #expect(image?.size.height == 9)
    }

    @Test func emptyRowsReturnsNil() {
        #expect(UsageMenuBarIcon.image(rows: [], darkAppearance: true) == nil)
    }

    @Test func widthIsFixedRegardlessOfDigitCountAndAppearance() {
        let shortRow = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "7%", dimmed: false)]
        let longRow = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "100%", dimmed: false)]
        let shortImage = UsageMenuBarIcon.image(rows: shortRow, darkAppearance: true)
        let longImage = UsageMenuBarIcon.image(rows: longRow, darkAppearance: false)
        #expect(shortImage?.size.width == longImage?.size.width)
    }
}
