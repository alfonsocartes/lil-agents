import SwiftUI

/// Content of the Settings window: notification preferences bound directly
/// to `AppSettings`. Compact by design — this app has exactly one settings
/// surface, no tabs/sidebar needed.
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
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
        .padding(20)
        .frame(width: 360)
    }
}
