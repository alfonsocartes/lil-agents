import SwiftUI
import UsageCore
#if canImport(UIKit)
import UIKit
#endif

/// Vendor logomark, same shapes as Mac lil agents. Images are white-on-
/// transparent templates so they tint with the surrounding foreground.
/// Black-on-transparent templates compile to empty glyphs in Assets.car.
struct ProviderLogo: View {
    let kind: ProviderKind

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: String {
        switch kind {
        case .claude: "sparkles"
        case .grok: "hare"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    private var image: UIImage? {
        #if canImport(UIKit)
        UIImage(named: ProviderChrome.logoAssetName(kind))?
            .withRenderingMode(.alwaysTemplate)
        #else
        nil
        #endif
    }
}
