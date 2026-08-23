import SwiftUI
import UsageCore

struct RootView: View {
    @Environment(RefreshController.self) private var refresh
    @AppStorage("widgetSetup.dismissed") private var widgetSetupDismissed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Home Screen widgets for Claude, Codex, and Grok usage. Sign in on this phone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    widgetSetupSection
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        ProviderCard(kind: kind)
                    }
                }
                .padding()
            }
            .navigationTitle("lil usage")
            .refreshable {
                await refresh.refreshNow()
            }
            .task {
                await refresh.refreshNow()
            }
        }
    }

    @ViewBuilder
    private var widgetSetupSection: some View {
        switch WidgetSetupPrompt(
            hasSignedInProvider: refresh.snapshot.hasSignedInProvider,
            dismissed: widgetSetupDismissed
        ) {
        case .hidden:
            EmptyView()
        case .card:
            WidgetSetupCard { widgetSetupDismissed = true }
        case .link:
            Button {
                widgetSetupDismissed = false
            } label: {
                Label("How to add widgets", systemImage: "widget.small")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
