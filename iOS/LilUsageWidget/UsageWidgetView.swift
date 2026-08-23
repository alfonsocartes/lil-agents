import SwiftUI
import UsageCore
import WidgetKit

struct ProviderUsageBody: View {
    let kind: ProviderKind
    let snapshot: ProviderSnapshot
    var layout: UsageWindowLine.Layout = .inlineReset
    var showsTitle: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTitle {
                HStack(spacing: 6) {
                    ProviderLogo(kind: kind)
                        .frame(width: 12, height: 12)
                    Text(ProviderChrome.title(kind))
                        .fontWeight(.medium)
                }
                .font(.caption)
            }
            content
        }
        .opacity(snapshot.lastError != nil && snapshot.usage != nil ? 0.6 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if let usage = snapshot.usage {
            ForEach(ProviderChrome.windowLabels(kind), id: \.self) { label in
                UsageWindowLine(
                    label: label,
                    window: ProviderChrome.window(kind: kind, label: label, usage: usage),
                    layout: layout
                )
            }
        } else if let error = snapshot.lastError {
            Text(ProviderChrome.errorText(error, kind: kind))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(ProviderChrome.windowLabels(kind), id: \.self) { label in
                UsageWindowLine(label: label, window: nil, layout: layout)
            }
        }
    }
}
