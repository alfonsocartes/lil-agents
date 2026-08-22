import SwiftUI
import UsageCore

extension UsageUrgency {
    /// Semantic accent for this tier, or nil for `.normal`. Quiet below 75%;
    /// `.orange` at ≥75%, `.red` at ≥90% on the rounded percent.
    var tint: Color? {
        switch self {
        case .normal: return nil
        case .elevated: return .orange
        case .critical: return .red
        }
    }
}

/// Slim capsule track with a leading fill proportional to `percent` (0–100).
/// Nil/zero percent is track-only so "--" keeps its geometry. Hidden from
/// accessibility — the percent text beside it is the accessible value.
struct UsageGauge: View {
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
                        // below its own diameter collapses into a sliver.
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

/// One window's gauge line. Matches Mac `UsageMenuSection` metrics: 36pt
/// label, 40×3 gauge, 32pt trailing percent, reset caption that never truncates.
struct UsageWindowLine: View {
    enum Layout {
        case inlineReset
        case stackedReset
    }

    let label: String
    let window: UsageWindow?
    var now: Date = Date()
    var layout: Layout = .inlineReset

    private enum Metrics {
        static let windowLabelWidth: CGFloat = 36
        static let gaugeWidth: CGFloat = 40
        static let gaugeHeight: CGFloat = 3
        static let percentWidth: CGFloat = 32
    }

    private var percent: Double? { window?.percent }
    private var urgency: UsageUrgency { UsageUrgency(percent: percent) }
    private var reset: String { UsageFormatting.resetLabel(for: window?.resetsAt, now: now) }

    var body: some View {
        switch layout {
        case .inlineReset:
            HStack(spacing: 6) {
                labelView
                gauge
                percentView
                Spacer(minLength: 4)
                resetView
            }
        case .stackedReset:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    labelView
                    gauge
                    percentView
                    Spacer(minLength: 0)
                }
                resetView
            }
        }
    }

    private var labelView: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: Metrics.windowLabelWidth, alignment: .leading)
    }

    private var gauge: some View {
        UsageGauge(percent: percent)
            .frame(width: Metrics.gaugeWidth, height: Metrics.gaugeHeight)
    }

    private var percentView: some View {
        Text(UsageFormatting.percentLabel(percent))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(urgency.tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            .frame(width: Metrics.percentWidth, alignment: .trailing)
    }

    @ViewBuilder
    private var resetView: some View {
        if !reset.isEmpty {
            Text(reset)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }
}
