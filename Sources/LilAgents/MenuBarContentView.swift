import AppKit
import SwiftUI

// MARK: - Menu-bar dropdown
//
// The SwiftUI content rendered inside the `MenuBarExtra` (window style) that
// replaced the legacy NSStatusItem/NSMenu implementation. Wired to the live
// SessionStore, overlay controller, stay-awake controller, and the settings /
// Sparkle actions.
//
// The destructive "Uninstall lil agents…" action used to live here (isolated
// from Quit by a divider); it has since moved into the Settings scene, behind a
// native confirmation dialog, so it's no longer one slightly-off click from the
// most-used item.

/// Menu-bar dropdown content. Renders a fixed-width, vertically stacked menu
/// with aligned icon columns, richer session rows, and clearer on/off
/// affordances than the legacy NSMenu.
struct MenuBarContentView: View {
    let store: SessionStore
    let awake: StayAwakeController
    let overlay: OverlayController
    /// Claude/Codex/Grok usage state, rendered as `UsageMenuSection` between
    /// the header and the session list, and refreshed (throttled) whenever
    /// the dropdown appears.
    let usage: UsageStore
    let settings: AppSettings
    @ObservedObject var updater: UpdaterController

    /// Flips activation policy so the `Settings` scene comes frontmost with a
    /// menu bar when opened, and reverts on close.
    let activationPolicy: ActivationPolicyController

    /// SwiftUI's native action to open the `Settings` scene. Paired with
    /// `activationPolicy` so the window actually gets focus in this accessory app.
    @Environment(\.openSettings) private var openSettings

    /// Closes the `MenuBarExtra` panel. Spike-verified to work for the
    /// `.window` menu-bar style. Called after every action that navigates
    /// away or opens something else, EXCEPT the stay-awake toggle — flipping
    /// a toggle and having the panel vanish out from under you is hostile;
    /// users often toggle and glance at the resulting state.
    @Environment(\.dismiss) private var dismiss

    private var activeCount: Int { store.sessions.count }

    /// Roughly seven session rows (~43pt each). Chosen so the whole dropdown —
    /// header, usage section, list, and the fixed actions below it — still fits
    /// on a 13" display's visible height with room to spare, rather than
    /// scaling to the screen: a menu whose length changes with the monitor it
    /// opens on is harder to build muscle memory for than one that doesn't.
    private static let maxSessionListHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.vertical, 4)

            // Renders EmptyView (and adds no divider of its own) when all
            // three providers are disabled — see UsageMenuSection's doc comment.
            UsageMenuSection(usage: usage)

            if settings.sessionsEnabled {
                sessionsSection

                Divider()
                    .padding(.vertical, 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Title/icon reflect current overlay visibility. "⌥⌘J" is
                // display TEXT ONLY — no real .keyboardShortcut: the global
                // Carbon hotkey already toggles the overlay, and a functional
                // key equivalent here would fire a SECOND toggle.
                if settings.sessionsEnabled {
                    MenuRow(
                        icon: overlay.isVisible ? "eye.slash" : "eye",
                        title: overlay.isVisible ? "Hide overlay" : "Show overlay",
                        trailing: "⌥⌘J"
                    ) {
                        overlay.toggle()
                        dismiss()
                    }
                }

                // Real Toggle bound through the controller's own toggle() so the
                // sudoers prompt / battery-floor guards behave exactly as before.
                // Deliberately does NOT dismiss: flipping a toggle and having the
                // panel vanish out from under you is hostile — people toggle this
                // and want to glance at the resulting state.
                StayAwakeRow(isOn: Binding(
                    get: { awake.isAwake },
                    set: { _ in awake.toggle() }
                ))
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                MenuRow(icon: "gearshape", title: "Settings…", trailing: "⌘,") {
                    dismiss()
                    activationPolicy.openSettings(openSettings)
                }
                .keyboardShortcut(",", modifiers: .command)

                // Sparkle can't validate an NSMenuItem's enabled state for us
                // under MenuBarExtra, so canCheckForUpdates (bridged from
                // SPUUpdater via Combine in UpdaterController) drives it here.
                MenuRow(icon: "arrow.down.circle", title: "Check for Updates…", trailing: nil) {
                    dismiss()
                    updater.controller.checkForUpdates(nil)
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Divider()
                .padding(.vertical, 4)

            // MUST be NSApp.terminate(nil): only applicationWillTerminate reverts
            // the kernel SleepDisabled flag. Never exit()/NSApplication.stop.
            // No dismiss needed — the process exits.
            MenuRow(icon: "power", title: "Quit lil agents", trailing: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 280)
        .onAppear { usage.refreshIfStale() }
    }

    private var header: some View {
        HStack {
            Text("lil agents")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if settings.sessionsEnabled {
                Text("\(activeCount) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(activeCount) active session\(activeCount == 1 ? "" : "s")")
            }
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
            // Capped and scrollable: the list grew without limit, so running a
            // dozen agents pushed Settings and Quit off the bottom of the
            // screen with no way to reach them. The list is the only part that
            // may overflow — everything below it must stay on screen.
            ContentSizedScrollView(maxHeight: Self.maxSessionListHeight) {
                VStack(spacing: 2) {
                    // Same stable project ordering as the overlay (displayOrdered,
                    // defined in OverlayView.swift) so the two surfaces agree and
                    // the user's spatial memory transfers between them. Status is
                    // still obvious per-row via the dot and the detail line.
                    ForEach(store.sessions.displayOrdered) { session in
                        SessionRow(session: session) {
                            TerminalJumpers.jump(session.jumpTarget)
                            dismiss()
                        } onRemove: {
                            store.remove(session.id)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Status-item label

/// The `MenuBarExtra` label. Observes the store, stay-awake controller,
/// usage store, and session-tracking flag: the attention dot plus, when at
/// least one usage provider is enabled, two stacked mini-rows of symbol +
/// percent beside it. When tracking is off the attention dot is omitted so
/// usage-only mode is just the gauges (stay-awake still shows the bolt).
///
/// The attention image renders via AttentionIcon with
/// `.renderingMode(.original)` to keep its traffic-light tint (a template
/// image would be recolored by the menu bar), falling back to a plain SF
/// Symbol if the NSImage is ever nil.
///
/// When usage tracking is enabled the whole label — attention icon plus the
/// two usage mini-rows — is composited into ONE bitmap by
/// `UsageMenuBarIcon.labelImage` (see that type for why: the label flattens
/// native SwiftUI stacks and won't render drawingHandler/template images, so
/// a single eagerly-rasterized `Image(nsImage:)` — the exact pattern the
/// attention icon already ships — is the only reliable vehicle). The
/// `colorScheme` environment drives the explicit white/black paint and
/// re-renders the label when the system appearance flips.
struct StatusIconLabel: View {
    let store: SessionStore
    let awake: StayAwakeController
    let usage: UsageStore
    let settings: AppSettings

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !usageRows.isEmpty,
           let composite = UsageMenuBarIcon.labelImage(
               attention: sessionGlyph,
               rows: menuBarIconRows,
               darkAppearance: colorScheme == .dark
           ) {
            Image(nsImage: composite)
                .renderingMode(.original)
        } else {
            attentionImage
        }
    }

    /// Traffic-light / stay-awake mark. Omitted when session tracking is off
    /// (unless stay-awake is on) so usage-only mode is just the gauges.
    private var sessionGlyph: NSImage? {
        if settings.sessionsEnabled {
            return AttentionIcon.image(attention: store.attention, isAwake: awake.isAwake)
        }
        guard awake.isAwake else { return nil }
        return AttentionIcon.image(attention: .none, isAwake: true)
    }

    /// Usage disabled (or composite construction failed): today's exact
    /// pre-feature appearance, untouched.
    @ViewBuilder
    private var attentionImage: some View {
        if let image = AttentionIcon.image(attention: store.attention, isAwake: awake.isAwake) {
            Image(nsImage: image)
                .renderingMode(.original)
        } else {
            Image(systemName: store.attention.symbolName)
        }
    }

    /// Each enabled provider contributes its weekly percent (Claude's 5-hour
    /// window stays in the dropdown/overlay). A `.disabled` provider
    /// contributes no row at all. The raw percent rides along beside the
    /// formatted text so the bitmap can pick the row's urgency tint
    /// (UsageMenuBarIcon).
    private var usageRows: [UsageMenuBarIcon.Row] {
        var rows: [UsageMenuBarIcon.Row] = []
        if usage.claude != .disabled {
            let percent = usage.claude.usage?.weekly?.percent
            rows.append(UsageMenuBarIcon.Row(
                symbolName: AgentTool.claude.symbol,
                logoImage: AgentTool.claude.logoImage,
                text: UsageFormatting.percentLabel(percent),
                percent: percent,
                dimmed: usage.claude.isDimmed
            ))
        }
        if usage.codex != .disabled {
            let percent = usage.codex.usage?.weekly?.percent
            rows.append(UsageMenuBarIcon.Row(
                symbolName: AgentTool.codex.symbol,
                logoImage: AgentTool.codex.logoImage,
                text: UsageFormatting.percentLabel(percent),
                percent: percent,
                dimmed: usage.codex.isDimmed
            ))
        }
        if usage.grok != .disabled {
            let percent = usage.grok.usage?.weekly?.percent
            rows.append(UsageMenuBarIcon.Row(
                symbolName: AgentTool.grok.symbol,
                logoImage: AgentTool.grok.logoImage,
                text: UsageFormatting.percentLabel(percent),
                percent: percent,
                dimmed: usage.grok.isDimmed
            ))
        }
        return rows
    }

    /// Menu bar bitmap is 21pt and only designed for 1–2 rows; keep the two highest percents (nil last).
    private var menuBarIconRows: [UsageMenuBarIcon.Row] {
        let rows = usageRows
        guard rows.count > 2 else { return rows }
        return Array(rows.sorted { ($0.percent ?? -1) > ($1.percent ?? -1) }.prefix(2))
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
                        // Shortcut hint glyphs (e.g. "⌥⌘J", "⌘,") read as noise
                        // through VoiceOver — the row's own accessibilityLabel
                        // below already conveys the action; hide the redundant
                        // (and, for "⌥⌘J", non-functional) trailing text.
                        .accessibilityHidden(true)
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
        .accessibilityLabel(title)
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
                // Toggle already reports its on/off state to VoiceOver; the
                // missing piece is what it DOES — `labelsHidden()` above
                // strips the visible text from the accessibility tree too,
                // so spell it out explicitly here.
                .accessibilityLabel("Stay awake while lid is closed")
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
            cwd: "/Users/dev/Projects/\(project)",
            tty: nil,
            lastUpdate: Date().addingTimeInterval(-minutesAgo * 60)
        )
    }
}

/// Sample usage: both providers enabled and available, so the preview shows
/// `UsageMenuSection`'s full detail (percent + reset time per window).
@MainActor
private func previewUsageStore() -> UsageStore {
    .previewStore(
        claude: .available(ProviderUsage(
            session: UsageWindow(percent: 62, resetsAt: Date().addingTimeInterval(3 * 3600)),
            weekly: UsageWindow(percent: 41, resetsAt: Date().addingTimeInterval(4 * 86400)),
            fetchedAt: Date()
        )),
        codex: .available(ProviderUsage(
            session: nil,
            weekly: UsageWindow(percent: 30, resetsAt: Date().addingTimeInterval(2 * 86400)),
            fetchedAt: Date()
        ))
    )
}

@MainActor
private func previewMenu(sessions: [Session], awake: Bool) -> some View {
    let store = SessionStore.previewStore(sessions)
    let stayAwake = StayAwakeController()
    let usage = previewUsageStore()
    let overlay = OverlayController(store: store, usage: usage)
    let updater = UpdaterController()
    return MenuBarContentView(
        store: store,
        awake: stayAwake,
        overlay: overlay,
        usage: usage,
        settings: AppSettings(),
        updater: updater,
        activationPolicy: ActivationPolicyController()
    )
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(20)
}

#Preview("Menu — with sessions") {
    previewMenu(
        sessions: [
            .sample(id: "1", tool: .claude, status: .working, project: "marketplace", minutesAgo: 2),
            .sample(id: "2", tool: .codex, status: .idle, project: "docs", minutesAgo: 14),
            .sample(id: "3", tool: .claude, status: .waitingApproval, project: "tools", minutesAgo: 1),
        ],
        awake: true
    )
}

#Preview("Menu — empty state") {
    previewMenu(sessions: [], awake: false)
}
#endif
