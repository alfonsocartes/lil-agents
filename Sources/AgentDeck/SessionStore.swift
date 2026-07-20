import Foundation
import Combine

/// Holds the set of live sessions and applies incoming hook events to drive
/// each session's status. Main-actor bound — the UI observes it directly.
@MainActor
final class SessionStore: ObservableObject {
    /// Sessions sorted for display: attention-needing first, then working, then idle.
    @Published private(set) var sessions: [Session] = []

    private var byID: [String: Session] = [:]
    private var pruneTimer: Timer?

    /// Last attention-state we actually fired a notification for, per
    /// session id. This does NOT mean "notify once per session" — it
    /// suppresses a repeat notification for the SAME status only when no
    /// intervening work happened, i.e. only until the next transition into
    /// `.working` (see `apply`, which clears the entry there) or an explicit
    /// `SessionEnd`. That's what makes it safe: a live session that goes
    /// idle → working → idle again notifies both times, because the
    /// `.working` heartbeat in between clears the entry.
    ///
    /// It exists as a layer independent of `byID` because `pruneStale` drops
    /// idle/waiting sessions from `byID` after `AgentDeck.staleAfter` (1hr)
    /// of silence — if the CLI later emits another heartbeat for the SAME
    /// session_id with the SAME status (no `.working` in between, since the
    /// session was pruned precisely because it went quiet), `byID[id]` is
    /// nil, `previousStatus` looks like a brand-new session, and without
    /// this map `notifyIfNeeded` would fire a second "finished its turn"
    /// notification for a turn that ended an hour ago. Cleared on an
    /// explicit `SessionEnd` so a genuinely new session that recycles the
    /// same id can notify again, and aged out (on a much longer horizon than
    /// `byID` itself) in `pruneStale` so a session that never gets an
    /// explicit `SessionEnd` — e.g. the CLI crashed — can't leak an entry
    /// here forever.
    private var lastNotified: [String: (status: SessionStatus, at: Date)] = [:]

    /// Fires a system notification on attention transitions (see
    /// `notifyIfNeeded` below). Optional so SessionStore carries no hard
    /// dependency on UserNotifications (e.g. for tests) — AppDelegate wires
    /// this in before the listener starts.
    var notifier: Notifier?

    /// Aggregate state across all sessions — drives the menu bar / header icon.
    /// Priority (most attention-worthy first): needsInput > idle > working > none.
    enum Attention { case needsInput, idle, working, none }

    var attention: Attention {
        if sessions.contains(where: { $0.status == .waitingApproval }) { return .needsInput }
        if sessions.contains(where: { $0.status == .idle }) { return .idle }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        return .none
    }

    init() {
        // Periodically drop sessions that went silent (missed SessionEnd).
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneStale() }
        }
    }

    /// Apply a single hook event. Called on the main actor from the listener.
    func apply(_ event: HookEvent) {
        let id = event.session_id ?? "\(event.tool):\(event.tty ?? "?")"

        switch event.event {
        case "SessionEnd":
            byID[id] = nil
            // A genuinely new session can reuse this id later — clear the
            // notify-suppression entry too so it can notify again (see
            // `lastNotified`'s doc comment above).
            lastNotified[id] = nil
            rebuild()
            return
        case "SubagentStop":
            // A subagent finished — the parent session is still working. Touch
            // only the timestamp so it isn't pruned, don't flip to idle.
            if var s = byID[id] { s.lastUpdate = Date(); byID[id] = s; rebuild() }
            return
        default:
            break
        }

        let status = Self.status(for: event)
        // nil for a session seen for the first time — treated as "no prior
        // attention state" below, so a session that arrives already idle or
        // waitingApproval still notifies once.
        let previousStatus = byID[id]?.status

        if var s = byID[id] {
            if let status { s.status = status }
            if let cwd = event.cwd, !cwd.isEmpty { s.cwd = cwd }
            if let tty = event.tty, !tty.isEmpty { s.tty = tty }
            if event.terminalKind != .unknown { s.terminal = event.terminalKind }
            if let v = event.wezterm_pane, !v.isEmpty { s.weztermPane = v }
            if let v = event.wezterm_socket, !v.isEmpty { s.weztermSocket = v }
            if let v = event.wezterm_exe, !v.isEmpty { s.weztermExe = v }
            if let v = event.tmux_pane, !v.isEmpty { s.tmuxPane = v }
            if let v = event.tmux_socket, !v.isEmpty { s.tmuxSocket = v }
            if let v = event.tmux_host, let kind = TerminalKind(rawValue: v) { s.tmuxHost = kind }
            if let v = event.host_tty, !v.isEmpty { s.hostTTY = v }
            s.lastUpdate = Date()
            byID[id] = s
        } else {
            byID[id] = Session(
                id: id,
                tool: event.agentTool,
                status: status ?? .working,
                cwd: event.cwd,
                tty: event.tty,
                lastUpdate: Date(),
                terminal: event.terminalKind,
                weztermPane: event.wezterm_pane,
                weztermSocket: event.wezterm_socket,
                weztermExe: event.wezterm_exe,
                tmuxPane: event.tmux_pane,
                tmuxSocket: event.tmux_socket,
                tmuxHost: event.tmux_host.flatMap(TerminalKind.init(rawValue:)),
                hostTTY: event.host_tty
            )
        }

        // A transition into `.working` means real work is happening again —
        // any stale suppression entry for this id no longer applies. Checked
        // against the merged/created session's *actual* status (not the
        // local `status` var) so this applies uniformly to both the
        // existing-session branch above (where `status` may be nil and the
        // prior status carries over unchanged) and the new-session branch
        // (where a nil `status` still resolves to `.working`). See
        // `lastNotified`'s doc comment for what this suppression layer means.
        if byID[id]?.status == .working {
            lastNotified[id] = nil
        }

        rebuild()
        notifyIfNeeded(id: id, previousStatus: previousStatus)
    }

    /// Fires the notifier on each transition INTO an attention state
    /// (working → idle/waitingApproval, or a brand-new session that arrives
    /// already in one of those states). Never fires for `.working`, and
    /// never re-fires while a session stays in the same attention state
    /// across subsequent events (e.g. repeated Notification events while
    /// still waitingApproval) — but DOES fire again for a later, separate
    /// idle/waitingApproval transition once the session has passed back
    /// through `.working` in between. This is not "once per session, ever":
    /// a session that finishes its turn multiple times notifies multiple
    /// times, as long as each finish is preceded by renewed work.
    ///
    /// `previousStatus` (derived from in-memory `byID`) isn't sufficient on
    /// its own: it goes back to nil once `pruneStale` drops the session, so
    /// a later heartbeat for the same session_id looks like a brand-new
    /// session again. The `lastNotified[id]` checks below are an additional
    /// suppression layer on top of the existing transition-once logic — they
    /// only matter when no `.working` heartbeat has been observed since the
    /// last notification for this id (see `apply`, which clears the entry on
    /// every transition into `.working`, and `lastNotified`'s doc comment
    /// for the full rationale). They don't change behavior for the normal
    /// in-memory case; they only stop a duplicate notification from firing
    /// after `byID` has forgotten the session but no genuine new work
    /// happened.
    private func notifyIfNeeded(id: String, previousStatus: SessionStatus?) {
        guard let session = byID[id] else { return }
        if session.status == .waitingApproval, previousStatus != .waitingApproval,
           lastNotified[id]?.status != .waitingApproval {
            notifier?.notify(session: session, reason: .approval)
            lastNotified[id] = (status: .waitingApproval, at: Date())
        } else if session.status == .idle, previousStatus != .idle,
                  lastNotified[id]?.status != .idle {
            notifier?.notify(session: session, reason: .idle)
            lastNotified[id] = (status: .idle, at: Date())
        }
    }

    /// Map an event to a status transition, or nil to leave status unchanged.
    private static func status(for event: HookEvent) -> SessionStatus? {
        switch event.event {
        case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .working
        case "PermissionRequest":                       // Codex
            return .waitingApproval
        case "Notification":
            switch event.notification_type {
            case "permission_prompt", "agent_needs_input":
                return .waitingApproval
            case "idle_prompt", "agent_completed":
                return .idle
            default:
                return nil                              // unknown notification: no change
            }
        case "Stop":
            return .idle
        default:
            return nil
        }
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-AgentDeck.staleAfter)
        let before = byID.count
        byID = byID.filter { $0.value.lastUpdate >= cutoff }
        if byID.count != before { rebuild() }

        // Bound `lastNotified`'s growth for sessions that never get an
        // explicit SessionEnd (e.g. the CLI crashed). Use a much longer
        // horizon than `byID`'s own staleAfter so the "heartbeat arrives
        // after byID already pruned it" suppression case above keeps
        // working across realistic gaps, while still guaranteeing this map
        // can't grow unboundedly over a long-running AgentDeck process.
        let notifiedCutoff = Date().addingTimeInterval(-AgentDeck.staleAfter * 24)
        lastNotified = lastNotified.filter { $0.value.at >= notifiedCutoff }
    }

    private func rebuild() {
        sessions = byID.values.sorted { a, b in
            func rank(_ s: SessionStatus) -> Int {
                switch s {
                case .waitingApproval: return 0
                case .idle: return 1        // idle = "waiting for you", surface above working
                case .working: return 2
                }
            }
            let ra = rank(a.status), rb = rank(b.status)
            if ra != rb { return ra < rb }
            return a.lastUpdate > b.lastUpdate
        }
    }
}

#if DEBUG
extension SessionStore {
    /// Preview-only: a store pre-seeded with fixed sessions, bypassing the event
    /// pipeline. Lives in this file so it can reach the file-private `sessions`
    /// setter. Never compiled into release.
    static func previewStore(_ sessions: [Session]) -> SessionStore {
        let store = SessionStore()
        store.sessions = sessions
        return store
    }
}
#endif
