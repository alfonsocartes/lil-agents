import Foundation

/// DI seam for fetching one provider's usage snapshot — the `UsageStore`
/// analogue of `SessionNotifying`. Production wires in `ClaudeUsageFetcher`/
/// `CodexUsageFetcher`; tests inject a stub that returns canned data or
/// throws a `UsageFetchError` without touching disk, Keychain, or the
/// network.
///
/// Deliberately has no `kind`/provider-identity property: `UsageStore` holds
/// exactly two named slots (`claudeProvider`/`codexProvider`) rather than
/// typing providers generically, so a `kind` enum here would be dead weight
/// nothing ever switches on.
protocol UsageProviding: Sendable {
    func fetchUsage() async throws -> ProviderUsage
}
