import SwiftUI
import AppKit

// MARK: - Display ordering

extension Array where Element == Session {
    /// Stable display order shared by the overlay and the menu-bar dropdown:
    /// grouped by project label, then working directory, then session id.
    ///
    /// The store's own `sessions` array is status-sorted and recency-sorted,
    /// which makes rows jump around every time a session changes state or
    /// receives a heartbeat. For a glanceable ambient surface that's hostile:
    /// the user builds spatial memory ("ai-sessions is the second row") and a
    /// reshuffle breaks it mid-glance — or worse, mid-click. Every key used
    /// here is fixed for the life of a session, so a row can never move once
    /// it exists; combined with `ForEach`'s `session.id` identity, SwiftUI
    /// updates rows in place instead of tearing them down.
    var displayOrdered: [Session] {
        sorted { a, b in
            let byLabel = a.label.localizedStandardCompare(b.label)
            if byLabel != .orderedSame { return byLabel == .orderedAscending }
            let byCwd = (a.cwd ?? "").localizedStandardCompare(b.cwd ?? "")
            if byCwd != .orderedSame { return byCwd == .orderedAscending }
            return a.id < b.id
        }
    }
}

// MARK: - Overlay

/// The overlay content: a compact, translucent list of sessions — a pure
/// glance target. Title, hotkey hint, count, ⋯ menu and the stay-awake toggle
/// were intentionally removed; those controls live in the menu bar.
///
/// Layout decisions, deliberately:
/// - Fixed width (not intrinsic): project names get room and truncate at the
///   END (`ai-sessions…`), never mid-string garbage (`ai-s…ons`), and the
///   panel footprint stays predictable instead of breathing as text changes.
/// - Rows are ordered by project (see `displayOrdered`), not by status, so
///   they never reshuffle under the cursor.
/// - `.ultraThinMaterial` + semantic hairline instead of a hard-coded black
///   wash, so it reads as a native widget in both light and dark mode.
/// - Elapsed time is wrapped in a per-minute `TimelineView` so "5m" stays
///   honest without the store having to publish anything.
struct OverlayView: View {
    let store: SessionStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            Group {
                if store.sessions.isEmpty {
                    emptyHint
                } else {
                    sessionList(now: timeline.date)
                }
            }
        }
        .frame(width: 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
    }

    /// A quiet one-liner rather than an invisible sliver: the panel is toggled
    /// manually, so when it's empty the user still needs to see (and drag) it —
    /// a blank shape would read as a bug.
    private var emptyHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz")
            Text("No active sessions")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func sessionList(now: Date) -> some View {
        let sessions = store.sessions.displayOrdered
        return VStack(spacing: 1) {
            ForEach(sessions) { session in
                OverlaySessionRow(
                    session: session,
                    detail: detail(for: session, among: sessions),
                    now: now
                ) {
                    TerminalJumpers.jump(session.jumpTarget)
                }
            }
        }
        .padding(4)
    }

    /// Second line shown ONLY when it disambiguates — i.e. when another
    /// session shares this one's project label. Two identical "p2-marketplace"
    /// rows are the overlay's worst failure mode; a lone session needs no
    /// extra chrome. The detail is built from what actually differs:
    /// the parent directory when the labels collide across different paths,
    /// otherwise the tool plus the tty (two panes in the same project).
    private func detail(for session: Session, among sessions: [Session]) -> String? {
        let twins = sessions.filter { $0.label == session.label }
        guard twins.count > 1 else { return nil }

        var parts: [String] = []
        if Set(twins.map { $0.cwd ?? "" }).count > 1, let cwd = session.cwd {
            let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty { parts.append(parent + "/") }
        }
        parts.append(session.tool.display)
        if let tty = session.tty, !tty.isEmpty {
            parts.append((tty as NSString).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Overlay row

/// The overlay's own row. It used to share `SessionRow` with the menu via a
/// `context` switch, but the two surfaces have genuinely diverged: the menu
/// wants a roomy, always-detailed row with a jump affordance; the overlay
/// wants maximum name legibility in minimum chrome (no tool glyph, no jump
/// glyph — the whole row is the button and the hover highlight says so).
/// Forcing both through one view meant every overlay decision risked the
/// menu, so the shared row now belongs to the menu alone.
private struct OverlaySessionRow: View {
    let session: Session
    /// Disambiguating second line, or nil when the project name alone is
    /// unique (the common case — keeps rows single-line and the panel short).
    let detail: String?
    /// Injected by the enclosing `TimelineView` so elapsed labels refresh.
    let now: Date
    let onSelect: () -> Void

    @State private var isHovering = false

    private var needsInput: Bool { session.status == .waitingApproval }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.label)
                        .font(.callout)
                        .fontWeight(needsInput ? .medium : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                // Elapsed time is the cheapest strong discriminator between
                // rows ("2m" vs "1h") and doubles as a liveness cue.
                Text(elapsedLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                // The red "needs input" state is the one the user must act
                // on, so it gets standing visual weight (a soft semantic
                // tint), not just a 7-pt dot.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(needsInput ? AnyShapeStyle(.red.opacity(0.14)) : AnyShapeStyle(.clear))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary)
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Jump to this session's pane")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // Traffic-light: green working, yellow idle/finished-turn, red needs your
    // input now. Yellow (not orange) to match the shipped menu-bar icon.
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

    private var elapsedMinutes: Int {
        Int(max(0, now.timeIntervalSince(session.lastUpdate)) / 60)
    }

    private var elapsedLabel: String {
        let minutes = elapsedMinutes
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    /// The tool no longer has a visible glyph on the row, so it must stay in
    /// the accessibility label — VoiceOver users get strictly more than the
    /// visual layout shows, never less.
    private var accessibilityLabel: String {
        var label = "\(session.label), \(session.tool.display), \(statusLabel)"
        let minutes = elapsedMinutes
        if minutes < 1 {
            label += ", updated just now"
        } else if minutes < 60 {
            label += ", updated \(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else {
            let hours = minutes / 60
            label += ", updated \(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        return label
    }
}

// MARK: - Previews
//
// Preview-only scaffolding, never compiled into release.

#if DEBUG
private func overlaySample(
    id: String,
    tool: AgentTool,
    status: SessionStatus,
    cwd: String,
    tty: String?,
    minutesAgo: Double
) -> Session {
    Session(
        id: id,
        tool: tool,
        status: status,
        cwd: cwd,
        tty: tty,
        lastUpdate: Date().addingTimeInterval(-minutesAgo * 60)
    )
}

#Preview("Overlay — sessions") {
    OverlayView(store: .previewStore([
        // Two sessions in the SAME project — the detail line must appear.
        overlaySample(id: "b", tool: .claude, status: .working,
                      cwd: "/Users/alfonso/Developer/p2-marketplace", tty: "/dev/ttys004", minutesAgo: 2),
        overlaySample(id: "a", tool: .codex, status: .waitingApproval,
                      cwd: "/Users/alfonso/Developer/p2-marketplace", tty: "/dev/ttys009", minutesAgo: 75),
        // A lone session — single line, no detail.
        overlaySample(id: "c", tool: .claude, status: .idle,
                      cwd: "/Users/alfonso/Developer/Tools/ai-sessions", tty: "/dev/ttys012", minutesAgo: 14),
    ]))
    .padding(40)
}

#Preview("Overlay — empty") {
    OverlayView(store: .previewStore([]))
        .padding(40)
}
#endif
