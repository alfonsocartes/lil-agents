import AppKit
import Testing
@testable import LilAgents

/// Covers `UsageMenuBarIcon.image(rows:darkAppearance:)`'s size contract.
/// The invariants that matter:
/// - The usage block is ALWAYS 21pt tall — two stacked 10.5pt rows, or one
///   full-height single-provider cell (the iStat idiom: a lone row grows
///   into the whole item, it doesn't float as a sliver) — comfortably
///   inside the ~22pt menu bar, and constant across provider toggles.
/// - Width never changes with row CONTENTS — digits, placeholders, urgency,
///   appearance — only the fixed metrics (glyph box + spacing + "100%"-sized
///   text slot) matter, so data can never make the status item jitter. Both
///   modes share those horizontal metrics, so a lone row is no wider than
///   two stacked ones.
/// - Empty rows produce nil, never a blank image.
/// The image is deliberately NOT a template (explicit white/black/urgency
/// paint instead — see the type's doc comment), so that is asserted too.
/// Pixel probes cover the compactness contract: short percents pack to
/// the leading edge in both modes, including beside the attention icon.
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

    /// Usage-only mode (session tracking off) must not reserve attention
    /// width — `labelImage(attention: nil)` matches the usage-block image.
    @Test func labelImageWithoutAttentionMatchesUsageBlockWidth() {
        let rows = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "62%", percent: 62, dimmed: false)]
        let usageOnly = UsageMenuBarIcon.image(rows: rows, darkAppearance: true)
        let composite = UsageMenuBarIcon.labelImage(attention: nil, rows: rows, darkAppearance: true)
        #expect(usageOnly?.size.width == composite?.size.width)
        #expect(usageOnly?.size.height == composite?.size.height)
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

    /// Single-provider mode used to inflate type to 12pt, so a lone row was
    /// wider than two stacked ones. Compact means the one-row cell is no
    /// wider than the two-row block — toggling a second provider on must
    /// not shrink the item, and a lone "12%" must not spend extra bar.
    @Test func singleRowIsNoWiderThanStackedRows() {
        let single = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "12%", percent: 12, dimmed: false)]
        let stacked = [
            UsageMenuBarIcon.Row(symbolName: "sparkles", text: "12%", percent: 12, dimmed: false),
            UsageMenuBarIcon.Row(
                symbolName: "chevron.left.forwardslash.chevron.right",
                text: "12%",
                percent: 12,
                dimmed: false
            ),
        ]
        let singleImage = UsageMenuBarIcon.image(rows: single, darkAppearance: true)
        let stackedImage = UsageMenuBarIcon.image(rows: stacked, darkAppearance: true)
        #expect(singleImage != nil && stackedImage != nil)
        #expect(singleImage!.size.width <= stackedImage!.size.width)
    }

    /// Short percents ("12%") used to right-align inside a "100%"-wide slot,
    /// leaving a dead gap before the glyph — the menu-bar extra looked padded
    /// on the leading edge. The pair must pack to the leading edge; unused
    /// width (reserved so 99→100 never jitters) sits trailing, as transparent
    /// pixels the next status item covers visually.
    @Test func singleRowShortPercentPacksToLeadingEdge() {
        let rows = [UsageMenuBarIcon.Row(symbolName: "sparkles", text: "12%", percent: 12, dimmed: false)]
        let image = UsageMenuBarIcon.image(rows: rows, darkAppearance: true)
        #expect(image != nil)
        let leading = firstOpaqueXPoints(image!)
        #expect(leading != nil)
        // SF Symbols don't fill their box; 2pt of ink inset is the symbol,
        // not layout padding. Anything past that is the old right-align hole.
        #expect(leading! <= 2.0)
    }

    /// Two-row mode used to right-align each pair so percents shared a
    /// trailing edge. That opened the same leading hole as single-row —
    /// and next to the attention dot it sat BETWEEN the dot and the
    /// glyphs. Stacked short percents must pack leading too; unused
    /// width stays trailing. Placeholder "--" is the worst case
    /// (narrower than "12%").
    @Test func stackedRowsShortPercentPacksToLeadingEdge() {
        let rows = [
            UsageMenuBarIcon.Row(symbolName: "sparkles", text: "12%", percent: 12, dimmed: false),
            UsageMenuBarIcon.Row(
                symbolName: "chevron.left.forwardslash.chevron.right",
                text: "--",
                percent: nil,
                dimmed: true
            ),
        ]
        let image = UsageMenuBarIcon.image(rows: rows, darkAppearance: true)
        #expect(image != nil)
        let leading = firstOpaqueXPoints(image!)
        #expect(leading != nil)
        #expect(leading! <= 2.0)
    }

    /// Attention + usage: the 4pt gap after the dot is the only air
    /// between them. A right-aligned usage block used to insert the
    /// unused "100%" slot there too (~7pt for "12%", ~20pt for "--").
    @Test func attentionThenStackedUsageHasNoDeadGap() {
        let attention = AttentionIcon.image(attention: .working, isAwake: false)
        #expect(attention != nil)
        let rows = [
            UsageMenuBarIcon.Row(symbolName: "sparkles", text: "12%", percent: 12, dimmed: false),
            UsageMenuBarIcon.Row(
                symbolName: "chevron.left.forwardslash.chevron.right",
                text: "12%",
                percent: 12,
                dimmed: false
            ),
        ]
        let image = UsageMenuBarIcon.labelImage(attention: attention, rows: rows, darkAppearance: true)
        #expect(image != nil)
        // Attention is 15pt; spacing is 4pt; usage glyph may inset 2pt.
        // Anything past ~21pt is the old right-align hole in the usage block.
        let usageStart = firstOpaqueXPoints(image!, after: attention!.size.width)
        #expect(usageStart != nil)
        #expect(usageStart! <= attention!.size.width + 4 + 2)
    }
}

/// First column with visible ink, in the image's point coordinate space.
/// `after` skips leading content (the attention glyph) so callers can
/// measure where the usage block's ink begins.
private func firstOpaqueXPoints(_ image: NSImage, after: CGFloat = 0) -> CGFloat? {
    guard let rep = image.representations.first as? NSBitmapImageRep else { return nil }
    let scale = CGFloat(rep.pixelsWide) / image.size.width
    guard scale > 0 else { return nil }
    let start = max(0, Int((after * scale).rounded(.up)))
    for x in start..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            var pixel = [Int](repeating: 0, count: 4)
            rep.getPixel(&pixel, atX: x, y: y)
            if pixel[3] > 10 {
                return CGFloat(x) / scale
            }
        }
    }
    return nil
}
