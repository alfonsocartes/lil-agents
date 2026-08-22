import SwiftUI
import UsageCore

struct RootView: View {
    @Environment(RefreshController.self) private var refresh

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
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
}
