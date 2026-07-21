import SwiftUI

/// The menu-bar dropdown's usage section: one non-interactive row per enabled
/// provider (title + caption detail lines), styled to match `MenuRow`'s 18pt
/// fixed icon column (MenuBarContentView.swift) but with no `Button`/hover —
/// there's nothing to click here, just numbers to read. Includes its own
/// trailing `Divider` so callers (MenuBarContentView) can insert this section
/// as a single unit; renders `EmptyView` — no rows, no divider — when both
/// providers are `.disabled`, the default until the user opts in via
/// Settings.
struct UsageMenuSection: View {
    let usage: UsageStore

    var body: some View {
        if usage.claude == .disabled && usage.codex == .disabled {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if usage.claude != .disabled {
                    row(
                        symbolName: AgentTool.claude.symbol,
                        title: "Claude",
                        captions: captions(for: usage.claude, provider: .claude),
                        dimmed: usage.claude.isDimmed
                    )
                }
                if usage.codex != .disabled {
                    row(
                        symbolName: AgentTool.codex.symbol,
                        title: "Codex",
                        captions: captions(for: usage.codex, provider: .codex),
                        dimmed: usage.codex.isDimmed
                    )
                }

                Divider()
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Row

    private func row(symbolName: String, title: String, captions: [String], dimmed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                ForEach(captions, id: \.self) { caption in
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        // Same "recede, don't disappear" treatment as OverlayUsageHeader:
        // stale/loading/unavailable data dims the whole row rather than
        // hiding it — there's still a last-known number (or an explanatory
        // caption) worth reading.
        .opacity(dimmed ? 0.6 : 1)
    }

    // MARK: - Caption text

    /// Which CLI a row belongs to — only used to pick the right window(s)
    /// and phrase the right sign-in hint; `UsageStore` itself has no such
    /// identity (see UsageProvider.swift's doc comment).
    private enum Provider {
        case claude
        case codex
    }

    /// One caption line per window when there's data to show (`.available`/
    /// `.stale`/`.loading`, the last case rendering "--" placeholders); a
    /// single explanatory caption instead when the provider has never
    /// succeeded this launch (`.unavailable`) — there's nothing numeric to
    /// pair it with. `.disabled` never reaches here (the row is omitted).
    private func captions(for state: ProviderUsageState, provider: Provider) -> [String] {
        switch state {
        case .disabled:
            return []
        case .unavailable(let error):
            return [errorCaption(error, provider: provider)]
        case .loading, .available, .stale:
            return windowCaptions(usage: state.usage, provider: provider)
        }
    }

    private func windowCaptions(usage: ProviderUsage?, provider: Provider) -> [String] {
        let now = Date()
        switch provider {
        case .claude:
            return [
                windowCaption(prefix: "5h", window: usage?.session, now: now),
                windowCaption(prefix: "week", window: usage?.weekly, now: now),
            ]
        case .codex:
            return [windowCaption(prefix: "week", window: usage?.weekly, now: now)]
        }
    }

    /// e.g. `"5h 62% · resets 3 PM"`, or just `"5h 62%"` when there's no
    /// reset date to report (`UsageFormatting.resetLabel` returns "" for a
    /// nil date).
    private func windowCaption(prefix: String, window: UsageWindow?, now: Date) -> String {
        let percent = UsageFormatting.percentLabel(window?.percent)
        let reset = UsageFormatting.resetLabel(for: window?.resetsAt, now: now)
        guard !reset.isEmpty else { return "\(prefix) \(percent)" }
        return "\(prefix) \(percent) · \(reset)"
    }

    /// v1 is strictly read-only (see the feature plan) — every error state
    /// maps to "go run the CLI", never "retry" language, except the generic
    /// catch-all for transient failures (rate limiting, transport, bad
    /// response) that aren't worth explaining in one caption line.
    private func errorCaption(_ error: UsageFetchError, provider: Provider) -> String {
        let cli: String
        switch provider {
        case .claude: cli = "claude"
        case .codex: cli = "codex"
        }
        switch error {
        case .credentialsMissing:
            return "Sign in with `\(cli)` to see usage"
        case .tokenExpired:
            return "Token expired — run \(cli)"
        case .rateLimited, .network, .badResponse:
            return "Usage unavailable"
        }
    }
}

#if DEBUG
#Preview("Usage menu section") {
    VStack(alignment: .leading, spacing: 0) {
        UsageMenuSection(usage: .previewStore(
            claude: .available(ProviderUsage(
                session: UsageWindow(percent: 62, resetsAt: Date().addingTimeInterval(3 * 3600)),
                weekly: UsageWindow(percent: 41, resetsAt: Date().addingTimeInterval(4 * 86400)),
                fetchedAt: Date()
            )),
            codex: .unavailable(.credentialsMissing)
        ))
    }
    .padding(20)
    .frame(width: 280)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
}
#endif
