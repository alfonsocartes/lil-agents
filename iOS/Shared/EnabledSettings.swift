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

    static func set(_ enabled: Bool, kind: ProviderKind) {
        switch kind {
        case .claude: claudeEnabled = enabled
        case .grok: grokEnabled = enabled
        case .codex: codexEnabled = enabled
        }
    }
}
