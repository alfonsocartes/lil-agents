import SwiftUI

/// The menu-bar dropdown's usage section: one non-interactive row per enabled
/// provider, styled to match `MenuRow`'s 18pt fixed icon column
/// (MenuBarContentView.swift) but with no `Button`/hover — there's nothing to
/// click here, just numbers to read.
///
/// Each row is the provider title followed by one gauge line per usage
/// window: a short window label ("5h"/"week"), a slim fixed-width capacity
/// gauge (`UsageGauge` — fixed so bars form an aligned column across rows,
/// exactly like `MenuRow`'s fixed icon column aligns labels), the percent in
/// monospaced digits, and the reset time pushed to the trailing edge as a
/// secondary caption — deliberately the same "trailing quiet caption" idiom
/// as `MenuRow`'s shortcut hints ("⌘,"), because a reset time is the same
/// class of information: useful, never primary. Urgency (>= 75% amber,
/// >= 90% red, via `UsageUrgency`) tints the gauge fill and the percent;
/// everything else stays monochrome.
///
/// Includes its own trailing `Divider` so callers (MenuBarContentView) can
/// insert this section as a single unit; renders `EmptyView` — no rows, no
/// divider — when both providers are `.disabled`, the default until the user
/// opts in via Settings.
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
                        state: usage.claude,
                        provider: .claude
                    )
                }
                if usage.codex != .disabled {
                    row(
                        symbolName: AgentTool.codex.symbol,
                        title: "Codex",
                        state: usage.codex,
                        provider: .codex
                    )
                }

                Divider()
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Row

    /// Column metrics for the window gauge lines, chosen so all four columns
    /// (label / gauge / percent / reset) align across every line of every
    /// row — misaligned bars would read as sloppier than no bars at all.
    private enum Metrics {
        /// Fits "week", the longest window label, at `.caption`.
        static let windowLabelWidth: CGFloat = 30
        /// Fixed gauge track. Long enough that 75% vs 90% is visibly
        /// different territory, and — the binding constraint — short enough
        /// that the WORST-CASE reset caption ("resets Wed 12 PM") always
        /// renders whole in the 280pt menu: the reset time is a datum users
        /// plan around, so it must never truncate (see `windowLine`). 40pt
        /// leaves the trailing caption ~100pt of guaranteed room.
        static let gaugeWidth: CGFloat = 40
        /// Hairline-plus: visible fill, but clearly an accent under the
        /// caption text, not a chart.
        static let gaugeHeight: CGFloat = 3
        /// Fits "100%" at `.caption` with monospaced digits, trailing
        /// aligned so units line up down the column.
        static let percentWidth: CGFloat = 32
    }

    private func row(
        symbolName: String,
        title: String,
        state: ProviderUsageState,
        provider: Provider
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                content(for: state, provider: provider)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        // Same "recede, don't disappear" treatment as OverlayUsageHeader:
        // stale/loading/unavailable data dims the whole row rather than
        // hiding it — there's still a last-known number (or an explanatory
        // caption) worth reading. Urgency tints survive the dip: a dimmed
        // amber still reads amber, just quieter.
        .opacity(state.isDimmed ? 0.6 : 1)
    }

    /// One gauge line per window when there's data to show (`.available`/
    /// `.stale`/`.loading`, the last rendering "--" + track-only gauges); a
    /// single explanatory caption instead when the provider has never
    /// succeeded this launch (`.unavailable`) — there's nothing numeric to
    /// pair a gauge with. `.disabled` never reaches here (the row is
    /// omitted).
    @ViewBuilder
    private func content(for state: ProviderUsageState, provider: Provider) -> some View {
        switch state {
        case .disabled:
            EmptyView()
        case .unavailable(let error):
            Text(errorCaption(error, provider: provider))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loading, .available, .stale:
            let now = Date()
            switch provider {
            case .claude:
                windowLine(label: "5h", window: state.usage?.session, now: now)
                windowLine(label: "week", window: state.usage?.weekly, now: now)
            case .codex:
                windowLine(label: "week", window: state.usage?.weekly, now: now)
            }
        }
    }

    /// One window's gauge line. The percent inherits the urgency tint (or
    /// stays `.primary` at normal usage — it's the row's actual datum, so it
    /// gets full contrast); the reset caption is `.secondary` and
    /// right-aligned, receding the way secondary information should.
    private func windowLine(label: String, window: UsageWindow?, now: Date) -> some View {
        let urgency = UsageUrgency(percent: window?.percent)
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.windowLabelWidth, alignment: .leading)
            UsageGauge(percent: window?.percent)
                .frame(width: Metrics.gaugeWidth, height: Metrics.gaugeHeight)
            Text(UsageFormatting.percentLabel(window?.percent))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(urgency.tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: Metrics.percentWidth, alignment: .trailing)
            Spacer(minLength: 4)
            Text(UsageFormatting.resetLabel(for: window?.resetsAt, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                // The reset time must NEVER truncate — "resets Sun…" is
                // worse than useless, and this caption is the one thing on
                // the line the user actually plans around. `fixedSize` +
                // top layout priority make it always render whole; the
                // Spacer absorbs the flex, and the gauge column was sized
                // down (Metrics.gaugeWidth) so the worst-case caption fits
                // the 280pt menu with room to spare.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }

    // MARK: - Caption text

    /// Which CLI a row belongs to — only used to pick the right window(s)
    /// and phrase the right sign-in hint; `UsageStore` itself has no such
    /// identity (see UsageProvider.swift's doc comment).
    private enum Provider {
        case claude
        case codex
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

/// The loud/degraded corner of the design: Claude burning through both
/// windows (red 5h gauge, amber weekly), Codex showing last-known data
/// dimmed by a stale fetch — checks that the urgency tints stay legible
/// through the 0.6 dim.
#Preview("Usage menu section — high usage & stale") {
    VStack(alignment: .leading, spacing: 0) {
        UsageMenuSection(usage: .previewStore(
            claude: .available(ProviderUsage(
                session: UsageWindow(percent: 92, resetsAt: Date().addingTimeInterval(1 * 3600)),
                weekly: UsageWindow(percent: 78, resetsAt: Date().addingTimeInterval(2 * 86400)),
                fetchedAt: Date()
            )),
            codex: .stale(
                ProviderUsage(
                    session: nil,
                    weekly: UsageWindow(percent: 95, resetsAt: Date().addingTimeInterval(3 * 86400)),
                    fetchedAt: Date().addingTimeInterval(-3600)
                ),
                .network("offline")
            )
        ))
    }
    .padding(20)
    .frame(width: 280)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
}
#endif
