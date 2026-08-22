import Foundation

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var claude: ProviderSnapshot
    public var grok: ProviderSnapshot
    public var codex: ProviderSnapshot

    public init(claude: ProviderSnapshot, grok: ProviderSnapshot, codex: ProviderSnapshot) {
        self.claude = claude
        self.grok = grok
        self.codex = codex
    }

    public static var empty: UsageSnapshot {
        UsageSnapshot(claude: .empty, grok: .empty, codex: .empty)
    }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Last successful fetch, kept across later failures (stale) and while
    /// the provider is disabled.
    public var usage: ProviderUsage?
    /// Nil if the last fetch succeeded.
    public var lastError: UsageFetchError?
    public var lastAttemptAt: Date?
    /// 429 backoff deadline. `UsageRefresher` skips network while `now` is
    /// still before this, even if `minAge` has elapsed.
    public var retryAfterUntil: Date?

    public init(
        enabled: Bool = false,
        usage: ProviderUsage? = nil,
        lastError: UsageFetchError? = nil,
        lastAttemptAt: Date? = nil,
        retryAfterUntil: Date? = nil
    ) {
        self.enabled = enabled
        self.usage = usage
        self.lastError = lastError
        self.lastAttemptAt = lastAttemptAt
        self.retryAfterUntil = retryAfterUntil
    }

    public static var empty: ProviderSnapshot {
        ProviderSnapshot()
    }
}

/// Codable snapshot file `usage-snapshot.json` in an injected directory
/// (App Group later). Never includes tokens.
public struct SnapshotStore: Sendable {
    public static let filename = "usage-snapshot.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() -> UsageSnapshot {
        let url = directory.appendingPathComponent(Self.filename)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UsageSnapshot.self, from: data)) ?? .empty
    }

    public func save(_ snapshot: UsageSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let dest = directory.appendingPathComponent(Self.filename)
        let temp = directory.appendingPathComponent("usage-snapshot-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: dest)
        }
    }
}
