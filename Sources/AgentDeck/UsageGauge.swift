import SwiftUI

/// SwiftUI half of the usage design language defined by `UsageUrgency`
/// (UsageModel.swift): the semantic tint per tier, and the slim capsule
/// "capacity gauge" both SwiftUI usage surfaces draw (`UsageMenuSection`'s
/// per-window lines and `OverlayUsageHeader`'s per-provider segments). Lives
/// in its own file because it belongs to neither surface — it IS the shared
/// piece that keeps them cohesive. The menu bar draws the same gauge as
/// baked pixels in UsageMenuBarIcon.swift (a `MenuBarExtra` label can't host
/// live SwiftUI — see that file's rasterization rationale).
extension UsageUrgency {
    /// Semantic accent for this tier, or nil for `.normal` — normal usage is
    /// deliberately QUIET (monochrome secondary/primary, per surface), so
    /// color only ever appears when it's saying something: amber
    /// "approaching the cap", red "about to run out". Semantic `.orange`/
    /// `.red` (not fixed RGB) so the system adapts them to appearance and
    /// increase-contrast settings; the menu bar bitmap, which can't use
    /// semantic colors, bakes matching explicit values instead.
    var tint: Color? {
        switch self {
        case .normal: return nil
        case .elevated: return .orange
        case .critical: return .red
        }
    }
}

/// A slim horizontal capacity gauge: a quiet `.quaternary` capsule track with
/// a leading fill proportional to `percent` (0–100, clamped). The fill is
/// monochrome `.secondary` at normal usage and takes the urgency tint at
/// >= 75% / >= 90% — the gauge, not the text, is what reads at a glance, so
/// it carries the color first.
///
/// Sizing is the caller's job (`.frame(width:height:)`): the dropdown uses a
/// fixed 64pt column so bars align across rows, the overlay a 20pt micro
/// track. A nil/zero percent renders track-only — the "--" placeholder state
/// keeps its full geometry so nothing jumps when data arrives.
///
/// Hidden from accessibility: every gauge sits beside the exact percent as
/// text, so VoiceOver would only hear the same number twice.
struct UsageGauge: View {
    /// 0–100 (clamped), or nil for the placeholder track-only state.
    let percent: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max((percent ?? 0) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                if fraction > 0 {
                    Capsule(style: .continuous)
                        .fill(fillStyle)
                        // Never narrower than the track is tall: a capsule
                        // below its own diameter collapses into a sliver of
                        // garbage pixels, so tiny percents show as a minimal
                        // round dot instead.
                        .frame(width: max(geo.size.height, geo.size.width * fraction))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var fillStyle: AnyShapeStyle {
        if let tint = UsageUrgency(percent: percent).tint {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(.secondary)
    }
}

#if DEBUG
#Preview("Usage gauges") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach([nil, 3.0, 40, 62, 78, 92, 100] as [Double?], id: \.self) { percent in
            HStack(spacing: 8) {
                UsageGauge(percent: percent)
                    .frame(width: 64, height: 3)
                Text(UsageFormatting.percentLabel(percent))
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }
    .padding(20)
}
#endif
