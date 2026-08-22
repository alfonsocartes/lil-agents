import SwiftUI
import UsageCore

enum ProviderChrome {
    static func title(_ kind: ProviderKind) -> String {
        switch kind {
        case .claude: "Claude"
        case .grok: "Grok"
        case .codex: "Codex"
        }
    }

    static func symbolName(_ kind: ProviderKind) -> String {
        switch kind {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "hare"
        }
    }

    static func credentialsCaption(_ kind: ProviderKind) -> String {
        switch kind {
        case .claude: "~/.claude/.credentials.json"
        case .grok: "~/.grok/auth.json"
        case .codex: "~/.codex/auth.json"
        }
    }

    static func windowLabels(_ kind: ProviderKind) -> [String] {
        switch kind {
        case .claude: ["5h", "week"]
        case .grok, .codex: ["week"]
        }
    }

    static func window(kind: ProviderKind, label: String, usage: ProviderUsage?) -> UsageWindow? {
        switch (kind, label) {
        case (.claude, "5h"): usage?.session
        case (_, "week"): usage?.weekly
        default: nil
        }
    }

    static func errorText(_ error: UsageFetchError) -> String {
        switch error {
        case .credentialsMissing, .tokenExpired: "Sign in again"
        case .rateLimited, .network, .badResponse: "Usage unavailable"
        }
    }
}

extension UsageSnapshot {
    subscript(_ kind: ProviderKind) -> ProviderSnapshot {
        switch kind {
        case .claude: claude
        case .grok: grok
        case .codex: codex
        }
    }
}
