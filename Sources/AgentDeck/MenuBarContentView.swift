import AppKit
import SwiftUI

// MARK: - Menu-bar dropdown
//
// The SwiftUI content rendered inside the `MenuBarExtra` (window style) that
// replaced the legacy NSMenu built by MenuBarController. Wired to the live
// SessionStore, overlay controller, stay-awake controller, and the settings /
// Sparkle / uninstall actions.
//
// Note on "Uninstall lil agents…": in the old NSMenu it sat directly above
// "Quit lil agents", a classic accident-prone layout — a destructive,
// irreversible action one slightly-off click from the most-used item. It is
// slated to move into the Settings window (see the TODO below); until then it
// lives here, isolated from Quit by a divider so the two are never adjacent.

/// Menu-bar dropdown content. Renders a fixed-width, vertically stacked menu
/// with aligned icon columns, richer session rows, and clearer on/off
/// affordances than the legacy NSMenu.
struct MenuBarContentView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var awake: StayAwakeController
    @ObservedObject var overlay: OverlayController

    /// Opens the existing AppKit Settings window (SettingsWindowController).
    let onOpenSettings: () -> Void
    /// Triggers the same Sparkle "Check for Updates…" action the old menu used.
    let onCheckForUpdates: () -> Void

    private var activeCount: Int { store.sessions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.vertical, 4)

            sessionsSection

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                // Title/icon reflect current overlay visibility. "⌥⌘J" is
                // display TEXT ONLY — no real .keyboardShortcut: the global
                // Carbon hotkey already toggles the overlay, and a functional
                // key equivalent here would fire a SECOND toggle.
                MenuRow(
                    icon: overlay.isVisible ? "eye.slash" : "eye",
                    title: overlay.isVisible ? "Hide overlay" : "Show overlay",
                    trailing: "⌥⌘J"
                ) { overlay.toggle() }

                // Real Toggle bound through the controller's own toggle() so the
                // sudoers prompt / battery-floor guards behave exactly as before.
                StayAwakeRow(isOn: Binding(
                    get: { awake.isAwake },
                    set: { _ in awake.toggle() }
                ))
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                MenuRow(icon: "gearshape", title: "Settings…", trailing: "⌘,") {
                    onOpenSettings()
                }
                MenuRow(icon: "arrow.down.circle", title: "Check for Updates…", trailing: nil) {
                    onCheckForUpdates()
                }
            }

            Divider()
                .padding(.vertical, 4)

            // TODO(phase-5): move into Settings. Temporary row so Uninstall stays
            // reachable now that the old NSMenu that hosted it is gone. Isolated
            // from Quit by the divider below so the destructive action is never
            // adjacent to the most-used item.
            MenuRow(icon: "trash", title: "Uninstall lil agents…", trailing: nil) {
                Uninstaller.promptAndUninstall()
            }

            Divider()
                .padding(.vertical, 4)

            // MUST be NSApp.terminate(nil): only applicationWillTerminate reverts
            // the kernel SleepDisabled flag. Never exit()/NSApplication.stop.
            MenuRow(icon: "power", title: "Quit lil agents", trailing: "⌘Q") {
                NSApp.terminate(nil)
            }
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
        if store.sessions.isEmpty {
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
                ForEach(store.sessions) { session in
                    SessionRow(session: session, context: .menu)
                }
            }
        }
    }
}

// MARK: - Status-item label

/// The `MenuBarExtra` label. Observes the store and stay-awake controller and
/// renders the exact status-item pixels AppKit used, via AttentionIcon.
/// `.renderingMode(.original)` keeps the traffic-light tint (a template image
/// would be recolored by the menu bar). Falls back to a plain SF Symbol if the
/// NSImage is ever nil.
struct StatusIconLabel: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var awake: StayAwakeController

    var body: some View {
        if let image = AttentionIcon.image(attention: store.attention, isAwake: awake.isAwake) {
            Image(nsImage: image)
                .renderingMode(.original)
        } else {
            Image(systemName: store.attention.symbolName)
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

// MARK: - Previews
//
// Preview-only scaffolding: sample data and the #Preview blocks below are
// wrapped in #if DEBUG so they never ship in a release build.

#if DEBUG
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

@MainActor
private func previewMenu(sessions: [Session], awake: Bool) -> some View {
    let store = SessionStore.previewStore(sessions)
    let stayAwake = StayAwakeController()
    let overlay = OverlayController(store: store)
    return MenuBarContentView(
        store: store,
        awake: stayAwake,
        overlay: overlay,
        onOpenSettings: {},
        onCheckForUpdates: {}
    )
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(20)
}

#Preview("Menu — with sessions") {
    previewMenu(
        sessions: [
            .sample(id: "1", tool: .claude, status: .working, project: "ai-sessions", minutesAgo: 2),
            .sample(id: "2", tool: .codex, status: .idle, project: "wandity-site", minutesAgo: 14),
            .sample(id: "3", tool: .claude, status: .waitingApproval, project: "menu-redesign", minutesAgo: 1),
        ],
        awake: true
    )
}

#Preview("Menu — empty state") {
    previewMenu(sessions: [], awake: false)
}
#endif
