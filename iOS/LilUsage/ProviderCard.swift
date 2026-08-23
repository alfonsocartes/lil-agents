import SwiftUI
import UsageCore

struct ProviderCard: View {
    let kind: ProviderKind

    @Environment(RefreshController.self) private var refresh
    @State private var enabled: Bool
    @State private var showingSignIn = false
    @State private var saveFailed = false

    init(kind: ProviderKind) {
        self.kind = kind
        _enabled = State(initialValue: EnabledSettings.isEnabled(kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderLogo(kind: kind)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.primary)
                Text(ProviderChrome.title(kind))
                    .font(.headline)
                Spacer(minLength: 8)
                Toggle("Show in widgets", isOn: $enabled)
                    .labelsHidden()
                    .onChange(of: enabled) { _, value in
                        EnabledSettings.set(value, kind: kind)
                        Task { await refresh.refreshNow() }
                    }
            }

            if let usage = refresh.snapshot[kind].usage {
                VStack(alignment: .leading, spacing: 4) {
                    windowLines(usage: usage)
                    Text(usage.fetchedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .opacity(refresh.snapshot[kind].lastError != nil ? 0.6 : 1)
            }

            if let error = refresh.snapshot[kind].lastError, enabled, refresh.snapshot[kind].usage == nil {
                Text(ProviderChrome.errorText(error, kind: kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                showingSignIn = true
            } label: {
                Text(refresh.snapshot[kind].usage == nil ? "Sign in" : "Sign in again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if saveFailed {
                Text("Couldn’t save the token on this phone.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { enabled = EnabledSettings.isEnabled(kind) }
        .onChange(of: refresh.snapshot[kind].enabled) { _, value in
            enabled = value
        }
        .sheet(isPresented: $showingSignIn) {
            SignInSheet(kind: kind) { raw in
                Task { await saveRaw(raw) }
            }
        }
    }

    private func windowLines(usage: ProviderUsage?) -> some View {
        ForEach(ProviderChrome.windowLabels(kind), id: \.self) { label in
            UsageWindowLine(
                label: label,
                window: ProviderChrome.window(kind: kind, label: label, usage: usage)
            )
        }
    }

    private func saveRaw(_ raw: String) async {
        do {
            try KeychainTokenStore().save(kind: kind, raw: raw)
            EnabledSettings.set(true, kind: kind)
            enabled = true
            saveFailed = false
            await refresh.refreshNow()
        } catch {
            saveFailed = true
        }
    }
}
