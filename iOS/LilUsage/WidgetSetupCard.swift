import SwiftUI

struct WidgetSetupCard: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to Home Screen")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                step("1. Touch and hold the Home Screen")
                step("2. Tap **Edit**, then **Add Widget**")
                step("3. Search **lil usage**")
                step("4. Add **Stack** (every signed-in provider) or **Provider** (one)")
                step("5. For Provider: touch and hold the widget, tap **Edit Widget**, and pick Claude, Codex, or Grok")
            }
            Button("Got it") {
                onDismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
