import Foundation
import Testing
@testable import AgentDeck

@Suite struct ProcessIdentityResolverTests {
    @Test func resolvesCurrentProcessWithStartFingerprint() {
        let resolver = DarwinProcessIdentityResolver()

        guard case .running(let identity) = resolver.identity(for: getpid()) else {
            Issue.record("Expected the current process to be inspectable")
            return
        }

        #expect(identity.pid == getpid())
        #expect(identity.startSeconds > 0)
    }

    @Test func rejectsInvalidPID() {
        let resolver = DarwinProcessIdentityResolver()
        #expect(resolver.identity(for: 0) == .notFound)
        #expect(resolver.identity(for: 1) == .notFound)
    }

    /// pid 0 and 1 both return through the `pid > 1` guard without ever
    /// reaching `proc_pidinfo`, so the branch that actually distinguishes "the
    /// process is gone" from "we could not look at it" was unexercised — and
    /// that distinction is the whole never-kill-a-live-session contract.
    /// Collapsing it to `kill(pid, 0) == 0 ? .unavailable : .notFound` would
    /// make live sessions disappear on their next hook, with a green suite.
    @Test(.timeLimit(.minutes(1)))
    func reapedProcessResolvesToNotFoundRatherThanUnavailable() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()

        let resolver = DarwinProcessIdentityResolver()
        // Foundation reaps the child, so the pid is genuinely gone rather than
        // a zombie — the exact state an agent leaves behind when it exits.
        #expect(resolver.identity(for: child.processIdentifier) == .notFound)
    }
}

/// Returns a fixed lookup result regardless of pid, so the observation's
/// post-registration fingerprint check can be driven directly.
private struct StubProcessIdentityResolver: ProcessIdentityResolving {
    let result: ProcessLookupResult
    func identity(for pid: pid_t) -> ProcessLookupResult { result }
}

@MainActor
@Suite struct ProcessExitObserverTests {
    /// libdispatch already delivers an exit for a process that died before
    /// registration, which leaves the PID-REUSE branch as the only thing the
    /// post-registration check uniquely does — and it is the sole guard against
    /// a recycled pid pinning a row forever. `pruneStale(protecting:)` exempts
    /// process-backed rows, so losing this check resurrects the unremovable
    /// row this whole area exists to prevent.
    @Test(.timeLimit(.minutes(1)))
    func recycledPIDAtRegistrationEndsTheObservation() async {
        // A live pid, so the dispatch source registers cleanly, paired with a
        // start-time fingerprint that does not match: exactly what a reassigned
        // pid looks like.
        let observed = processIdentity(pid: getpid(), startSeconds: 1)
        let differentGeneration = processIdentity(pid: getpid(), startSeconds: 2)
        let observer = DispatchProcessExitObserver(
            resolver: StubProcessIdentityResolver(result: .running(differentGeneration))
        )

        var observation: (any ProcessObservation)?
        await withCheckedContinuation { continuation in
            observation = observer.observe(observed) { exited in
                #expect(exited == observed)
                continuation.resume()
            }
        }
        observation?.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func observesRealChildProcessExit() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }

        let resolver = DarwinProcessIdentityResolver()
        guard case .running(let identity) = resolver.identity(for: child.processIdentifier) else {
            Issue.record("Expected the child process to be inspectable")
            return
        }

        let observer = DispatchProcessExitObserver(resolver: resolver)
        var observation: (any ProcessObservation)?
        await withCheckedContinuation { continuation in
            observation = observer.observe(identity) { exited in
                #expect(exited == identity)
                continuation.resume()
            }
            child.terminate()
        }
        observation?.cancel()
    }
}
