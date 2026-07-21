import SwiftUI

/// The overlay's usage header: ONE 26pt line above the session list, shared
/// by every enabled provider. Each provider renders a segment — glyph,
/// capacity gauge, percent — and the segments split the row's full width
/// equally: two providers get half each, a single provider stretches across
/// the whole row (no ghost space reserved for the disabled one). Claude
/// shows its 5-hour window, Codex its weekly — the user's explicit choice of
/// window per provider; see UsageModel.swift and the feature plan. Lives
/// inside the overlay's single glass sheet (OverlayView.swift): plain fills
/// only here, never a second `.glassEffect` — glass-on-glass is explicitly
/// discouraged.
///
/// Why one shared row (not one line per provider): the header must stay
/// subordinate to the session list, and two 26pt header lines pushed the
/// panel's actual content down a full row-height for what is ambient
/// information. Splitting one line keeps the vertical budget constant while
/// the flexing gauges still use every point of the 180pt width — each
/// segment's gauge absorbs its share's slack, so the bars remain genuine
/// "how much is left" instruments rather than fixed micro-ornaments.
///
/// Designed to sit in the panel's rhythm rather than float above it:
/// - Same 26pt height as `OverlaySessionRow`, so the header reads as "row
///   zero" of the panel instead of a bolted-on strip.
/// - Content inset 12pt = the session rows' effective inset (4pt list
///   padding + 8pt row padding), so the leading glyph sits on the same left
///   edge as the status dots below.
/// - Everything is `.caption` + `.secondary` — sessions are the overlay's
///   primary content and this header must stay quiet. The only color that
///   ever appears is the shared urgency language (`UsageUrgency`: amber
///   >= 75%, red >= 90%) on a gauge fill and its percent — the one thing
///   worth breaking the monochrome for.
///
/// Hidden entirely when both providers are `.disabled` (the default, opt-in
/// Settings toggles are off).
struct OverlayUsageHeader: View {
    let usage: UsageStore

    var body: some View {
        if usage.claude == .disabled && usage.codex == .disabled {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if usage.claude != .disabled {
                        segment(
                            symbolName: AgentTool.claude.symbol,
                            percent: usage.claude.usage?.session?.percent,
                            dimmed: usage.claude.isDimmed
                        )
                    }
                    if usage.codex != .disabled {
                        segment(
                            symbolName: AgentTool.codex.symbol,
                            percent: usage.codex.usage?.weekly?.percent,
                            dimmed: usage.codex.isDimmed
                        )
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                // Fixed height (matching OverlaySessionRow) instead of
                // vertical padding: the header can never change the panel's
                // frame as data arrives — same no-reflow discipline as the
                // rows' hover reveal.
                .frame(height: 26)

                Divider()
            }
        }
    }

    /// One provider's segment: glyph in a fixed column, gauge flexing to
    /// fill the segment's share of the row, percent right-aligned in a fixed
    /// "100%"-sized slot (monospaced digits) so the gauge's trailing edge —
    /// and therefore its fill geometry — never shifts as digits change in
    /// this always-on panel. `maxWidth: .infinity` is what makes the split
    /// adaptive: two segments divide the row equally, a lone segment takes
    /// it all. `dimmed` (stale/loading/unavailable data, per
    /// `ProviderUsageState.isDimmed`) applies an EXTRA 0.5 opacity on top of
    /// the already-secondary styling, so a provider that's currently failing
    /// visibly recedes without disappearing — there's still a last-known
    /// number (and gauge fill) to glance at. A nil percent renders "--"
    /// beside a track-only gauge: full geometry, no reflow when data
    /// arrives.
    private func segment(symbolName: String, percent: Double?, dimmed: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .frame(width: 12, alignment: .center)
            UsageGauge(percent: percent)
                .frame(height: 3)
            Text(UsageFormatting.percentLabel(percent))
                .foregroundStyle(
                    UsageUrgency(percent: percent).tint.map(AnyShapeStyle.init)
                        ?? AnyShapeStyle(.secondary)
                )
                .frame(width: 26, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .opacity(dimmed ? 0.5 : 1)
    }
}

#if DEBUG
#Preview("Overlay usage header — two providers") {
    VStack(spacing: 0) {
        OverlayUsageHeader(usage: .previewStore(
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
        ))
        Text("session list goes here")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
    }
    .frame(width: 180)
    // Plain background, not `.glassEffect` — this preview isolates the
    // header alone; the real glass sheet lives on OverlayView's root, and
    // this file must never introduce a second one.
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(40)
}

/// Single-provider mode: only Claude enabled — its segment stretches across
/// the full row, no ghost space reserved for the missing Codex half.
#Preview("Overlay usage header — single provider") {
    VStack(spacing: 0) {
        OverlayUsageHeader(usage: .previewStore(
            claude: .available(ProviderUsage(
                session: UsageWindow(percent: 62, resetsAt: Date().addingTimeInterval(3 * 3600)),
                weekly: UsageWindow(percent: 41, resetsAt: Date().addingTimeInterval(4 * 86400)),
                fetchedAt: Date()
            ))
        ))
        Text("session list goes here")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
    }
    .frame(width: 180)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(40)
}

/// Degraded corner: Claude stale (dimmed, last-known 78% amber fill), Codex
/// still loading (dimmed "--" + track-only gauge) — checks that the dim
/// keeps both segments legible and the geometry identical to the live state.
#Preview("Overlay usage header — stale & loading") {
    VStack(spacing: 0) {
        OverlayUsageHeader(usage: .previewStore(
            claude: .stale(
                ProviderUsage(
                    session: UsageWindow(percent: 78, resetsAt: Date().addingTimeInterval(3 * 3600)),
                    weekly: UsageWindow(percent: 41, resetsAt: Date().addingTimeInterval(4 * 86400)),
                    fetchedAt: Date().addingTimeInterval(-3600)
                ),
                .network("offline")
            ),
            codex: .loading
        ))
        Text("session list goes here")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
    }
    .frame(width: 180)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(40)
}
#endif
