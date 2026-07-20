import Foundation
import Combine

/// User-configurable notification preferences for the Settings window.
/// Persisted to `UserDefaults.standard` immediately on change (`didSet`), and
/// read back in `init` — with the defaults below when a key hasn't been set
/// yet (first launch). @MainActor since it's only ever touched from UI code
/// and the (also @MainActor) SessionStore/Notifier.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let notificationsEnabled = "notifications.enabled"
        static let notifyOnApproval = "notifications.notifyOnApproval"
        static let notifyOnIdle = "notifications.notifyOnIdle"
        static let playSound = "notifications.playSound"
    }

    /// Master switch. When off, no notification of any kind fires.
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// Notify when a session is blocked on a permission/approval prompt (red).
    @Published var notifyOnApproval: Bool {
        didSet { UserDefaults.standard.set(notifyOnApproval, forKey: Keys.notifyOnApproval) }
    }

    /// Notify when a session finishes its turn and is waiting on the user (yellow).
    @Published var notifyOnIdle: Bool {
        didSet { UserDefaults.standard.set(notifyOnIdle, forKey: Keys.notifyOnIdle) }
    }

    /// Play the default notification sound alongside the banner.
    @Published var playSound: Bool {
        didSet { UserDefaults.standard.set(playSound, forKey: Keys.playSound) }
    }

    init() {
        let defaults = UserDefaults.standard
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        notifyOnApproval = defaults.object(forKey: Keys.notifyOnApproval) as? Bool ?? true
        notifyOnIdle = defaults.object(forKey: Keys.notifyOnIdle) as? Bool ?? true
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true
    }
}
