import SwiftUI
import AppKit

/// The overlay content: nothing but a compact, near-transparent list of sessions.
/// Title, hotkey hint, count, ⋯ menu and the stay-awake toggle were intentionally
/// removed — those controls live in the menu bar now. This is a pure glance target.
struct OverlayView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                Text("no sessions")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.sessions) { session in
                        SessionRow(session: session, context: .overlay)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .frame(minWidth: 140)
        // As transparent as possible while the shape stays discernible.
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.06)))
    }
}
