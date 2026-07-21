import AppKit

/// Namespace for building the status-item label `NSImage`: the attention icon
/// plus, when usage tracking is enabled, an iStat-Menus-style usage block —
/// one or two rows, each a small SF Symbol glyph followed by a right-aligned
/// percentage (Claude 5-hour % on top, Codex weekly % on the bottom). No
/// gauge here: at menu bar sizes the number IS the gauge — user feedback
/// confirmed the micro-bar cost width without adding read speed, and the
/// reclaimed points went into bigger, heavier digits instead (the iStat
/// trade: typography over ornament). Capacity bars live in the dropdown and
/// overlay. What the menu bar keeps from the shared usage language
/// (`UsageUrgency`, UsageModel.swift) is the urgency tint on the percent
/// itself: quiet monochrome below 75%, amber >= 75%, red >= 90%, identical
/// thresholds to every other surface. Mirrors `AttentionIcon`'s "one
/// namespace, one place both AppKit and SwiftUI draw from" shape
/// (AttentionIcon.swift).
///
/// Why one pre-rendered bitmap for the whole label: `MenuBarExtra` labels
/// flatten SwiftUI content — custom fonts are ignored and stacked layouts
/// collapse to a single line — so stacked mini-rows can only exist as pixels
/// we drew ourselves. And within the label, custom `drawingHandler` images
/// and template recoloring both proved unreliable (the usage block rendered
/// black-on-black or not at all), so everything is rasterized eagerly into a
/// plain bitmap representation with explicit colors: the proven-working
/// "single `Image(nsImage:)` label" pattern the attention icon already ships.
///
/// Colors are painted for the appearance the caller passes (white on a dark
/// menu bar, black on a light one, read from the SwiftUI `colorScheme`
/// environment so the label re-renders when the system appearance flips).
enum UsageMenuBarIcon {
    /// One row of the usage block: a glyph plus its percentage text.
    struct Row: Equatable {
        /// SF Symbol name drawn at the row's leading edge.
        let symbolName: String
        /// Right-aligned label, e.g. "62%" or "--". Kept as a separate field
        /// (rather than derived from `percent`) so `UsageFormatting` stays
        /// the single source of the "62%"/"--" phrasing.
        let text: String
        /// Raw percent (0–100) driving the urgency tier of the text tint;
        /// nil (the "--" placeholder) is always the quiet monochrome tier.
        let percent: Double?
        /// Dimmed rows (stale/unavailable data) render at reduced alpha —
        /// both the glyph and the text — instead of disappearing entirely.
        let dimmed: Bool
    }

    /// Total height of the usage block in EVERY mode: two stacked 10.5pt
    /// rows, or one full-height row when only a single provider is enabled —
    /// the iStat idiom where a lone cell grows into the whole item instead
    /// of floating as a tiny line in empty space. A constant block height
    /// also means toggling a provider on/off never changes the item's
    /// height. 21pt sits inside the ~22pt menu bar (the attention icon
    /// already renders the item taller than the old 18pt block did), and the
    /// digits' actual ink — cap height only; "0–9%" has no descenders —
    /// spans well under the slot, so nothing clips even on a classic
    /// non-notched bar.
    private static let blockHeight: CGFloat = 21

    /// Per-mode drawing metrics. Two providers pack as dense stacked cells;
    /// one provider relaxes into a single larger cell — bigger font, bigger
    /// glyph, vertically centered — because the density was only ever the
    /// price of fitting two. Both modes use `.medium` weight (heavier than
    /// the old 8pt block for bar legibility, lighter than bold so digits
    /// don't smear at the 2x raster) with monospaced digits.
    private struct Metrics {
        /// Height of one row slot; rows stack top-down inside `blockHeight`.
        let rowHeight: CGFloat
        /// Side length of the square glyph box each symbol is centered in.
        let glyphSide: CGFloat
        /// Point size fed to the glyph's `SymbolConfiguration`.
        let glyphPointSize: CGFloat
        /// Point size of the row's percentage text.
        let textPointSize: CGFloat
        /// Gap between the glyph box and its number. Tight (2pt) because the
        /// glyph HUGS the text: the pair renders as one right-aligned unit
        /// (see `draw`), so this gap is all the air between them.
        let glyphTextSpacing: CGFloat

        /// iStat-style dense two-row cell: 10pt digits in 10.5pt rows,
        /// 9pt glyph in a 10pt box.
        static let stacked = Metrics(
            rowHeight: blockHeight / 2, glyphSide: 10, glyphPointSize: 9,
            textPointSize: 10, glyphTextSpacing: 2
        )
        /// Single-provider cell: the row owns the whole 21pt block, so the
        /// type scales up to match — 12pt digits, 11pt glyph.
        static let single = Metrics(
            rowHeight: blockHeight, glyphSide: 12, glyphPointSize: 11,
            textPointSize: 12, glyphTextSpacing: 2
        )

        /// Stacked for two rows, single for one — the row COUNT is the mode.
        static func forRowCount(_ count: Int) -> Metrics {
            count == 1 ? .single : .stacked
        }

        /// Text attributes shared by every row's percentage label.
        func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedDigitSystemFont(ofSize: textPointSize, weight: .medium),
                .foregroundColor: color,
            ]
        }

        /// Fixed width of the usage block FOR THIS MODE, independent of the
        /// actual row contents: glyph box + gap + the width "100%" would
        /// take in the row font (the worst-case glyph+number pair exactly
        /// fills the block). Digits changing (7% → 62% → 100%) must never
        /// resize the status item — a resizing status item visibly jitters
        /// and can shift every icon to its left — so every image built in a
        /// given mode uses this same width regardless of what the longest
        /// row's text actually is; shorter pairs right-align inside it (see
        /// `draw`). The two MODES have different widths (a 12pt single cell
        /// is wider than a 10pt stacked one); that's deliberate and safe:
        /// modes only switch when the user toggles a provider in Settings —
        /// a state change, not data jitter.
        var fixedWidth: CGFloat {
            let sample = "100%" as NSString
            let width = sample.size(withAttributes: textAttributes(color: .black)).width
            return glyphSide + glyphTextSpacing + ceil(width)
        }
    }

    /// Gap between the attention icon and the usage block in the composite.
    private static let attentionSpacing: CGFloat = 4
    /// Alpha applied to a dimmed (stale/loading/unavailable) row's every
    /// element — the bitmap equivalent of the SwiftUI surfaces' opacity dip.
    private static let dimmedAlpha: CGFloat = 0.4

    // MARK: - Urgency colors

    /// Explicit text color for a row's urgency tier, baked per appearance.
    /// `.normal` stays the monochrome bar color — quiet until there's
    /// something to say. The amber/red values are Apple's system orange/red
    /// sRGB values for each appearance, written out literally because
    /// dynamic `NSColor.systemOrange`/`.systemRed` resolve against
    /// `NSAppearance.current` at draw time — inside this offscreen bitmap
    /// context that is NOT reliably the menu bar's appearance, and this
    /// pipeline exists precisely because implicit appearance machinery
    /// failed inside the `MenuBarExtra` label (see the type doc comment).
    private static func urgencyColor(
        _ urgency: UsageUrgency,
        base: NSColor,
        darkAppearance: Bool
    ) -> NSColor {
        switch urgency {
        case .normal:
            return base
        case .elevated:
            return darkAppearance
                ? NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 1)
                : NSColor(srgbRed: 1, green: 149 / 255, blue: 0, alpha: 1)
        case .critical:
            return darkAppearance
                ? NSColor(srgbRed: 1, green: 69 / 255, blue: 58 / 255, alpha: 1)
                : NSColor(srgbRed: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)
        }
    }

    // MARK: - Public builders

    /// The full status-item label: `attention` (drawn at its natural size,
    /// colors preserved; template attention icons are tinted to the bar
    /// color) followed by the usage rows. Pass an empty `rows` to get just
    /// the attention icon — though callers should prefer using the attention
    /// image directly in that case to keep today's exact appearance.
    /// Returns nil only when there is nothing to draw at all.
    static func labelImage(attention: NSImage?, rows: [Row], darkAppearance: Bool) -> NSImage? {
        let attentionSize = attention?.size ?? .zero
        let metrics = Metrics.forRowCount(rows.count)
        let usageWidth = rows.isEmpty ? 0 : metrics.fixedWidth
        let spacing: CGFloat = (attention != nil && !rows.isEmpty) ? attentionSpacing : 0
        let width = attentionSize.width + spacing + usageWidth
        guard width > 0 else { return nil }
        let height = max(attentionSize.height, rows.isEmpty ? 0 : blockHeight)
        let baseColor: NSColor = darkAppearance ? .white : .black

        return rasterized(size: NSSize(width: width, height: height)) { rect in
            if let attention {
                let box = NSRect(
                    x: rect.minX,
                    y: rect.midY - attentionSize.height / 2,
                    width: attentionSize.width,
                    height: attentionSize.height
                )
                attention.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                if attention.isTemplate {
                    // The no-session attention icon is a template (black
                    // pixels): baked into a bitmap it would vanish on a dark
                    // menu bar, so tint it to the bar color ourselves.
                    baseColor.set()
                    box.fill(using: .sourceAtop)
                }
            }
            if !rows.isEmpty {
                let rowsRect = NSRect(
                    x: rect.minX + attentionSize.width + spacing,
                    y: rect.midY - blockHeight / 2,
                    width: usageWidth,
                    height: blockHeight
                )
                draw(rows: rows, in: rowsRect, metrics: metrics,
                     baseColor: baseColor, darkAppearance: darkAppearance)
            }
        }
    }

    /// Just the usage block, without an attention icon. Returns nil for an
    /// empty row list — callers should omit the image entirely rather than
    /// show a blank one.
    static func image(rows: [Row], darkAppearance: Bool) -> NSImage? {
        guard !rows.isEmpty else { return nil }
        let metrics = Metrics.forRowCount(rows.count)
        let size = NSSize(width: metrics.fixedWidth, height: blockHeight)
        let baseColor: NSColor = darkAppearance ? .white : .black
        return rasterized(size: size) { rect in
            draw(rows: rows, in: rect, metrics: metrics,
                 baseColor: baseColor, darkAppearance: darkAppearance)
        }
    }

    // MARK: - Drawing

    /// Draws the rows top-to-bottom into `rect` (bottom-up coordinates, so
    /// row 0 goes in the topmost slot by walking from the top down). Row
    /// anatomy: identity glyph (always monochrome — WHICH provider never
    /// carries urgency) immediately followed by its percent, tinted only
    /// when the tier is non-normal so at normal usage the whole row reads as
    /// quiet monochrome.
    ///
    /// The glyph+number pair is laid out as ONE right-aligned unit: the text
    /// hugs the block's trailing edge and the glyph hugs the text's leading
    /// edge (2pt gap). Anchoring the glyph to the block's LEFT edge instead
    /// opened a dead gap in the middle for typical 2-digit percents — the
    /// text right-aligns in a "100%"-sized slot, so the shorter the number,
    /// the more the pair fell apart. The glyph therefore shifts by a
    /// digit-width when a value crosses 9→10 or 99→100; that's the number
    /// changing, not layout jitter — the image's TOTAL width (sized for the
    /// worst-case pair) never moves, so the status item never resizes.
    private static func draw(
        rows: [Row],
        in rect: NSRect,
        metrics: Metrics,
        baseColor: NSColor,
        darkAppearance: Bool
    ) {
        for (index, row) in rows.enumerated() {
            let rowTop = rect.maxY - CGFloat(index) * metrics.rowHeight
            let rowRect = NSRect(
                x: rect.minX,
                y: rowTop - metrics.rowHeight,
                width: rect.width,
                height: metrics.rowHeight
            )
            let alpha = row.dimmed ? dimmedAlpha : 1.0
            let rowColor = baseColor.withAlphaComponent(alpha)
            let urgency = UsageUrgency(percent: row.percent)
            let textColor = urgencyColor(urgency, base: baseColor, darkAppearance: darkAppearance)
                .withAlphaComponent(alpha)

            // Text first: its measured width decides where the glyph goes.
            let text = row.text as NSString
            let attributes = metrics.textAttributes(color: textColor)
            let textSize = text.size(withAttributes: attributes)
            let textOrigin = NSPoint(
                x: rowRect.maxX - textSize.width,
                y: rowRect.midY - textSize.height / 2
            )
            text.draw(at: textOrigin, withAttributes: attributes)

            // Glyph anchored to the text's leading edge, not the block's —
            // see the method doc comment for why.
            let glyphBox = NSRect(
                x: textOrigin.x - metrics.glyphTextSpacing - metrics.glyphSide,
                y: rowRect.midY - metrics.glyphSide / 2,
                width: metrics.glyphSide,
                height: metrics.glyphSide
            )
            // Palette-colored symbol configuration bakes the row color into
            // the glyph itself — a plain template symbol would rasterize
            // black here regardless of appearance.
            let symbolConfig = NSImage.SymbolConfiguration(
                pointSize: metrics.glyphPointSize,
                weight: .bold
            )
            .applying(NSImage.SymbolConfiguration(paletteColors: [rowColor]))
            if let glyph = NSImage(systemSymbolName: row.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig) {
                glyph.isTemplate = false
                glyph.draw(in: glyphBox, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    /// Renders into an explicit 2x `NSBitmapImageRep` instead of a
    /// `drawingHandler`-backed image: a plain bitmap displays anywhere any
    /// image does, while lazily-drawn handler images empirically never
    /// appeared inside the `MenuBarExtra` label.
    private static func rasterized(size: NSSize, draw: (NSRect) -> Void) -> NSImage? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
