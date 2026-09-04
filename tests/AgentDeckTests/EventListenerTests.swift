import Foundation
import Network
import Testing
@testable import AgentDeck

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

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
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
