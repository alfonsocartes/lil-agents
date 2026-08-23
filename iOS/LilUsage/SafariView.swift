import SafariServices
import SwiftUI

/// In-app Safari so the system default browser (Brave, etc.) cannot strip
/// OAuth query params. Claude's authorize URL is rejected as "Invalid
/// request format" when those params never arrive.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
