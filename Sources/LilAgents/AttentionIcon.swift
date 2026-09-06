import AppKit

/// Single source of truth for the status indicator shown in BOTH the menu bar
/// item and the overlay header, so the icon looks identical whether the overlay
/// is visible or hidden.
extension SessionStore.Attention {
    /// SF Symbol name for this attention level.
    var symbolName: String {
        switch self {
        case .needsInput: return "exclamationmark.circle.fill"
        case .idle:       return "circle.fill"
        case .working:    return "circle.fill"
        case .none:       return "circle.dotted"
        }
    }

    /// Tint color, or nil to render monochrome (template) when there are no
    /// sessions at all. Traffic-light: green working, yellow idle, red needs-input.
    var tint: NSColor? {
        switch self {
        case .needsInput: return .systemRed
        case .idle:       return .systemYellow
        case .working:    return .systemGreen
        case .none:       return nil
        }
    }
}

/// Namespace for building the status-item `NSImage` itself, so both the
/// AppKit menu bar and (in a later phase) SwiftUI can share the exact same
/// pixels.
enum AttentionIcon {
    /// Builds the status-item image for a given attention level and
    /// stay-awake state. Stay-awake ON swaps in a `bolt.fill` glyph while
    /// keeping the traffic-light tint; otherwise the normal per-attention
    /// symbol is used. Tinted images render non-template (`isTemplate =
    /// false`); the untinted, no-attention image renders as a template so it
    /// adapts to the menu bar's light/dark appearance.
    static func image(attention: SessionStore.Attention, isAwake: Bool) -> NSImage? {
        let symbol = isAwake ? "bolt.fill" : attention.symbolName
        let color = attention.tint

        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let color {
            let tinted = base.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "lil agents")?
                .withSymbolConfiguration(tinted)
            image?.isTemplate = false
            return image
        } else {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "lil agents")?
                .withSymbolConfiguration(base)
            image?.isTemplate = true   // adapt to light/dark menu bar
            return image
        }
    }
}
