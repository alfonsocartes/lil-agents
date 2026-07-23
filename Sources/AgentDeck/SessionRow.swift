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
/// The primary row action is a `.plain` `Button`, so it remains one
/// keyboard- and VoiceOver-reachable accessibility element; the separate
/// remove control appears on hover and is also exposed as an accessibility
/// action.
struct SessionRow: View {
    let session: Session
    /// What happens when the row is tapped. The call site decides — the
    /// menu-bar context closes the `MenuBarExtra` panel after jumping.
    let onSelect: () -> Void
    /// Removes the session from the shared live list without affecting the
    /// terminal or CLI process that owns it.
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
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
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jump to this session's pane")
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAction(named: "Remove") { onRemove() }

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Keep the row width stable while making removal discoverable on
            // hover; the hidden control still reserves its small slot.
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
            .help("Remove from lil agents")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .opacity(isHovering ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
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
