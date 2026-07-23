import Foundation
import Testing
@testable import AgentDeck

@MainActor
@Suite struct SessionStoreStateMachineTests {
    private func status(_ store: SessionStore, _ id: String = "s1") -> SessionStatus? {
        store.sessions.first { $0.id == id }?.status
    }

    @Test func sessionStartAndPreToolUseGoWorking() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))
        #expect(status(store) == .working)
        store.apply(makeEvent("PreToolUse"))
        #expect(status(store) == .working)
    }

    @Test func notificationPermissionGoesWaitingApproval() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))
        store.apply(makeEvent("Notification", notification: "permission_prompt"))
        #expect(status(store) == .waitingApproval)
    }

    @Test func codexPermissionRequestGoesWaitingApproval() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart", tool: "codex"))
        store.apply(makeEvent("PermissionRequest", tool: "codex"))
        #expect(status(store) == .waitingApproval)
    }

    @Test func stopGoesIdle() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))
        store.apply(makeEvent("Stop"))
        #expect(status(store) == .idle)
    }

    @Test func sessionEndRemovesSession() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))
        #expect(!store.sessions.isEmpty)
        store.apply(makeEvent("SessionEnd"))
        #expect(store.sessions.isEmpty)
    }

    @Test func removeHidesSessionUntilThatSessionEnds() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))

        store.remove("s1")
        #expect(store.sessions.isEmpty)

        // A still-running agent emits more hook events, but a manually removed
        // session should stay out of both live surfaces until it ends.
        store.apply(makeEvent("Stop"))
        #expect(store.sessions.isEmpty)

        store.apply(makeEvent("SessionEnd"))
        #expect(store.sessions.isEmpty)
    }

    @Test func newSessionWithReusedIDCanAppearAfterRemoval() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))
        store.remove("s1")

        // SessionStart marks a new lifecycle, even if a CLI reuses the id.
        store.apply(makeEvent("SessionStart"))
        #expect(store.sessions.map(\.id) == ["s1"])
    }

    @Test func subagentStopDoesNotFlipStatus() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))       // working
        store.apply(makeEvent("SubagentStop"))
        #expect(status(store) == .working)           // unchanged, not idle
    }
}

@MainActor
@Suite struct SessionStoreNotifyOnceTests {
    @Test func idleTransitionNotifiesOnceAndAgainAfterWork() {
        let store = SessionStore()
        let spy = SpyNotifier()
        store.notifier = spy

        store.apply(makeEvent("SessionStart"))       // working -> no notify
        #expect(spy.count == 0)

        store.apply(makeEvent("Stop"))               // -> idle, notify once
        #expect(spy.reasons == [.idle])

        store.apply(makeEvent("Stop"))               // still idle, no re-notify
        #expect(spy.count == 1)

        // idle -> working -> idle must notify AGAIN (the lastNotified reset on
        // .working — this exact regression shipped once).
        store.apply(makeEvent("PreToolUse"))         // working, clears suppression
        store.apply(makeEvent("Stop"))               // -> idle, notify again
        #expect(spy.reasons == [.idle, .idle])
    }

    @Test func approvalTransitionIsSymmetric() {
        let store = SessionStore()
        let spy = SpyNotifier()
        store.notifier = spy

        store.apply(makeEvent("SessionStart"))
        store.apply(makeEvent("Notification", notification: "permission_prompt"))
        #expect(spy.reasons == [.approval])

        store.apply(makeEvent("Notification", notification: "permission_prompt"))
        #expect(spy.count == 1)                      // still waiting, no re-notify

        store.apply(makeEvent("PreToolUse"))         // working, clears suppression
        store.apply(makeEvent("Notification", notification: "permission_prompt"))
        #expect(spy.reasons == [.approval, .approval])
    }

    @Test func sessionEndClearsSuppression() {
        let store = SessionStore()
        let spy = SpyNotifier()
        store.notifier = spy

        store.apply(makeEvent("SessionStart"))
        store.apply(makeEvent("Stop"))               // idle notify (1)
        #expect(spy.count == 1)

        store.apply(makeEvent("SessionEnd"))         // removes + clears lastNotified

        // A brand-new session reusing the same id, arriving already idle, must
        // be able to notify again.
        store.apply(makeEvent("Stop"))
        #expect(spy.count == 2)
    }
}

@MainActor
@Suite struct SessionStorePruneTests {
    @Test func suppressionSurvivesPruneButRenewedWorkNotifies() {
        let store = SessionStore()
        let spy = SpyNotifier()
        store.notifier = spy

        var clock = Date(timeIntervalSince1970: 1_000_000)
        store.now = { clock }

        store.apply(makeEvent("SessionStart"))       // working @ t0
        store.apply(makeEvent("Stop"))               // idle @ t0, notify (1)
        #expect(spy.count == 1)

        // Advance past staleAfter (but within the much longer lastNotified
        // horizon), then prune: byID drops the session, suppression survives.
        clock = clock.addingTimeInterval(AgentDeck.staleAfter + 1)
        store.pruneStale()
        #expect(store.sessions.isEmpty)

        // Re-seen with an idle heartbeat — must NOT re-notify (an hour-old turn).
        store.apply(makeEvent("Stop"))
        #expect(spy.count == 1)

        // But genuine resurrection -> working -> idle DOES notify again.
        store.apply(makeEvent("PreToolUse"))
        store.apply(makeEvent("Stop"))
        #expect(spy.count == 2)
    }
}
