import Foundation
import Network
import Testing
@testable import AgentDeck

/// Serialized so two tests never bind 54173 at once. Skip bind-again if
/// something else (a live lil agents) already owns the port.
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

    @Test func startStopStartBindsAgain() async {
        if await tcpConnects() {
            return
        }

        let listener = makeListener()
        listener.start()
        let bound = await waitUntil { await tcpConnects() }
        guard bound else {
            listener.stop()
            return
        }
        #expect(listener.isRunning)

        listener.stop()
        #expect(!listener.isRunning)
        _ = await waitUntil { await !tcpConnects() }

        if await tcpConnects() {
            return
        }

        listener.start()
        let rebound = await waitUntil { await tcpConnects() }
        guard rebound else {
            listener.stop()
            return
        }
        #expect(listener.isRunning)
        listener.stop()
        #expect(!listener.isRunning)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func tcpConnects() async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ResumeOnce()
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: AgentDeck.port)!,
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
