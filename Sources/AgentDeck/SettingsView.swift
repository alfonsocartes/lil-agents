import SwiftUI

/// Content of the SwiftUI `Settings` scene. Three sections: the notification
/// preferences and the AI usage opt-in toggles, both bound directly to
/// `AppSettings`, and — visually separated at the bottom — the destructive
/// Uninstall action (which relocated here out of the menu-bar dropdown,
/// behind a native confirmation dialog).
struct SettingsView: View {
    @Bindable var settings: AppSettings

    /// Drives the uninstall confirmation dialog. The old NSAlert confirmation
    /// lived in `Uninstaller`; the confirmation is now SwiftUI's, and
    /// `Uninstaller.performUninstall()` runs only after the user confirms.
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            notificationsSection

            Divider()

            usageSection

            Divider()

            uninstallSection
        }
        .padding(20)
        .frame(width: 380)
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notifications")
                .font(.headline)

            Toggle("Enable notifications", isOn: $settings.notificationsEnabled)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Notify when a session needs approval", isOn: $settings.notifyOnApproval)
                Toggle("Notify when a session finishes its turn", isOn: $settings.notifyOnIdle)
                Toggle("Play sound", isOn: $settings.playSound)
            }
            .padding(.leading, 18)
            .disabled(!settings.notificationsEnabled)
            .foregroundStyle(settings.notificationsEnabled ? .primary : .secondary)

            Text("Alerts fire once, right when a session starts needing you — not on every update while it waits.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Opt-in toggles for the two usage-tracking providers (default off —
    /// see `AppSettings.claudeUsageEnabled`/`codexUsageEnabled`). Both are
    /// read-only against undocumented endpoints: enabling one starts polling
    /// that provider's CLI credentials and its own vendor's servers, nothing
    /// else.
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI usage")
                .font(.headline)

            Toggle("Show Claude usage", isOn: $settings.claudeUsageEnabled)
            Toggle("Show Codex usage", isOn: $settings.codexUsageEnabled)

            Text("Reads the CLI's local sign-in and contacts Anthropic/OpenAI's servers for your current usage. Claude's credentials are read via macOS's built-in `security` tool, so no permission prompt appears.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var uninstallSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Uninstall")
                .font(.headline)

            Text("This removes lil agents' hooks, its stay-awake system rule, and its support files.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Uninstall lil agents…", role: .destructive) {
                confirmingUninstall = true
            }
            .confirmationDialog(
                "Uninstall lil agents?",
                isPresented: $confirmingUninstall,
                titleVisibility: .visible
            ) {
                Button("Uninstall", role: .destructive) {
                    Uninstaller.performUninstall()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes lil agents' hooks, its stay-awake system rule, and its support files, then quits and reveals the app in Finder so you can drag it to the Trash. This can't be undone.")
            }
        }
    }
}
