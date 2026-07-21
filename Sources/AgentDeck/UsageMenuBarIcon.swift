import AppKit

/// Namespace for building the status-item label `NSImage`: the attention icon
/// plus, when usage tracking is enabled, up to two stacked mini-rows — each a
/// small SF Symbol glyph followed by a right-aligned percentage (Claude
/// 5-hour % on top, Codex weekly % on the bottom). Mirrors `AttentionIcon`'s
/// "one namespace, one place both AppKit and SwiftUI draw from" shape
/// (AttentionIcon.swift).
///
/// Why one pre-rendered bitmap for the whole label: `MenuBarExtra` labels
/// flatten SwiftUI content — custom fonts are ignored and stacked layouts
/// collapse to a single line — so two 9pt rows can only exist as pixels we
/// drew ourselves. And within the label, custom `drawingHandler` images and
/// template recoloring both proved unreliable (the usage block rendered
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
        /// Right-aligned label, e.g. "62%" or "--".
        let text: String
        /// Dimmed rows (stale/unavailable data) render at reduced alpha —
        /// both the glyph and the text — instead of disappearing entirely.
        let dimmed: Bool
    }

    /// Height of a single row in points. Two rows stack to 18pt, comfortably
    /// inside the ~22pt menu bar; a single row is 9pt and centers vertically
    /// in the status item on its own.
    private static let rowHeight: CGFloat = 9
    /// Side length of the square glyph box each symbol is centered in.
    private static let glyphSide: CGFloat = 8
    /// Gap between the glyph box and the start of the text.
    private static let glyphTextSpacing: CGFloat = 2
    /// Gap between the attention icon and the usage block in the composite.
    private static let attentionSpacing: CGFloat = 4
    /// Point size fed to the glyph's `SymbolConfiguration`.
    private static let glyphPointSize: CGFloat = 7
    /// Point size of the row's percentage text.
    private static let textPointSize: CGFloat = 8

    /// Text attributes shared by every row's percentage label.
    private static func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: textPointSize, weight: .semibold),
            .foregroundColor: color,
        ]
    }

    /// Fixed width of the usage block, independent of the actual row
    /// contents: glyph box + spacing + the width "100%" would take in the
    /// row font. Digits changing (7% → 62% → 100%) must never resize the
    /// status item — a resizing status item visibly jitters and can shift
    /// every icon to its left — so every image this builds uses this same
    /// width regardless of what the longest row's text actually is.
    private static var fixedWidth: CGFloat {
        let sample = "100%" as NSString
        let width = sample.size(withAttributes: textAttributes(color: .black)).width
        return glyphSide + glyphTextSpacing + ceil(width)
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
        let usageWidth = rows.isEmpty ? 0 : fixedWidth
        let spacing: CGFloat = (attention != nil && !rows.isEmpty) ? attentionSpacing : 0
        let width = attentionSize.width + spacing + usageWidth
        guard width > 0 else { return nil }
        let height = max(attentionSize.height, CGFloat(rows.count) * rowHeight)
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
                    y: rect.midY - CGFloat(rows.count) * rowHeight / 2,
                    width: usageWidth,
                    height: CGFloat(rows.count) * rowHeight
                )
                draw(rows: rows, in: rowsRect, baseColor: baseColor)
            }
        }
    }

    /// Just the usage block, without an attention icon. Returns nil for an
    /// empty row list — callers should omit the image entirely rather than
    /// show a blank one.
    static func image(rows: [Row], darkAppearance: Bool) -> NSImage? {
        guard !rows.isEmpty else { return nil }
        let size = NSSize(width: fixedWidth, height: CGFloat(rows.count) * rowHeight)
        let baseColor: NSColor = darkAppearance ? .white : .black
        return rasterized(size: size) { rect in
            draw(rows: rows, in: rect, baseColor: baseColor)
        }
    }

    // MARK: - Drawing

    /// Draws the rows top-to-bottom into `rect` (bottom-up coordinates, so
    /// row 0 goes in the topmost slot by walking from the top down).
    private static func draw(rows: [Row], in rect: NSRect, baseColor: NSColor) {
        for (index, row) in rows.enumerated() {
            let rowTop = rect.maxY - CGFloat(index) * rowHeight
            let rowRect = NSRect(x: rect.minX, y: rowTop - rowHeight, width: rect.width, height: rowHeight)
            let rowColor = baseColor.withAlphaComponent(row.dimmed ? 0.4 : 1.0)

            let glyphBox = NSRect(
                x: rowRect.minX,
                y: rowRect.midY - glyphSide / 2,
                width: glyphSide,
                height: glyphSide
            )
            // Palette-colored symbol configuration bakes the row color into
            // the glyph itself — a plain template symbol would rasterize
            // black here regardless of appearance.
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [rowColor]))
            if let glyph = NSImage(systemSymbolName: row.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig) {
                glyph.isTemplate = false
                glyph.draw(in: glyphBox, from: .zero, operation: .sourceOver, fraction: 1)
            }

            let text = row.text as NSString
            let attributes = textAttributes(color: rowColor)
            let textSize = text.size(withAttributes: attributes)
            let textOrigin = NSPoint(
                x: rowRect.maxX - textSize.width,
                y: rowRect.midY - textSize.height / 2
            )
            text.draw(at: textOrigin, withAttributes: attributes)
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
