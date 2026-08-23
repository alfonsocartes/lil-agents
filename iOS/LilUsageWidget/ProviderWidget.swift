import SwiftUI
import WidgetKit

struct ProviderWidget: Widget {
    let kind = "LilUsageProvider"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectProviderIntent.self,
            provider: ProviderTimelineProvider()
        ) { entry in
            ProviderWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(UsageTimeline.appURL)
        }
        .configurationDisplayName("Provider")
        .description("Usage for one provider.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ProviderWidgetView: View {
    let entry: ProviderEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.snapshot.enabled {
            ProviderUsageBody(
                kind: entry.kind,
                snapshot: entry.snapshot,
                layout: family == .systemSmall ? .stackedReset : .inlineReset
            )
        } else {
            Text("Turn on \(ProviderChrome.title(entry.kind)) in lil usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
