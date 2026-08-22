import Foundation

/// DI seam for fetching one provider's usage snapshot. Production wires in
/// `ClaudeUsageFetcher`/`CodexUsageFetcher`/`GrokUsageFetcher`; tests inject
/// a stub that returns canned data or throws a `UsageFetchError` without
/// touching the network.
///
/// Deliberately has no `kind` property: callers hold named slots rather than
/// typing providers generically.
public protocol UsageProviding: Sendable {
    func fetchUsage() async throws -> ProviderUsage
}
