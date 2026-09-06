import Foundation
import Network
import Testing
@testable import LilAgents

/// Serialized so two tests never bind 54173 at once. Skip bind-again only
/// when something else already owns the port *before* this test starts it.
@MainActor
@Suite(.serialized) struct EventListenerTests {
    private func makeListener() -> EventListener {
        let store = SessionStore()
        let observer = FakeProcessExitObserver()
        let lifecycle = SessionLifecycleCoordinator(store: store, processObserver: observer)
        return EventListener(
            lifecycle: lifecycle,
            processResolver: DarwinProcessIdentityResolver(),
            token: "test-token"
        )
    }

    @Test func stopOnUnstartedListenerIsANoOp() {
        let listener = makeListener()
        #expect(!listener.isRunning)
        listener.stop()
        #expect(!listener.isRunning)
        listener.stop()
        #expect(!listener.isRunning)
    }

    @Test func startWhileRunningIsANoOp() async {
        guard !(await tcpConnects()) else { return }
        let listener = makeListener()
        listener.start()
        let bound = await waitUntil { await tcpConnects() }
        #expect(bound)
        listener.start()
        #expect(listener.isRunning)
        listener.stop()
    }

    @Test func startStopStartBindsAgain() async {
        guard !(await tcpConnects()) else { return }

        let listener = makeListener()
        listener.start()
        let bound = await waitUntil { await tcpConnects() }
        #expect(bound)
        #expect(listener.isRunning)

        listener.stop()
        #expect(!listener.isRunning)
        _ = await waitUntil { await !tcpConnects() }

        listener.start()
        let rebound = await waitUntil { await tcpConnects() }
        #expect(rebound)
        #expect(listener.isRunning)
        listener.stop()
        #expect(!listener.isRunning)
    }

    @Test func stopIgnoresEventsAfterUnbind() async {
        guard !(await tcpConnects()) else { return }
        let store = SessionStore()
        let observer = FakeProcessExitObserver()
        let lifecycle = SessionLifecycleCoordinator(store: store, processObserver: observer)
        let token = "test-token"
        let listener = EventListener(
            lifecycle: lifecycle,
            processResolver: DarwinProcessIdentityResolver(),
            token: token
        )
        listener.start()
        #expect(await waitUntil { await tcpConnects() })

        listener.stop()
        #expect(!listener.isRunning)
        await postHook(token: token, event: "SessionStart", id: "after-stop")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(store.sessions.isEmpty)
    }

    @Test func authAcceptsTheCurrentTokenHeader() async {
        guard !(await tcpConnects()) else { return }

        let store = SessionStore()
        let observer = FakeProcessExitObserver()
        let lifecycle = SessionLifecycleCoordinator(store: store, processObserver: observer)
        let token = "test-token"
        let listener = EventListener(
            lifecycle: lifecycle,
            processResolver: DarwinProcessIdentityResolver(),
            token: token
        )
        listener.start()
        #expect(await waitUntil { await tcpConnects() })

        let id = "auth-X-LilAgents-Token"
        await postHook(token: token, header: "X-LilAgents-Token", event: "SessionStart", id: id)
        let accepted = await waitForSession(id, in: store)
        #expect(accepted, "X-LilAgents-Token should be accepted")

        listener.stop()
        _ = await waitUntil { await !tcpConnects() }
    }

    @Test func authRejectsAnUnknownTokenHeaderName() async {
        guard !(await tcpConnects()) else { return }

        let store = SessionStore()
        let observer = FakeProcessExitObserver()
        let lifecycle = SessionLifecycleCoordinator(store: store, processObserver: observer)
        let token = "test-token"
        let listener = EventListener(
            lifecycle: lifecycle,
            processResolver: DarwinProcessIdentityResolver(),
            token: token
        )
        listener.start()
        #expect(await waitUntil { await tcpConnects() })

        await postHook(token: token, header: "X-Some-Other-Token", event: "SessionStart", id: "rejected")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(store.sessions.isEmpty)

        listener.stop()
    }

    /// Polls for a session id on the main actor. The listener hands accepted
    /// events to the main actor asynchronously, so one is not visible the
    /// instant the HTTP response comes back.
    private func waitForSession(_ sessionID: String, in store: SessionStore) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if store.sessions.contains(where: { $0.id == sessionID }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return store.sessions.contains { $0.id == sessionID }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func postHook(
        token: String,
        header: String = "X-LilAgents-Token",
        event: String,
        id: String
    ) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(LilAgents.port)/event")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: header)
        request.timeoutInterval = 1
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "tool": "claude",
            "event": event,
            "session_id": id,
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func tcpConnects() async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ResumeOnce()
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: LilAgents.port)!,
                using: .tcp
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    box.resume(true, continuation)
                case .failed, .cancelled:
                    box.resume(false, continuation)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if connection.state != .ready {
                    connection.cancel()
                }
            }
        }
    }
}

/// Ensures a checked continuation is resumed exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ value: Bool, _ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
