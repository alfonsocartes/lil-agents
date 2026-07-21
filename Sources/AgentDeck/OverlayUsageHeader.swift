import SwiftUI

/// The overlay's usage row: one combined line above the session list showing
/// Claude's 5-hour percent and Codex's weekly percent, e.g. "✳ 95%  ⬡ 15%"
/// (the user's explicit choice of window per provider — see UsageModel.swift
/// and the feature plan). Lives inside the overlay's single glass sheet
/// (OverlayView.swift): plain fills only here, never a second `.glassEffect`
/// — glass-on-glass is explicitly discouraged.
///
/// Hidden entirely when both providers are `.disabled` (the default, opt-in
/// Settings toggles are off); a provider's own segment is omitted the same
/// way, so enabling just one provider shows just its glyph and percent.
struct OverlayUsageHeader: View {
    let usage: UsageStore

    var body: some View {
        if usage.claude == .disabled && usage.codex == .disabled {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
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
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                Divider()
            }
        }
    }

    /// One glyph + percent pair. `dimmed` (stale/loading/unavailable data,
    /// per `ProviderUsageState.isDimmed`) applies an EXTRA 0.5 opacity on top
    /// of the row's already-secondary foreground style, so a provider that's
    /// currently failing visibly recedes without disappearing — there's still
    /// a last-known number to glance at.
    private func segment(symbolName: String, percent: Double?, dimmed: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
            Text(UsageFormatting.percentLabel(percent))
        }
        .opacity(dimmed ? 0.5 : 1)
    }
}

#if DEBUG
#Preview("Overlay usage header") {
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
#endif
