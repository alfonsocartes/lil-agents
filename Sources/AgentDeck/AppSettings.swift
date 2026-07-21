import Foundation
import Observation

/// User-configurable notification preferences for the Settings window.
/// Persisted to `UserDefaults.standard` immediately on change (`didSet`), and
/// read back in `init` — with the defaults below when a key hasn't been set
/// yet (first launch). @MainActor since it's only ever touched from UI code
/// and the (also @MainActor) SessionStore/Notifier.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let notificationsEnabled = "notifications.enabled"
        static let notifyOnApproval = "notifications.notifyOnApproval"
        static let notifyOnIdle = "notifications.notifyOnIdle"
        static let playSound = "notifications.playSound"
        static let claudeUsageEnabled = "usage.claudeEnabled"
        static let codexUsageEnabled = "usage.codexEnabled"
    }

    /// Master switch. When off, no notification of any kind fires.
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// Notify when a session is blocked on a permission/approval prompt (red).
    var notifyOnApproval: Bool {
        didSet { UserDefaults.standard.set(notifyOnApproval, forKey: Keys.notifyOnApproval) }
    }

    /// Notify when a session finishes its turn and is waiting on the user (yellow).
    var notifyOnIdle: Bool {
        didSet { UserDefaults.standard.set(notifyOnIdle, forKey: Keys.notifyOnIdle) }
    }

    /// Play the default notification sound alongside the banner.
    var playSound: Bool {
        didSet { UserDefaults.standard.set(playSound, forKey: Keys.playSound) }
    }

    /// Opt-in for Claude usage tracking (Settings toggle). Default **false**:
    /// reading credentials/polling the network on every update would be a
    /// surprise, and the Keychain fallback path can show a one-time macOS
    /// consent prompt — both should only happen after an explicit opt-in.
    var claudeUsageEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeUsageEnabled, forKey: Keys.claudeUsageEnabled) }
    }

    /// Opt-in for Codex/ChatGPT usage tracking (Settings toggle). Default
    /// **false** — same rationale as `claudeUsageEnabled`.
    var codexUsageEnabled: Bool {
        didSet { UserDefaults.standard.set(codexUsageEnabled, forKey: Keys.codexUsageEnabled) }
    }

    init() {
        let defaults = UserDefaults.standard
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        notifyOnApproval = defaults.object(forKey: Keys.notifyOnApproval) as? Bool ?? true
        notifyOnIdle = defaults.object(forKey: Keys.notifyOnIdle) as? Bool ?? true
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true
        claudeUsageEnabled = defaults.object(forKey: Keys.claudeUsageEnabled) as? Bool ?? false
        codexUsageEnabled = defaults.object(forKey: Keys.codexUsageEnabled) as? Bool ?? false
    }
}
