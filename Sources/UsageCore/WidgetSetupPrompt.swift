/// Whether the iOS app should teach adding Home Screen widgets.
/// The widget gallery is a system gesture — apps cannot add one themselves.
/// Installing a widget does not hide this; people still need the steps later.
public enum WidgetSetupPrompt: Equatable, Sendable {
    /// Nobody has signed in yet.
    case hidden
    /// Signed in, steps visible.
    case card
    /// Signed in, card collapsed to a link that brings the steps back.
    case link

    public init(hasSignedInProvider: Bool, dismissed: Bool) {
        guard hasSignedInProvider else {
            self = .hidden
            return
        }
        self = dismissed ? .link : .card
    }
}

extension UsageSnapshot {
    /// True once any provider has been connected — usage on file, or a
    /// fetch error that isn't "no credentials". Toggling a provider on
    /// without signing in does not count.
    public var hasSignedInProvider: Bool {
        [claude, grok, codex].contains { $0.isSignedIn }
    }
}

extension ProviderSnapshot {
    var isSignedIn: Bool {
        if usage != nil { return true }
        switch lastError {
        case .tokenExpired, .rateLimited, .network, .badResponse:
            return true
        case .credentialsMissing, nil:
            return false
        }
    }
}
