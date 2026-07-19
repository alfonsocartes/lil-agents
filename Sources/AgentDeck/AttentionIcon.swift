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
