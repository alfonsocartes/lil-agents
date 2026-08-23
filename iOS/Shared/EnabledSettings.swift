import Foundation
import UsageCore

enum EnabledSettings {
    private static let claudeKey = "usage.claudeEnabled"
    private static let grokKey = "usage.grokEnabled"
    private static let codexKey = "usage.codexEnabled"

    static var claudeEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: claudeKey) }
        set { AppGroup.defaults.set(newValue, forKey: claudeKey) }
    }

    static var grokEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: grokKey) }
        set { AppGroup.defaults.set(newValue, forKey: grokKey) }
    }

    static var codexEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: codexKey) }
        set { AppGroup.defaults.set(newValue, forKey: codexKey) }
    }

    static var settings: UsageSettings {
        UsageSettings(
            claudeEnabled: claudeEnabled,
            grokEnabled: grokEnabled,
            codexEnabled: codexEnabled
        )
    }

    static func isEnabled(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .claude: claudeEnabled
        case .grok: grokEnabled
        case .codex: codexEnabled
        }
    }

    /// `nil` when the user has never toggled this provider. Distinct from
    /// `false` so Mac token handoff can auto-enable once without fighting
    /// a later "Show in widgets" off.
    static func explicitEnabled(_ kind: ProviderKind) -> Bool? {
        let name = key(kind)
        guard AppGroup.defaults.object(forKey: name) != nil else { return nil }
        return AppGroup.defaults.bool(forKey: name)
    }

    static func set(_ enabled: Bool, kind: ProviderKind) {
        switch kind {
        case .claude: claudeEnabled = enabled
        case .grok: grokEnabled = enabled
        case .codex: codexEnabled = enabled
        }
    }

    private static func key(_ kind: ProviderKind) -> String {
        switch kind {
        case .claude: claudeKey
        case .grok: grokKey
        case .codex: codexKey
        }
    }
}
