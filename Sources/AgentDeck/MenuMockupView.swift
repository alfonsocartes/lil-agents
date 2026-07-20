#if DEBUG
import SwiftUI

// MARK: - Design mockup only
//
// This file is a SwiftUI redesign PROPOSAL for the menu-bar menu currently
// built as a plain NSMenu in MenuBarController.swift. It is not wired up to
// anything — it exists purely so the new layout can be reviewed (via the
// #Preview blocks below) before any of MenuBarController's NSMenu code is
// touched. Wrapped in #if DEBUG so it never ships in a release build.
//
// Note on "Uninstall lil agents…": intentionally NOT reproduced here. In the
// current menu it sits directly above "Quit lil agents ⌘Q", which is a
// classic accident-prone layout — a slightly-off click on a destructive,
// irreversible action right next to the most-used item in the menu. It
// belongs in the Settings window as an explicit, confirmed destructive
// action instead of a one-click menu-bar item.

/// Redesigned menu-bar dropdown content. Renders a fixed-width, vertically
/// stacked menu with aligned icon columns, richer session rows, and clearer
/// on/off affordances than the legacy NSMenu.
struct MenuMockupView: View {
    let sessions: [Session]
    @State private var stayAwakeEnabled: Bool

    init(sessions: [Session], stayAwakeEnabled: Bool = false) {
        self.sessions = sessions
        self._stayAwakeEnabled = State(initialValue: stayAwakeEnabled)
    }

    private var activeCount: Int { sessions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.vertical, 4)

            sessionsSection

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                MenuRow(icon: "eye.slash", title: "Hide overlay", trailing: "⌥⌘J") {}
                StayAwakeRow(isOn: $stayAwakeEnabled)
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                MenuRow(icon: "gearshape", title: "Settings…", trailing: "⌘,") {}
                MenuRow(icon: "arrow.down.circle", title: "Check for Updates…", trailing: nil) {}
            }

            Divider()
                .padding(.vertical, 4)

            MenuRow(icon: "power", title: "Quit lil agents", trailing: "⌘Q") {}
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Text("lil agents")
                .font(.headline)
            Spacer()
            Text("\(activeCount) active")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var sessionsSection: some View {
        if sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No active sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            VStack(spacing: 2) {
                ForEach(sessions) { session in
                    SessionRow(session: session, context: .menu)
                }
            }
        }
    }
}

// MARK: - Reusable rows

/// A single actionable menu row with a fixed-width leading icon column so
/// every row's label text lines up regardless of icon glyph width — the
/// biggest visual flaw in the current NSMenu, where only some items have
/// icons at all.
private struct MenuRow: View {
    let icon: String
    let title: String
    let trailing: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.body)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    }
}

/// "Stay awake" row — a real Toggle so the on/off state is visible at a
/// glance, instead of the legacy menu item whose checked state you have to
/// notice as a faint checkmark.
private struct StayAwakeRow: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .frame(width: 18, alignment: .center)
                .foregroundStyle(.secondary)
            Text("Stay awake (lid closed)")
                .font(.body)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

// MARK: - Sample data

private extension Session {
    static func sample(
        id: String,
        tool: AgentTool,
        status: SessionStatus,
        project: String,
        minutesAgo: Double
    ) -> Session {
        Session(
            id: id,
            tool: tool,
            status: status,
            cwd: "/Users/alfonso/Developer/\(project)",
            tty: nil,
            lastUpdate: Date().addingTimeInterval(-minutesAgo * 60)
        )
    }
}

// MARK: - Previews

#Preview("Menu — with sessions") {
    let sessions: [Session] = [
        .sample(id: "1", tool: .claude, status: .working, project: "ai-sessions", minutesAgo: 2),
        .sample(id: "2", tool: .codex, status: .idle, project: "wandity-site", minutesAgo: 14),
        .sample(id: "3", tool: .claude, status: .waitingApproval, project: "menu-redesign", minutesAgo: 1),
    ]

    MenuMockupView(sessions: sessions, stayAwakeEnabled: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(20)
}

#Preview("Menu — empty state") {
    MenuMockupView(sessions: [], stayAwakeEnabled: false)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(20)
}
#endif
