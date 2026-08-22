import Foundation
import Observation

/// User-configurable notification preferences for the Settings window.
/// Persisted to the injected `UserDefaults` (`.standard` in the app)
/// immediately on change (`didSet`), and
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
        static let grokUsageEnabled = "usage.grokEnabled"
        static let showBackgroundSessions = "sessions.showBackground"
    }

    /// Master switch. When off, no notification of any kind fires.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// Notify when a session is blocked on a permission/approval prompt (red).
    var notifyOnApproval: Bool {
        didSet { defaults.set(notifyOnApproval, forKey: Keys.notifyOnApproval) }
    }

    /// Notify when a session finishes its turn and is waiting on the user (yellow).
    var notifyOnIdle: Bool {
        didSet { defaults.set(notifyOnIdle, forKey: Keys.notifyOnIdle) }
    }

    /// Play the default notification sound alongside the banner.
    var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.playSound) }
    }

    /// Opt-in for Claude usage tracking (Settings toggle). Default **false**:
    /// reading credentials/polling the network on every update would be a
    /// surprise, and the Keychain fallback path can show a one-time macOS
    /// consent prompt — both should only happen after an explicit opt-in.
    var claudeUsageEnabled: Bool {
        didSet { defaults.set(claudeUsageEnabled, forKey: Keys.claudeUsageEnabled) }
    }

    /// Opt-in for Codex/ChatGPT usage tracking (Settings toggle). Default
    /// **false** — same rationale as `claudeUsageEnabled`.
    var codexUsageEnabled: Bool {
        didSet { defaults.set(codexUsageEnabled, forKey: Keys.codexUsageEnabled) }
    }

    /// Opt-in for Grok/xAI usage tracking (Settings toggle). Default
    /// **false** — same rationale as `claudeUsageEnabled`.
    var grokUsageEnabled: Bool {
        didSet { defaults.set(grokUsageEnabled, forKey: Keys.grokUsageEnabled) }
    }

    /// Show agents that have no terminal of their own — scripted or nested
    /// runs like `codex exec`, `claude -p`, grok headless, and CI. Default **false**: these
    /// have no pane to jump to and nobody waiting on them, and one agent
    /// spawning others produces them faster than real sessions, so left
    /// visible they bury the sessions you actually care about.
    ///
    /// Not everyone's background runs are noise, though — an agent hosted
    /// somewhere without a controlling terminal (a Codex IDE session, say) is
    /// a real session that this rule would otherwise hide with no way to get
    /// it back. Hence the toggle rather than a hardcoded policy.
    var showBackgroundSessions: Bool {
        didSet {
            defaults.set(showBackgroundSessions, forKey: Keys.showBackgroundSessions)
            onShowBackgroundSessionsChange?(showBackgroundSessions)
        }
    }

    /// Fired when `showBackgroundSessions` flips, so the lifecycle coordinator
    /// can retire rows the user just chose to stop seeing instead of leaving
    /// them until the next sweep. Wired in AppDelegate; nil in tests.
    var onShowBackgroundSessionsChange: ((Bool) -> Void)?

    /// Where these preferences are read from and written to. Injectable for
    /// the same reason `LoginItemController` takes one: tests that construct
    /// an `AppSettings` would otherwise read and write the ambient
    /// process-wide domain, leaving each test dependent on whatever a
    /// previous run left behind — and writing a plist to disk as a side
    /// effect. Production always gets `.standard`.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        notifyOnApproval = defaults.object(forKey: Keys.notifyOnApproval) as? Bool ?? true
        notifyOnIdle = defaults.object(forKey: Keys.notifyOnIdle) as? Bool ?? true
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true
        claudeUsageEnabled = defaults.object(forKey: Keys.claudeUsageEnabled) as? Bool ?? false
        codexUsageEnabled = defaults.object(forKey: Keys.codexUsageEnabled) as? Bool ?? false
        grokUsageEnabled = defaults.object(forKey: Keys.grokUsageEnabled) as? Bool ?? false
        showBackgroundSessions = defaults.object(forKey: Keys.showBackgroundSessions) as? Bool ?? false
    }
}
