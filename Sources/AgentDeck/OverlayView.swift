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
/// Design: minimal at rest, detail on intent (hover).
/// - At rest every row is ONE line — status dot + project name. That's the
///   overlay's whole resting job: which projects, what state. Elapsed time
///   and the duplicate-disambiguation detail are hover-revealed, so the
///   panel carries no reserved trailing column and no second lines.
/// - Hovering a row reveals a trailing caption (tool/tty/elapsed) INSIDE the
///   row's fixed bounds: the name yields width by truncating further, but the
///   row height, the other rows, and the panel frame never move. No layout
///   shift under the cursor, ever — the panel is an NSPanel sized by its
///   hosting view, so any hover-driven resize would wobble the whole window.
/// - The red needs-input state stays loud at rest (tint + dot + weight);
///   urgency is never hover-gated.
///
/// Layout decisions, deliberately:
/// - Fixed width (not intrinsic): project names get room and truncate at the
///   END (`ai-sessions…`), never mid-string garbage (`ai-s…ons`), and the
///   panel footprint stays predictable instead of breathing as text changes.
///   With the trailing elapsed column gone, 180 pt gives names MORE room
///   than the old 240 pt layout did.
/// - Rows are ordered by project (see `displayOrdered`), not by status, so
///   they never reshuffle under the cursor.
/// - Liquid Glass (`glassEffect`, regular variant), not `.ultraThinMaterial`:
///   on macOS 26 glass is the prescribed surface for exactly this kind of
///   element — an interactive control layer floating above content (HIG
///   "Materials": glass "forms a distinct functional layer for controls and
///   navigation elements … that floats above the content layer"; standard
///   materials are for differentiation *within* an app's content layer,
///   which this panel is not). The regular variant, not `.clear`, because
///   the panel is text-heavy and must stay legible over arbitrary desktop
///   content; `.clear` is reserved for chrome over media. No hairline
///   stroke: glass draws its own lensing rim, and a stroked border on top
///   reads as pre-26 chrome. One glass sheet only — rows use plain
///   color/vibrancy fills, never a second glass layer (glass-on-glass is
///   explicitly discouraged). The system swaps in a frosted fallback under
///   Reduce Transparency and when the window is inactive; both are native
///   behavior, not ours to re-implement.
/// - Elapsed time is wrapped in a per-minute `TimelineView` so "5m" stays
///   honest without the store having to publish anything.
struct OverlayView: View {
    let store: SessionStore
    /// Claude/Codex usage state, rendered as `OverlayUsageHeader` above the
    /// session list (and above `emptyHint`) — see that type for the
    /// disabled/dimmed rules. Plain fills only inside the header; the single
    /// `.glassEffect` below stays the panel's only glass layer.
    let usage: UsageStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(spacing: 0) {
                OverlayUsageHeader(usage: usage)
                Group {
                    if store.sessions.isEmpty {
                        emptyHint
                    } else {
                        sessionList(now: timeline.date)
                    }
                }
            }
        }
        .frame(width: 180)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// Disambiguating detail, built ONLY when another session shares this
    /// one's project label. It used to be a permanent second line; it is now
    /// hover-revealed, which collapses duplicates to one line at rest. The
    /// accepted rest-state ambiguity: two same-project rows are told apart by
    /// dot color and stable order alone — and since they ARE the same project,
    /// a glance rarely needs more; the tty matters only when jumping, which is
    /// exactly when the cursor is already on the row. The detail is built from
    /// what actually differs: the parent directory when the labels collide
    /// across different paths, otherwise the tool plus the tty (two panes in
    /// the same project).
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
///
/// Rest vs hover:
/// - Rest: dot + name. One line, fixed height.
/// - Hover: a trailing caption fades in — the duplicate-disambiguation
///   detail (or the tool name for unique rows) plus elapsed time when it's
///   ≥ 1 minute ("now" carried nothing and is simply suppressed). The
///   caption takes layout priority, so the NAME truncates to make room —
///   safe, because by the time the user hovers they've already read the
///   name; the reveal answers the follow-up questions (which pane? how
///   long?). Nothing outside the row's fixed bounds changes.
private struct OverlaySessionRow: View {
    let session: Session
    /// Disambiguating hover detail, or nil when the project name alone is
    /// unique (the common case — hover then shows tool + elapsed instead).
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

                Text(session.label)
                    .font(.callout)
                    .fontWeight(needsInput ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if isHovering {
                    Text(hoverDetail)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // The reveal wins the width fight; the name truncates.
                        .layoutPriority(1)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            // Pin the row height: the hover caption swaps in WITHIN these
            // bounds, so neither this row nor its neighbors can ever reflow
            // under the cursor.
            .frame(height: 26)
            .background {
                // The red "needs input" state is the one the user must act
                // on, so it gets standing visual weight (a soft semantic
                // tint), not just a 7-pt dot — never hover-gated.
                //
                // Radius 8 = the panel's 12 minus the 4-pt list padding, so
                // row highlights nest concentrically inside the glass shape
                // (the macOS 26 corner idiom). Plain fills, deliberately:
                // a second glassEffect here would stack glass on glass.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(needsInput ? AnyShapeStyle(.red.opacity(0.14)) : AnyShapeStyle(.clear))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Jump to this session's pane")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// What hover reveals, inside the row's own bounds. Duplicates show their
    /// disambiguator (parent dir / tool / tty); unique rows show the tool, so
    /// the reveal is never empty. Elapsed time joins from 1 minute up.
    private var hoverDetail: String {
        var parts: [String] = [detail ?? session.tool.display]
        if elapsedMinutes >= 1 { parts.append(elapsedLabel) }
        return parts.joined(separator: " · ")
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
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    /// Everything the eye can only get by hovering — tool, tty/parent-dir
    /// disambiguator, elapsed — must live here permanently: VoiceOver has no
    /// hover, so the label carries strictly MORE than the resting visuals,
    /// never less.
    private var accessibilityLabel: String {
        let spoken = (detail ?? session.tool.display)
            .replacingOccurrences(of: " · ", with: ", ")
        var label = "\(session.label), \(spoken), \(statusLabel)"
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

/// A loud multi-stop backdrop standing in for "arbitrary desktop content":
/// glass is invisible over a flat preview canvas, and its whole legibility
/// question — regular-variant blur keeping `.primary`/`.secondary` readable —
/// only shows up over something busy.
private struct PreviewDesktopBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [.indigo, .teal, .orange, .pink],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

/// Sample usage: both providers enabled and available, matching the feature
/// plan's own example row ("✳ 95%  ⬡ 15%").
@MainActor
private func previewUsageStore() -> UsageStore {
    .previewStore(
        claude: .available(ProviderUsage(
            session: UsageWindow(percent: 95, resetsAt: Date().addingTimeInterval(3 * 3600)),
            weekly: UsageWindow(percent: 41, resetsAt: Date().addingTimeInterval(4 * 86400)),
            fetchedAt: Date()
        )),
        codex: .available(ProviderUsage(
            session: nil,
            weekly: UsageWindow(percent: 15, resetsAt: Date().addingTimeInterval(2 * 86400)),
            fetchedAt: Date()
        ))
    )
}

#Preview("Overlay — sessions") {
    OverlayView(
        store: .previewStore([
            // Two sessions in the SAME project — one line each at rest; the
            // disambiguating detail (tool · tty) only appears on hover.
            overlaySample(id: "b", tool: .claude, status: .working,
                          cwd: "/Users/alfonso/Developer/p2-marketplace", tty: "/dev/ttys004", minutesAgo: 2),
            overlaySample(id: "a", tool: .codex, status: .waitingApproval,
                          cwd: "/Users/alfonso/Developer/p2-marketplace", tty: "/dev/ttys009", minutesAgo: 75),
            // A lone session — hover shows tool + elapsed.
            overlaySample(id: "c", tool: .claude, status: .idle,
                          cwd: "/Users/alfonso/Developer/Tools/ai-sessions", tty: "/dev/ttys012", minutesAgo: 14),
            // A fresh lone session — hover shows just the tool ("now" suppressed).
            overlaySample(id: "d", tool: .codex, status: .working,
                          cwd: "/Users/alfonso/Developer/wandity-site", tty: "/dev/ttys015", minutesAgo: 0),
        ]),
        usage: previewUsageStore()
    )
    .padding(40)
    .background(PreviewDesktopBackdrop())
}

#Preview("Overlay — empty") {
    OverlayView(store: .previewStore([]), usage: previewUsageStore())
        .padding(40)
        .background(PreviewDesktopBackdrop())
}

#Preview("Overlay — empty, usage disabled") {
    OverlayView(store: .previewStore([]), usage: .previewStore())
        .padding(40)
        .background(PreviewDesktopBackdrop())
}
#endif
