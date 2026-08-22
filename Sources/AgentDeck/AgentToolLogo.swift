import AppKit
import SwiftUI

extension AgentTool {
    /// Bundled logomark resource (no extension). Nominative use to identify
    /// the CLI a session belongs to. `unknown` has no mark.
    var logoResourceName: String? {
        switch self {
        case .claude: return "LogoClaude"
        case .codex: return "LogoCodex"
        case .grok: return "LogoGrok"
        case .unknown: return nil
        }
    }

    /// Template NSImage of the vendor mark, or nil to fall back to `symbol`.
    var logoImage: NSImage? {
        guard let name = logoResourceName,
              let url = AgentTool.logoURL(name),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        return image
    }

    private static func logoURL(_ name: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: "svg") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: "svg")
    }
}

/// Vendor logomark, or the SF Symbol fallback. Always template-tinted by
/// `foregroundStyle` / the current label color.
struct AgentToolIcon: View {
    let tool: AgentTool

    var body: some View {
        if let image = tool.logoImage {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Image(systemName: tool.symbol)
        }
    }
}
