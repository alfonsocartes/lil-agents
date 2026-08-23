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

    static func logoAssetName(_ kind: ProviderKind) -> String {
        switch kind {
        case .claude: "LogoClaude"
        case .grok: "LogoGrok"
        case .codex: "LogoCodex"
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

    static func errorText(_ error: UsageFetchError, kind: ProviderKind) -> String {
        switch error {
        case .credentialsMissing:
            "Tap Sign in to connect \(title(kind)) on this phone."
        case .tokenExpired:
            "Token expired — tap Sign in again."
        case .rateLimited, .network, .badResponse:
            "Usage unavailable. Pull to refresh, or sign in again."
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
