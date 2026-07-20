import SwiftUI

/// One session line in the menu-bar dropdown.
///
/// This view used to also render the overlay's compact row via a `context`
/// switch, but the two surfaces diverged: the overlay grew its own layout
/// (`OverlaySessionRow` in OverlayView.swift) tuned for name legibility and
/// minimal chrome, while this row keeps the roomier menu treatment with an
/// always-on detail line and a jump affordance. Sharing was a means (one
/// place to update), not an end — once every overlay tweak risked the menu,
/// the split became the safer shape. The menu's appearance is unchanged.
///
/// The row is a single `Button` (row-level, `.plain` style) so it's one
/// accessibility element that's keyboard- and VoiceOver-reachable — not just
/// mouse-tappable.
struct SessionRow: View {
    let session: Session
    /// What happens when the row is tapped. The call site decides — the
    /// menu-bar context closes the `MenuBarExtra` panel after jumping.
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
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
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Jump to this session's pane")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Bits

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
