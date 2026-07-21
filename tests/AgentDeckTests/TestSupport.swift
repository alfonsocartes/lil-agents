import Foundation
import Synchronization
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

// MARK: - Usage fetcher spies (Claude/CodexUsageFetcher)

/// Records every request handed to an injected `transport` closure and
/// replays canned `(Data, HTTPURLResponse)` results (or throws) in the order
/// given — the LAST configured result repeats for any call beyond the
/// list's length, so a test that only cares about the first response can
/// still assert "transport never called again" style expectations by
/// passing a single-element list. `Mutex`-backed (never `@unchecked
/// Sendable`) so it's safe to share between the `@Sendable` transport
/// closure and the test's assertions — mirrors EventListener.swift's use of
/// `Synchronization.Mutex`.
final class TransportSpy: Sendable {
    enum StubResult {
        case success(status: Int, headers: [String: String] = [:], body: Data)
        case failure(Error)
    }

    private struct State {
        var callCount = 0
        var results: [StubResult]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    init(_ results: [StubResult]) {
        state = Mutex(State(results: results))
    }

    var callCount: Int { state.withLock { $0.callCount } }

    /// Every request handed to `handle`, in order — lets tests assert on
    /// headers (e.g. "ChatGPT-Account-Id omitted when absent") without the
    /// stub needing to know in advance what to check.
    var requests: [URLRequest] { state.withLock { $0.requests } }

    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let result = state.withLock { s -> StubResult in
            let index = min(s.callCount, s.results.count - 1)
            let picked = s.results[index]
            s.callCount += 1
            s.requests.append(request)
            return picked
        }
        switch result {
        case .success(let status, let headers, let body):
            let http = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (body, http)
        case .failure(let error):
            throw error
        }
    }
}

/// Records how many times a `keychainRead` seam was invoked and returns a
/// fixed canned value every time. `ClaudeUsageFetcherTests` uses the call
/// count to assert the once-per-launch cache actually suppresses repeat
/// Keychain reads (including after a denial).
final class KeychainSpy: Sendable {
    private let state: Mutex<(callCount: Int, result: Data?)>

    init(returning result: Data?) {
        state = Mutex((0, result))
    }

    var callCount: Int { state.withLock { $0.callCount } }

    func read() -> Data? {
        state.withLock { s in
            s.callCount += 1
            return s.result
        }
    }
}
