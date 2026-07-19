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

        if var s = byID[id] {
            if let status { s.status = status }
            if let cwd = event.cwd, !cwd.isEmpty { s.cwd = cwd }
            if let tty = event.tty, !tty.isEmpty { s.tty = tty }
            s.lastUpdate = Date()
            byID[id] = s
        } else {
            byID[id] = Session(
                id: id,
                tool: event.agentTool,
                status: status ?? .working,
                cwd: event.cwd,
                tty: event.tty,
                lastUpdate: Date()
            )
        }
        rebuild()
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
