import SwiftUI

/// System paste control — the one iOS actually grants pasteboard access to.
struct ClipboardPasteButton: View {
    var onPaste: (String) -> Void

    var body: some View {
        PasteButton(payloadType: String.self) { items in
            guard let text = items.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            onPaste(text)
        }
    }
}
