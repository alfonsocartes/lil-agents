import SwiftUI
import UsageCore
import WidgetKit

struct StackWidget: Widget {
    let kind = "LilUsageStack"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StackTimelineProvider()) { entry in
            StackWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(UsageTimeline.appURL)
        }
        .configurationDisplayName("Stack")
        .description("Usage for every enabled provider.")
        .supportedFamilies([.systemMedium])
    }
}

struct StackWidgetView: View {
    let entry: StackEntry

    private var enabledKinds: [ProviderKind] {
        // Snapshot `enabled` is written atomically with usage; don't wait
        // on App Group UserDefaults (cfprefsd) to flush.
        ProviderKind.allCases.filter { entry.snapshot[$0].enabled }
    }

    var body: some View {
        if enabledKinds.isEmpty {
            Text("Enable a provider in lil usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(enabledKinds, id: \.self) { kind in
                    ProviderUsageBody(
                        kind: kind,
                        snapshot: entry.snapshot[kind],
                        layout: .inlineReset
                    )
                }
            }
        }
    }
}
