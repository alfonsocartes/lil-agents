import Foundation

/// Shared constants for AgentDeck.
enum AgentDeck {
    /// Loopback port the embedded event listener binds to, and that installed
    /// CLI hooks forward events to. Loopback-only (127.0.0.1) — never LAN.
    static let port: UInt16 = 8787

    /// A session that hasn't emitted any event in this many seconds is treated
    /// as dead and pruned (safety net for a missed SessionEnd).
    static let staleAfter: TimeInterval = 60 * 60

    /// Directory where AgentDeck keeps its runtime files (forwarder script, etc).
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AgentDeck", isDirectory: true)
    }
}
