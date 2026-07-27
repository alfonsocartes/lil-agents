import Foundation
import Testing
@testable import AgentDeck

@MainActor
@Suite struct SessionLifecycleCoordinatorTests {
    private func makeSystem() -> (
        store: SessionStore,
        observer: FakeProcessExitObserver,
        lifecycle: SessionLifecycleCoordinator
    ) {
        let store = SessionStore()
        let observer = FakeProcessExitObserver()
        return (
            store,
            observer,
            SessionLifecycleCoordinator(store: store, processObserver: observer)
        )
    }

    @Test func processExitRemovesSessionWithoutSessionEnd() {
        let system = makeSystem()
        let process = processIdentity(pid: 101)

        system.lifecycle.receive(
            makeEvent("SessionStart", agentPID: process.pid),
            processLookup: .running(process)
        )
        #expect(system.store.sessions.map(\.id) == ["s1"])

        system.observer.emitExit(for: process)
        #expect(system.store.sessions.isEmpty)
    }

    @Test func sameProcessSessionStartTransfersObservation() {
        let system = makeSystem()
        let process = processIdentity(pid: 102)

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "old", agentPID: process.pid),
            processLookup: .running(process)
        )
        system.lifecycle.receive(
            makeEvent("SessionStart", id: "new", agentPID: process.pid),
            processLookup: .running(process)
        )

        #expect(system.store.sessions.map(\.id) == ["new"])
        #expect(system.observer.observeCount[process] == 1)
        #expect(system.observer.cancelCount[process, default: 0] == 0)

        system.observer.emitExit(for: process)
        #expect(system.store.sessions.isEmpty)
    }

    @Test func samePaneNewProcessReplacesPreviousLifecycle() {
        let system = makeSystem()
        let oldProcess = processIdentity(pid: 103)
        let newProcess = processIdentity(pid: 104)

        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "old", tty: "/dev/ttys009",
                agentPID: oldProcess.pid
            ),
            processLookup: .running(oldProcess)
        )
        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "new", tty: "ttys009",
                agentPID: newProcess.pid
            ),
            processLookup: .running(newProcess)
        )

        #expect(system.store.sessions.map(\.id) == ["new"])
        #expect(system.observer.cancelCount[oldProcess] == 1)

        // A callback already queued for the cancelled old observation cannot
        // remove the replacement now occupying that pane.
        system.observer.emitExit(for: oldProcess)
        #expect(system.store.sessions.map(\.id) == ["new"])
    }

    @Test func recycledPIDOldGenerationCannotRemoveNewGeneration() {
        let system = makeSystem()
        let generationA = processIdentity(pid: 105, startSeconds: 1)
        let generationB = processIdentity(pid: 105, startSeconds: 2)

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "same", agentPID: generationA.pid),
            processLookup: .running(generationA)
        )
        system.lifecycle.receive(
            makeEvent("SessionStart", id: "same", agentPID: generationB.pid),
            processLookup: .running(generationB)
        )

        system.observer.emitExit(for: generationA)
        #expect(system.store.sessions.map(\.id) == ["same"])

        system.observer.emitExit(for: generationB)
        #expect(system.store.sessions.isEmpty)
    }

    @Test func delayedDeadOwnerEventCannotRemoveReboundSessionID() {
        let system = makeSystem()
        let oldProcess = processIdentity(pid: 111)
        let newProcess = processIdentity(pid: 112)

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "same", agentPID: oldProcess.pid),
            processLookup: .running(oldProcess)
        )
        system.lifecycle.receive(
            makeEvent("SessionStart", id: "same", agentPID: newProcess.pid),
            processLookup: .running(newProcess)
        )

        system.lifecycle.receive(
            makeEvent("Stop", id: "same", agentPID: oldProcess.pid),
            processLookup: .notFound
        )

        #expect(system.store.sessions.map(\.id) == ["same"])
    }

    @Test func explicitSessionEndCancelsObservation() {
        let system = makeSystem()
        let process = processIdentity(pid: 106)

        system.lifecycle.receive(
            makeEvent("SessionStart", agentPID: process.pid),
            processLookup: .running(process)
        )
        system.lifecycle.receive(
            makeEvent("SessionEnd", agentPID: process.pid),
            processLookup: .running(process)
        )

        #expect(system.store.sessions.isEmpty)
        #expect(system.observer.cancelCount[process] == 1)

        system.observer.emitExit(for: process)
        #expect(system.store.sessions.isEmpty)
    }

    @Test func PIDLessOldSessionEndCannotRemoveProcessBoundReplacement() {
        let system = makeSystem()
        let process = processIdentity(pid: 113)

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "same", agentPID: process.pid),
            processLookup: .running(process)
        )
        system.lifecycle.receive(
            makeEvent("SessionEnd", id: "same"),
            processLookup: nil
        )

        #expect(system.store.sessions.map(\.id) == ["same"])

        system.observer.emitExit(for: process)
        #expect(system.store.sessions.isEmpty)
    }

    @Test func uninspectableSessionEndCannotRemoveProcessBoundLifecycle() {
        let system = makeSystem()
        let process = processIdentity(pid: 114)

        system.lifecycle.receive(
            makeEvent("SessionStart", agentPID: process.pid),
            processLookup: .running(process)
        )
        system.lifecycle.receive(
            makeEvent("SessionEnd", agentPID: process.pid),
            processLookup: .unavailable(error: EPERM)
        )

        #expect(system.store.sessions.map(\.id) == ["s1"])
        system.observer.emitExit(for: process)
        #expect(system.store.sessions.isEmpty)
    }

    @Test func manualDismissalIsCleanedWhenProcessExits() {
        let system = makeSystem()
        let process = processIdentity(pid: 107)

        system.lifecycle.receive(
            makeEvent("SessionStart", agentPID: process.pid),
            processLookup: .running(process)
        )
        system.store.remove("s1")
        system.lifecycle.receive(
            makeEvent("Stop", agentPID: process.pid),
            processLookup: .running(process)
        )
        #expect(system.store.sessions.isEmpty)

        system.observer.emitExit(for: process)

        // A later lifecycle may reuse the id because exit cleared the hidden
        // lifecycle's dismissal tombstone.
        let nextProcess = processIdentity(pid: 108)
        system.lifecycle.receive(
            makeEvent("SessionStart", agentPID: nextProcess.pid),
            processLookup: .running(nextProcess)
        )
        #expect(system.store.sessions.map(\.id) == ["s1"])
    }

    @Test func alreadyExitedProcessDoesNotCreateGhostSession() {
        let system = makeSystem()

        system.lifecycle.receive(
            makeEvent("SessionStart", agentPID: 109),
            processLookup: .notFound
        )

        #expect(system.store.sessions.isEmpty)
        #expect(system.observer.observeCount.isEmpty)
    }

    @Test func unavailableInspectionKeepsSessionForFallbackPruning() {
        let system = makeSystem()

        system.lifecycle.receive(
            makeEvent("SessionStart", agentPID: 110),
            processLookup: .unavailable(error: EPERM)
        )

        #expect(system.store.sessions.map(\.id) == ["s1"])
        #expect(system.observer.observeCount.isEmpty)
    }

    @Test func staleProcesslessLifecycleIndexesAreReclaimed() {
        let system = makeSystem()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        system.store.now = { clock }
        system.lifecycle.now = { clock }

        system.lifecycle.receive(
            makeEvent("SessionStart", tty: "ttys030"),
            processLookup: nil
        )
        #expect(system.lifecycle.trackedLifecycleCount == 1)
        #expect(system.lifecycle.trackedPaneCount == 1)

        clock = clock.addingTimeInterval(AgentDeck.staleAfter + 1)
        system.lifecycle.pruneStale()

        #expect(system.store.sessions.isEmpty)
        #expect(system.lifecycle.trackedLifecycleCount == 0)
        #expect(system.lifecycle.trackedPaneCount == 0)
    }

    @Test func differentToolsCanCoexistOnSameTTY() {
        let system = makeSystem()

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "claude", tool: "claude", tty: "ttys010"),
            processLookup: nil
        )
        system.lifecycle.receive(
            makeEvent("SessionStart", id: "codex", tool: "codex", tty: "/dev/ttys010"),
            processLookup: nil
        )

        #expect(Set(system.store.sessions.map(\.id)) == ["claude", "codex"])
    }

    @Test func paneReplacementIsTrackedIndependentlyPerTool() {
        let system = makeSystem()

        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "claude-old", tool: "claude",
                tty: "ttys010"
            ),
            processLookup: nil
        )
        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "codex", tool: "codex",
                tty: "ttys010"
            ),
            processLookup: nil
        )
        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "claude-new", tool: "claude",
                tty: "ttys010"
            ),
            processLookup: nil
        )

        #expect(Set(system.store.sessions.map(\.id)) == ["claude-new", "codex"])
    }

    /// A `codex` run nested inside a Claude Code session can resolve to the
    /// PARENT claude PID (the forwarder walks past wrappers it can't name).
    /// Process ownership keyed by PID alone let that codex SessionStart evict
    /// the live parent Claude row — which the parent's next hook put back,
    /// then the next codex run removed again.
    @Test func nestedToolSharingOwnerPIDDoesNotEvictParentSession() {
        let system = makeSystem()
        let shared = processIdentity(pid: 201)

        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "parent-claude", tool: "claude",
                tty: "ttys003", agentPID: shared.pid
            ),
            processLookup: .running(shared)
        )
        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "nested-codex", tool: "codex",
                tty: "ttys003", agentPID: shared.pid
            ),
            processLookup: .running(shared)
        )

        #expect(Set(system.store.sessions.map(\.id)) == ["parent-claude", "nested-codex"])

        // The shared process really exiting still ends both.
        system.observer.emitExit(for: shared)
        #expect(system.store.sessions.isEmpty)
    }

    /// Ending one tool's lifecycle must not cancel the other tool's exit
    /// observation on the same PID — otherwise the survivor silently loses its
    /// only liveness signal and reverts to hour-long stale pruning.
    @Test func endingOneToolKeepsTheOtherToolsObservationOnSharedPID() {
        let system = makeSystem()
        let shared = processIdentity(pid: 202)

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "claude", tool: "claude", agentPID: shared.pid),
            processLookup: .running(shared)
        )
        system.lifecycle.receive(
            makeEvent("SessionStart", id: "codex", tool: "codex", agentPID: shared.pid),
            processLookup: .running(shared)
        )
        // One observation per (process, tool) — not one shared slot that the
        // second SessionStart would have taken over.
        #expect(system.observer.observeCount[shared] == 2)

        system.lifecycle.receive(
            makeEvent("SessionEnd", id: "codex", tool: "codex", agentPID: shared.pid),
            processLookup: .running(shared)
        )

        #expect(system.store.sessions.map(\.id) == ["claude"])
        // Only the codex observation was cancelled; claude's is still armed.
        #expect(system.observer.cancelCount[shared] == 1)

        system.observer.emitExit(for: shared)
        #expect(system.store.sessions.isEmpty)
    }

    /// Scripted/nested runs (`codex exec`, `claude -p`, CI) have no pane to
    /// jump to and nobody waiting on them. They must never reach the overlay,
    /// and no later event may resurrect one.
    @Test func headlessRunsAreNeverTracked() {
        let system = makeSystem()
        let process = processIdentity(pid: 203)

        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            system.lifecycle.receive(
                makeEvent(
                    event, id: "exec", tool: "codex", cwd: "/private/tmp",
                    agentPID: process.pid, headless: true
                ),
                processLookup: .running(process)
            )
        }

        #expect(system.store.sessions.isEmpty)
        #expect(system.lifecycle.trackedLifecycleCount == 0)
        #expect(system.observer.observeCount.isEmpty)
    }

    @Test func interactiveRunsAreStillTrackedWhenHeadlessIsAbsentOrFalse() {
        let system = makeSystem()

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "explicit", tool: "codex", headless: false),
            processLookup: nil
        )
        system.lifecycle.receive(
            makeEvent("SessionStart", id: "legacy", tool: "codex", tty: "ttys041"),
            processLookup: nil
        )

        #expect(Set(system.store.sessions.map(\.id)) == ["explicit", "legacy"])
    }

    /// Silence is not death. A session whose process is still being watched
    /// must survive the stale sweep however long it sits idle — pruning it
    /// dropped live agents off the list while dead ones lingered their hour.
    @Test func liveProcessBackedSessionSurvivesStalePruning() {
        let system = makeSystem()
        var clock = Date(timeIntervalSince1970: 2_000_000)
        system.store.now = { clock }
        system.lifecycle.now = { clock }
        let process = processIdentity(pid: 204)

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "quiet", agentPID: process.pid),
            processLookup: .running(process)
        )

        clock = clock.addingTimeInterval(AgentDeck.staleAfter * 3)
        system.lifecycle.pruneStale()

        #expect(system.store.sessions.map(\.id) == ["quiet"])
        #expect(system.lifecycle.trackedLifecycleCount == 1)

        // It still goes away the moment the process actually exits.
        system.observer.emitExit(for: process)
        #expect(system.store.sessions.isEmpty)
    }

    /// `/clear` in a live CLI while process inspection happens to fail must not
    /// cost the session its liveness signal: treating the replacement as
    /// processless cancels an observation on a process that is still running.
    @Test func unavailableInspectionAtSessionStartInheritsThePanesProcess() {
        let system = makeSystem()
        var clock = Date(timeIntervalSince1970: 3_000_000)
        system.store.now = { clock }
        system.lifecycle.now = { clock }
        let process = processIdentity(pid: 205)

        system.lifecycle.receive(
            makeEvent("SessionStart", id: "before", tty: "ttys050", agentPID: process.pid),
            processLookup: .running(process)
        )
        // Same pane, new session id, but the owner can't be fingerprinted.
        system.lifecycle.receive(
            makeEvent("SessionStart", id: "after", tty: "ttys050", agentPID: process.pid),
            processLookup: .unavailable(error: EPERM)
        )

        #expect(system.store.sessions.map(\.id) == ["after"])
        // The observation was handed over, not cancelled and dropped.
        #expect(system.observer.cancelCount[process, default: 0] == 0)

        // It survives the silence horizon, because it is still process-backed.
        clock = clock.addingTimeInterval(AgentDeck.staleAfter * 2)
        system.lifecycle.pruneStale()
        #expect(system.store.sessions.map(\.id) == ["after"])

        // And the process exiting still ends it.
        system.observer.emitExit(for: process)
        #expect(system.store.sessions.isEmpty)
    }

    @Test func tmuxHostTTYDoesNotCollapseIndependentPanes() {
        let system = makeSystem()

        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "one", terminal: "tmux",
                tmuxPane: "%1", tmuxSocket: "/tmp/tmux.sock",
                hostTTY: "/dev/ttys020"
            ),
            processLookup: nil
        )
        system.lifecycle.receive(
            makeEvent(
                "SessionStart", id: "two", terminal: "tmux",
                tmuxPane: "%2", tmuxSocket: "/tmp/tmux.sock",
                hostTTY: "/dev/ttys020"
            ),
            processLookup: nil
        )

        #expect(Set(system.store.sessions.map(\.id)) == ["one", "two"])
    }
}
