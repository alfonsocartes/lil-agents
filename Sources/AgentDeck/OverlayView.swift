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
                        SessionRow(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture { ITermJumper.jump(tty: session.tty, cwd: session.cwd) }
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

/// One compact session line: status dot, tool glyph, project label, jump button.
private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Image(systemName: session.tool.symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(session.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Button {
                ITermJumper.jump(tty: session.tty, cwd: session.cwd)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Jump to this pane in iTerm2")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
    }

    // Traffic-light: green working, yellow idle, red needs your input.
    private var color: Color {
        switch session.status {
        case .working:         return .green
        case .idle:            return .yellow
        case .waitingApproval: return .red
        }
    }
}
