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

    @Test func sessionEndThenStopDoesNotRevive() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))
        store.apply(makeEvent("SessionEnd"))
        store.apply(makeEvent("Stop"))
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

    @Test func sessionStartDoesNotCarryTerminalMetadataAcrossLifecycles() {
        let store = SessionStore()
        store.apply(makeEvent(
            "SessionStart",
            tty: "/dev/ttys001",
            terminal: "tmux",
            tmuxPane: "%1",
            tmuxSocket: "/tmp/tmux.sock"
        ))

        store.apply(makeEvent("SessionStart", tty: "/dev/ttys002"))

        let session = store.sessions[0]
        #expect(session.tty == "/dev/ttys002")
        #expect(session.terminal == .unknown)
        #expect(session.tmuxPane == nil)
        #expect(session.tmuxSocket == nil)
    }

    @Test func subagentStopDoesNotFlipStatus() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart"))       // working
        store.apply(makeEvent("SubagentStop"))
        #expect(status(store) == .working)           // unchanged, not idle
    }

    @Test func grokStopFailureAndStopCancelledGoIdle() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart", id: "fail", tool: "grok"))
        store.apply(makeEvent("StopFailure", id: "fail", tool: "grok"))
        #expect(status(store, "fail") == .idle)

        store.apply(makeEvent("SessionStart", id: "cancel", tool: "grok"))
        store.apply(makeEvent("StopCancelled", id: "cancel", tool: "grok"))
        #expect(status(store, "cancel") == .idle)
    }

    @Test func notificationTaskCompleteGoesIdle() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart", tool: "grok"))
        store.apply(makeEvent("Notification", tool: "grok", notification: "task_complete"))
        #expect(status(store) == .idle)
    }

    @Test func grokToolDisplayName() {
        #expect(AgentTool(rawValue: "grok")?.display == "Grok")
    }

    @Test func vendorLogoImagesLoad() {
        #expect(AgentTool.claude.logoImage != nil)
        #expect(AgentTool.codex.logoImage != nil)
        #expect(AgentTool.grok.logoImage != nil)
        #expect(AgentTool.unknown.logoImage == nil)
    }

    @Test func grokSessionEndStopDoesNotGoIdle() {
        let store = SessionStore()
        store.apply(makeEvent("SessionStart", tool: "grok"))
        store.apply(makeEvent("Stop", tool: "grok", reason: "channel_closed"))
        #expect(status(store) == .working)
        store.apply(makeEvent("Stop", tool: "grok", reason: "shutdown"))
        #expect(status(store) == .working)
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

        // A brand-new session reusing the same id must be able to notify
        // again. SessionStart is what opens the new lifecycle; a late Stop
        // from the ended one must not.
        store.apply(makeEvent("SessionStart"))
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

    @Test func protectedSessionsAreExemptFromTheSilenceHorizon() {
        let store = SessionStore()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        store.now = { clock }

        store.apply(makeEvent("SessionStart", id: "live"))
        store.apply(makeEvent("SessionStart", id: "unverifiable"))

        clock = clock.addingTimeInterval(AgentDeck.staleAfter + 1)
        store.pruneStale(protecting: ["live"])

        #expect(store.sessions.map(\.id) == ["live"])
    }
}
