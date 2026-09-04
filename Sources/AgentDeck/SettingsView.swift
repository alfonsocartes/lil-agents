import SwiftUI

/// Content of the SwiftUI `Settings` scene. Three sections: the notification
/// preferences and the AI usage opt-in toggles, both bound directly to
/// `AppSettings`, and — visually separated at the bottom — the destructive
/// Uninstall action (which relocated here out of the menu-bar dropdown,
/// behind a native confirmation dialog).
struct SettingsView: View {
    @Bindable var settings: AppSettings

    /// Launch-at-login toggle state. `@Observable`, not `@Bindable`, so a
    /// plain `let` tracks its reads fine; the Toggle below needs a manual
    /// `Binding` since `isEnabled` isn't exposed as a SwiftUI binding.
    let loginItem: LoginItemController

    /// Drives the uninstall confirmation dialog. The old NSAlert confirmation
    /// lived in `Uninstaller`; the confirmation is now SwiftUI's, and
    /// `Uninstaller.performUninstall()` runs only after the user confirms.
    @State private var confirmingUninstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        generalSection
                        Divider()
                        sessionsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 16) {
                        notificationsSection
                        Divider()
                        usageSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                uninstallSection
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 580, maxWidth: 640)
        .frame(minHeight: 360, idealHeight: 440, maxHeight: 520)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    /// The user can flip the login item off in System Settings at any time and
    /// `SMAppService` has no way to tell us — no KVO, no delegate, no
    /// notification — so the only option is to re-read `status` on demand.
    ///
    /// `.onAppear` alone isn't enough: it fires when this view is created, so
    /// a Settings window left open while the user visits System Settings would
    /// keep showing a stale toggle. That's the likeliest path to hit, since
    /// the `needsApproval` warning below sends people there by design. Hence
    /// also refreshing whenever the app comes back to the foreground.
    private var generalSection: some View {
        let isEnabled = Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.isEnabled = $0 }
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text("General")
                .font(.headline)

            Toggle("Launch at login", isOn: isEnabled)
                .disabled(!loginItem.isAvailable)

            if loginItem.isAvailable {
                Text("Starts in the menu bar when you log in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Available in the installed app only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if loginItem.needsApproval {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS is waiting on your approval before this can start automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Login Items…") {
                        loginItem.openSystemSettings()
                    }
                    .buttonStyle(.link)
                }
            }

            if let lastError = loginItem.lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.headline)

            Toggle("Enable notifications", isOn: $settings.notificationsEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Notify when a session needs approval", isOn: $settings.notifyOnApproval)
                Toggle("Notify when a session finishes its turn", isOn: $settings.notifyOnIdle)
                Toggle("Play sound", isOn: $settings.playSound)
            }
            .padding(.leading, 18)
            .disabled(!settings.notificationsEnabled)
            .foregroundStyle(settings.notificationsEnabled ? .primary : .secondary)

            Text("Fires once when a session starts needing you.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!settings.sessionsEnabled)
        .foregroundStyle(settings.sessionsEnabled ? .primary : .secondary)
    }

    /// Off by default: an agent with no terminal of its own is usually a
    /// scripted or nested run nobody is waiting on, and they arrive faster
    /// than real sessions. The toggle exists because that is not universally
    /// true — see `AppSettings.showBackgroundSessions`.
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions")
                .font(.headline)

            Toggle("Track sessions", isOn: $settings.sessionsEnabled)

            Text("Installs CLI hooks. Off removes them and hides the overlay.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show background agents", isOn: $settings.showBackgroundSessions)

                Text("Headless, CI, and editor-hosted agents. Hidden by default.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 18)
            .disabled(!settings.sessionsEnabled)
            .foregroundStyle(settings.sessionsEnabled ? .primary : .secondary)
        }
    }

    /// Opt-in toggles for the usage-tracking providers (default off —
    /// see `AppSettings.claudeUsageEnabled`/`codexUsageEnabled`/`grokUsageEnabled`).
    /// Each is read-only against undocumented endpoints: enabling one starts
    /// polling that provider's CLI credentials and its own vendor's servers,
    /// nothing else.
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI usage")
                .font(.headline)

            Toggle("Show Claude usage", isOn: $settings.claudeUsageEnabled)
            Toggle("Show Codex usage", isOn: $settings.codexUsageEnabled)
            Toggle("Show Grok usage", isOn: $settings.grokUsageEnabled)

            Text("Reads the CLI sign-in and asks Anthropic, OpenAI, or xAI for current usage.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Send tokens to iPhone", isOn: $settings.shareTokensWithIPhone)

            Text("Copies those sign-ins into iCloud Keychain for lil usage. Same Apple ID, iCloud Keychain on. The iPhone app can also Sign in there.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = IPhoneTokenHandoff.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var uninstallSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uninstall")
                .font(.headline)

            Text("This removes lil agents' hooks, its login item, its stay-awake system rule, and its support files.")
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
                Text("This removes lil agents' hooks, its login item, its stay-awake system rule, and its support files, then quits and reveals the app in Finder so you can drag it to the Trash. This can't be undone.")
            }
        }
    }
}
