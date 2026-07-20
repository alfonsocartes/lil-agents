import SwiftUI

/// One session line, shared by the overlay and the menu-bar dropdown so the
/// two surfaces can't drift the way their previous private copies did.
///
/// Both contexts render the same underlying `Button` (row-level, `.plain`
/// style) so a row is a single accessibility element that's keyboard- and
/// VoiceOver-reachable — not just mouse-tappable.
struct SessionRow: View {
    /// Which surface is hosting the row — controls density and the extra
    /// detail line, not the underlying interaction or data.
    enum Context {
        /// Compact line on the translucent overlay panel.
        case overlay
        /// Roomier row in the menu-bar dropdown, with a secondary detail line.
        case menu
    }

    let session: Session
    let context: Context

    @State private var isHovering = false

    var body: some View {
        Button {
            TerminalJumpers.jump(session.jumpTarget)
        } label: {
            switch context {
            case .overlay: overlayLabel
            case .menu:    menuLabel
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Jump to this session's pane")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Overlay layout

    private var overlayLabel: some View {
        HStack(spacing: 7) {
            statusDot(diameter: 7)
            Image(systemName: session.tool.symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(session.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white.opacity(0.08))
                .opacity(isHovering ? 1 : 0)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Menu layout

    private var menuLabel: some View {
        HStack(spacing: 8) {
            statusDot(diameter: 8)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.label)
                    .font(.body)
                    .lineLimit(1)
                Text("\(session.tool.display) · \(statusLabel) · \(elapsedLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "arrow.up.forward.app")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .opacity(isHovering ? 1 : 0)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Shared bits

    private func statusDot(diameter: CGFloat) -> some View {
        Circle()
            .fill(statusColor)
            .frame(width: diameter, height: diameter)
    }

    // Traffic-light: green working, yellow idle/finished-turn, red needs
    // your input now. Yellow (not orange) to match the shipped menu-bar icon.
    private var statusColor: Color {
        switch session.status {
        case .working:         return .green
        case .idle:            return .yellow
        case .waitingApproval: return .red
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .working:         return "working"
        case .idle:            return "idle"
        case .waitingApproval: return "needs input"
        }
    }

    private var elapsedLabel: String {
        let seconds = max(0, Date().timeIntervalSince(session.lastUpdate))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }

    private var accessibilityLabel: String {
        "\(session.label), \(session.tool.display), \(statusLabel)"
    }
}
