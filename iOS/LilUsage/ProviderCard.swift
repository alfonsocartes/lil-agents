import SwiftUI
import UsageCore

struct ProviderCard: View {
    let kind: ProviderKind

    @Environment(RefreshController.self) private var refresh
    @State private var enabled: Bool
    @State private var paste: String = ""
    @State private var saveFailed = false

    init(kind: ProviderKind) {
        self.kind = kind
        _enabled = State(initialValue: EnabledSettings.isEnabled(kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: ProviderChrome.symbolName(kind))
                    .frame(width: 18, height: 14)
                    .foregroundStyle(.secondary)
                Text(ProviderChrome.title(kind))
                    .font(.body)
                Spacer(minLength: 8)
                Toggle("Enabled", isOn: $enabled)
                    .labelsHidden()
                    .onChange(of: enabled) { _, value in
                        EnabledSettings.set(value, kind: kind)
                        Task { await refresh.refreshNow() }
                    }
            }

            HStack(spacing: 8) {
                SecureField("Token or CLI JSON", text: $paste)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.none)
                    .submitLabel(.done)
                    .onSubmit {
                        Task { await submitPaste() }
                    }
                    .onChange(of: paste) { _, _ in
                        saveFailed = false
                    }
                Button("Save") {
                    Task { await submitPaste() }
                }
                .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(saveFailed ? "Couldn't save token" : ProviderChrome.credentialsCaption(kind))
                .font(.caption)
                .foregroundStyle(saveFailed ? .red : .secondary)

            statusSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            enabled = EnabledSettings.isEnabled(kind)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        let slot = refresh.snapshot[kind]
        if let usage = slot.usage {
            VStack(alignment: .leading, spacing: 4) {
                windowLines(usage: usage)
                Text(usage.fetchedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(slot.lastError != nil ? 0.6 : 1)
        } else if let error = slot.lastError, enabled {
            Text(ProviderChrome.errorText(error))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if enabled {
            windowLines(usage: nil)
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

    private func submitPaste() async {
        let raw = paste.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        do {
            switch kind {
            case .claude: _ = try TokenParsing.claude(raw)
            case .codex: _ = try TokenParsing.codex(raw)
            case .grok: _ = try TokenParsing.grok(raw)
            }
            try KeychainTokenStore().save(kind: kind, raw: raw)
            EnabledSettings.set(true, kind: kind)
            enabled = true
            paste = ""
            saveFailed = false
            await refresh.refreshNow()
        } catch {
            saveFailed = true
        }
    }
}
