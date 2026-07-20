import Foundation
@testable import AgentDeck

// MARK: - Notifier spy

/// Records every notification SessionStore fires, without touching
/// UNUserNotificationCenter (which crashes in a bundle-less test process).
/// This is exactly the seam `SessionNotifying` exists for.
@MainActor
final class SpyNotifier: SessionNotifying {
    private(set) var events: [(sessionID: String, reason: Notifier.Reason)] = []

    func notify(session: Session, reason: Notifier.Reason) {
        events.append((session.id, reason))
    }

    var reasons: [Notifier.Reason] { events.map { $0.reason } }
    var count: Int { events.count }
}

// MARK: - HookEvent construction

/// Builds a `HookEvent` by decoding a JSON dict, sidestepping the noisy
/// memberwise initializer (every terminal-jump field is a separate arg).
/// Mirrors exactly how a real event arrives over the wire.
func makeEvent(
    _ event: String,
    id: String = "s1",
    tool: String = "claude",
    notification: String? = nil,
    cwd: String? = nil
) -> HookEvent {
    var dict: [String: Any] = ["tool": tool, "event": event, "session_id": id]
    if let notification { dict["notification_type"] = notification }
    if let cwd { dict["cwd"] = cwd }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(HookEvent.self, from: data)
}

// MARK: - Temp filesystem helpers (never writes outside the temp dir)

func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentDeckTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
func makeExecutableFile(at url: URL) -> URL {
    FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@discardableResult
func makeNonExecutableFile(at url: URL) -> URL {
    FileManager.default.createFile(atPath: url.path, contents: Data("plain\n".utf8))
    try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    return url
}

func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
