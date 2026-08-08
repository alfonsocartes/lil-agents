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
    cwd: String? = nil,
    tty: String? = nil,
    agentPID: Int32? = nil,
    headless: Bool? = nil,
    terminal: String? = nil,
    weztermPane: String? = nil,
    weztermSocket: String? = nil,
    tmuxPane: String? = nil,
    tmuxSocket: String? = nil,
    hostTTY: String? = nil
) -> HookEvent {
    var dict: [String: Any] = ["tool": tool, "event": event, "session_id": id]
    if let notification { dict["notification_type"] = notification }
    if let cwd { dict["cwd"] = cwd }
    if let tty { dict["tty"] = tty }
    if let agentPID { dict["agent_pid"] = agentPID }
    if let headless { dict["headless"] = headless }
    if let terminal { dict["terminal"] = terminal }
    if let weztermPane { dict["wezterm_pane"] = weztermPane }
    if let weztermSocket { dict["wezterm_socket"] = weztermSocket }
    if let tmuxPane { dict["tmux_pane"] = tmuxPane }
    if let tmuxSocket { dict["tmux_socket"] = tmuxSocket }
    if let hostTTY { dict["host_tty"] = hostTTY }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(HookEvent.self, from: data)
}

// MARK: - Process observation fakes

@MainActor
final class FakeProcessExitObserver: ProcessExitObserving {
    @MainActor
    private final class Token: ProcessObservation {
        private let onCancel: () -> Void
        private var isCancelled = false

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            onCancel()
        }
    }

    private(set) var observeCount: [ProcessIdentity: Int] = [:]
    private(set) var cancelCount: [ProcessIdentity: Int] = [:]
    private var handlers: [ProcessIdentity: [@MainActor @Sendable (ProcessIdentity) -> Void]] = [:]

    func observe(
        _ identity: ProcessIdentity,
        onExit: @escaping @MainActor @Sendable (ProcessIdentity) -> Void
    ) -> any ProcessObservation {
        observeCount[identity, default: 0] += 1
        handlers[identity, default: []].append(onExit)
        return Token { [weak self] in
            self?.cancelCount[identity, default: 0] += 1
        }
    }

    /// Intentionally retains handlers after cancellation. Tests can therefore
    /// simulate a dispatch callback that was already queued when replacement
    /// cancelled its observation.
    func emitExit(for identity: ProcessIdentity) {
        for handler in handlers[identity] ?? [] {
            handler(identity)
        }
    }
}

func processIdentity(
    pid: Int32,
    startSeconds: UInt64 = 1,
    startMicroseconds: UInt64 = 0
) -> ProcessIdentity {
    ProcessIdentity(
        pid: pid,
        startSeconds: startSeconds,
        startMicroseconds: startMicroseconds
    )
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

// MARK: - Scratch defaults (never writes outside memory)

/// An in-memory stand-in for a `UserDefaults` suite, shared by every test that
/// constructs a type taking injected defaults (`LoginItemController`,
/// `AppSettings`).
///
/// Those types take a concrete `UserDefaults`, not a protocol, so a real suite
/// (`UserDefaults(suiteName:)`) was the first thing tried — but every write to
/// a suite routes through `cfprefsd`, which flushes
/// `~/Library/Preferences/<suiteName>.plist` to disk asynchronously and on its
/// own schedule, as a separate long-lived daemon process. Confirmed by
/// observation: stray plists could still appear *seconds* after the test
/// process had already exited, so no in-process teardown —
/// `removePersistentDomain`, `synchronize()`, deleting the file directly, any
/// combination — could reliably win that race. Overriding the handful of
/// accessors those types actually call sidesteps `cfprefsd` entirely: nothing
/// is ever written to disk, so there's nothing left to race or clean up.
///
/// This is the defaults counterpart to `makeTempDir` above — same rule, that
/// the suite never writes outside its own scratch space.
@MainActor
final class InMemoryDefaults: UserDefaults {
    // `nonisolated(unsafe)`, not `Mutex`-guarded: these overrides must match
    // `UserDefaults`'s plain (non-isolated) Objective-C method signatures, so
    // they can't themselves be `@MainActor` even though the class is. Safe
    // without a lock because every real caller — the injected types' instance
    // methods and the `@MainActor` test bodies — only ever reaches this from
    // the main actor; nothing here actually runs concurrently.
    private nonisolated(unsafe) var storage: [String: Any] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func bool(forKey defaultName: String) -> Bool {
        (storage[defaultName] as? Bool) ?? false
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}

/// Hands `body` a fresh `InMemoryDefaults`, so tests don't leak persisted
/// flags between runs or collide with `.standard` (which the real app reads
/// and writes) — and, since it never touches disk, don't leak a
/// `~/Library/Preferences` plist either.
@MainActor
func withScratchDefaults(_ body: (UserDefaults) -> Void) {
    body(InMemoryDefaults())
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
