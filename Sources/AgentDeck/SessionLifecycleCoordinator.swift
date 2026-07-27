import Foundation

/// Reconciles hook lifecycles with their owning process and terminal pane.
/// Process bookkeeping lives here—not in the UI-facing Session model—so the
/// SessionStore remains a small, directly observable presentation state machine.
@MainActor
final class SessionLifecycleCoordinator {
    private enum PaneIdentity: Hashable {
        case tmux(socket: String, pane: String)
        case wezterm(socket: String, pane: String)
        case tty(String)
    }

    private struct Lifecycle {
        let id: String
        let tool: AgentTool
        var process: ProcessIdentity?
        var pane: PaneIdentity?
        var lastSeen: Date
        /// True for an agent with no controlling terminal of its own. Tracked
        /// so the rows can be retired the moment the user turns them off,
        /// rather than lingering until they happen to end.
        var isBackground: Bool = false
    }

    private struct PaneOwnerKey: Hashable {
        let pane: PaneIdentity
        let tool: AgentTool
    }

    /// Process ownership is scoped by tool for the same reason pane ownership
    /// is: one process can legitimately be the resolved owner of lifecycles
    /// belonging to different CLIs. A `codex` run nested inside a Claude Code
    /// session resolves — through a wrapper the forwarder can't attribute — to
    /// the parent `claude` PID. Keyed by PID alone, that codex SessionStart
    /// would find the parent Claude session as the incumbent owner and tear
    /// its row down, which the parent's next hook would immediately undo:
    /// two live sessions flapping over one key.
    private struct ProcessOwnerKey: Hashable {
        let process: ProcessIdentity
        let tool: AgentTool
    }

    private let store: SessionStore
    private let processObserver: any ProcessExitObserving

    private var lifecycleByID: [String: Lifecycle] = [:]
    private var sessionIDByProcess: [ProcessOwnerKey: String] = [:]
    private var sessionIDByPane: [PaneOwnerKey: String] = [:]
    private var observationByProcess: [ProcessOwnerKey: any ProcessObservation] = [:]
    private var pruneTimer: Timer?

    /// Test seam shared conceptually with SessionStore.now. Production uses
    /// wall time; tests advance both clocks deterministically.
    var now: () -> Date = { Date() }

    /// Whether agents with no terminal of their own are shown. A closure, not
    /// an `AppSettings` reference, so the coordinator keeps no dependency on
    /// the settings layer and tests can flip it without touching UserDefaults.
    /// Defaults to the shipped policy: hidden.
    var showsBackgroundSessions: () -> Bool = { false }

    var trackedLifecycleCount: Int { lifecycleByID.count }
    var trackedPaneCount: Int { sessionIDByPane.count }

    /// Retires every background row at once — what the Settings toggle calls
    /// when it is switched off, so those rows go immediately rather than
    /// hanging around until each one happens to end.
    func dropBackgroundSessions() {
        for id in lifecycleByID.values.filter(\.isBackground).map(\.id) {
            terminate(sessionID: id)
        }
    }

    init(store: SessionStore, processObserver: any ProcessExitObserving) {
        self.store = store
        self.processObserver = processObserver
        // Own the stale schedule so processless lifecycle indexes and the UI
        // store are pruned together. Process-backed lifecycles keep their exit
        // observation even when the old UI row ages out.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneStale() }
        }
    }

    /// Receives a decoded hook plus the process lookup captured by the listener
    /// before it replied to the hook request.
    func receive(_ event: HookEvent, processLookup: ProcessLookupResult?) {
        let id = event.resolvedSessionID

        // A headless owner is a scripted or nested run — `codex exec`, `claude
        // -p`, CI — with no pane behind it. There is nothing to jump to and
        // nobody waiting on it, and at the rate agents spawn other agents these
        // would swamp the real sessions. Dropped before any state is created,
        // so no later event can resurrect one — unless the user has asked to
        // see them (Settings → Sessions), since an agent hosted outside a
        // terminal is a real session to somebody.
        let isBackground = event.headless == true
        if isBackground, !showsBackgroundSessions() { return }

        if event.event == "SessionEnd" {
            receiveSessionEnd(event, id: id, processLookup: processLookup)
            return
        }

        if case .notFound? = processLookup {
            // The owner disappeared before its hook reached the main actor.
            // Never create a ghost row from an already-dead process.
            if let rawPID = event.agent_pid,
               let current = lifecycleByID[id]?.process,
               current.pid != rawPID {
                // This was a delayed event from an older owner after the same
                // session id was rebound to another live process.
                return
            }
            terminate(sessionID: id)
            return
        }

        let process: ProcessIdentity?
        if case .running(let identity)? = processLookup {
            process = identity
        } else {
            process = nil
        }

        if event.event == "SessionStart" {
            receiveSessionStart(
                event,
                id: id,
                process: process,
                inspectionFailed: {
                    if case .unavailable? = processLookup { return true }
                    return false
                }(),
                isBackground: isBackground
            )
        } else {
            store.apply(event)
            reconcileOwnership(
                for: event, id: id, process: process, isBackground: isBackground)
        }
    }

    private func receiveSessionEnd(
        _ event: HookEvent,
        id: String,
        processLookup: ProcessLookupResult?
    ) {
        guard let lifecycle = lifecycleByID[id] else {
            store.endLifecycle(id)
            return
        }

        // An ending from an older forwarder carries no owner PID. If this id
        // is now bound to a monitored process, the event cannot prove it
        // belongs to the current generation; let that process observation (or
        // a verifiable later SessionEnd) perform teardown instead.
        if event.agent_pid == nil, lifecycle.process != nil {
            return
        }
        if case .unavailable? = processLookup, lifecycle.process != nil {
            // A raw PID cannot distinguish generations when inspection fails.
            // The registered process source is the authoritative fallback.
            return
        }

        // Ignore a delayed ending from an older owner after this session id
        // has already been rebound to another process generation.
        if case .running(let identity)? = processLookup,
           let current = lifecycle.process,
           current != identity {
            return
        }
        if let rawPID = event.agent_pid,
           let current = lifecycle.process,
           current.pid != rawPID {
            return
        }

        terminate(sessionID: id)
    }

    private func receiveSessionStart(
        _ event: HookEvent,
        id: String,
        process: ProcessIdentity?,
        inspectionFailed: Bool,
        isBackground: Bool
    ) {
        let pane = Self.paneIdentity(for: event)

        // Inspection failure is not proof that the pane changed hands. When we
        // could not fingerprint the owner but this pane already has one, adopt
        // it: /clear inside a live CLI is overwhelmingly the case that gets
        // here, and treating the new lifecycle as processless would cancel the
        // incumbent's exit observation on a process that is still running —
        // leaving the replacement with no liveness signal at all, and the
        // process's eventual exit with nothing to reconcile. Consistent with
        // how SessionEnd already refuses to act on `.unavailable`.
        let process = process ?? (inspectionFailed
            ? inheritedProcess(
                forPane: pane,
                tool: event.agentTool,
                claimedPID: event.agent_pid
              )
            : nil)
        let owner = process.map { ProcessOwnerKey(process: $0, tool: event.agentTool) }
        var conflicts = Set<String>()

        if lifecycleByID[id] != nil {
            conflicts.insert(id)
        }
        if let owner,
           let incumbent = sessionIDByProcess[owner],
           incumbent != id {
            conflicts.insert(incumbent)
        }
        if let pane,
           let incumbent = sessionIDByPane[PaneOwnerKey(pane: pane, tool: event.agentTool)],
           incumbent != id {
            conflicts.insert(incumbent)
        }

        // Preserve an existing observation when /clear, /new, or /resume
        // starts a new session id inside the same long-lived CLI process.
        for conflict in conflicts {
            terminate(sessionID: conflict, preserving: owner)
        }

        store.apply(event)
        installLifecycle(Lifecycle(
            id: id,
            tool: event.agentTool,
            process: process,
            pane: pane,
            lastSeen: now(),
            isBackground: isBackground
        ))
    }

    /// The process bound to `pane` for `tool` — but ONLY when the event's own
    /// claimed pid agrees that it is the same process.
    ///
    /// Adopting the incumbent blindly binds a session to a process that is
    /// demonstrably not its own. Two ways that goes wrong, both real:
    ///
    ///  - The event says pid 206 and the pane's incumbent is 205. Inheriting
    ///    205 means 205's exit removes the new session, while 206 is never
    ///    watched at all.
    ///  - The pane's incumbent was `kill -9`'d and its exit notification is
    ///    queued but not yet delivered, so the pane index still names a dead
    ///    process. A new CLI starting in that pane would inherit the corpse's
    ///    identity AND its still-pending observation (`terminate(preserving:)`
    ///    keeps it deliberately), then delete itself when that exit lands.
    ///
    /// Requiring the pids to match rules out both. With no claimed pid there is
    /// nothing to corroborate, so we decline — which just leaves the lifecycle
    /// processless, exactly what an older forwarder produced anyway.
    private func inheritedProcess(
        forPane pane: PaneIdentity?,
        tool: AgentTool,
        claimedPID: pid_t?
    ) -> ProcessIdentity? {
        guard let claimedPID,
              let pane,
              let incumbent = sessionIDByPane[PaneOwnerKey(pane: pane, tool: tool)],
              let process = lifecycleByID[incumbent]?.process,
              process.pid == claimedPID
        else { return nil }
        return process
    }

    private func reconcileOwnership(
        for event: HookEvent,
        id: String,
        process: ProcessIdentity?,
        isBackground: Bool
    ) {
        let pane = Self.paneIdentity(for: event)
        let owner = process.map { ProcessOwnerKey(process: $0, tool: event.agentTool) }

        if let owner,
           let incumbent = sessionIDByProcess[owner],
           incumbent != id {
            terminate(sessionID: incumbent, preserving: owner)
        }

        if var lifecycle = lifecycleByID[id] {
            if let process, lifecycle.process != process {
                releaseProcess(lifecycle.process, tool: lifecycle.tool, ownedBy: id)
                lifecycle.process = process
            }
            if let pane, lifecycle.pane != pane {
                releasePane(lifecycle.pane, tool: lifecycle.tool, ownedBy: id)
                lifecycle.pane = pane
            }
            lifecycle.lastSeen = now()
            installLifecycle(lifecycle)
        } else {
            installLifecycle(Lifecycle(
                id: id,
                tool: event.agentTool,
                process: process,
                pane: pane,
                lastSeen: now(),
                isBackground: isBackground
            ))
        }
    }

    private func installLifecycle(_ lifecycle: Lifecycle) {
        lifecycleByID[lifecycle.id] = lifecycle
        if let pane = lifecycle.pane {
            sessionIDByPane[PaneOwnerKey(pane: pane, tool: lifecycle.tool)] = lifecycle.id
        }
        guard let process = lifecycle.process else { return }

        let owner = ProcessOwnerKey(process: process, tool: lifecycle.tool)
        sessionIDByProcess[owner] = lifecycle.id
        guard observationByProcess[owner] == nil else { return }
        let tool = lifecycle.tool
        observationByProcess[owner] = processObserver.observe(process) { [weak self] exited in
            self?.processDidExit(exited, tool: tool)
        }
    }

    private func processDidExit(_ identity: ProcessIdentity, tool: AgentTool) {
        let owner = ProcessOwnerKey(process: identity, tool: tool)
        guard let id = sessionIDByProcess[owner],
              lifecycleByID[id]?.process == identity
        else {
            observationByProcess.removeValue(forKey: owner)?.cancel()
            return
        }
        terminate(sessionID: id)
    }

    /// Drop UI rows that went silent and reclaim processless coordinator
    /// indexes on the same horizon. Forgetting coordinator state does not call
    /// endLifecycle: SessionStore retains its longer-lived notification and
    /// manual-dismissal suppression exactly as before.
    func pruneStale() {
        // A lifecycle with a monitored process has a real liveness signal, so
        // silence proves nothing about it: an agent someone left open and idle
        // for an afternoon is still a session they can jump back to. Only the
        // rows we cannot verify fall back to the silence horizon.
        let live = Set(lifecycleByID.values.lazy.filter { $0.process != nil }.map(\.id))
        store.pruneStale(protecting: live)
        let cutoff = now().addingTimeInterval(-AgentDeck.staleAfter)
        let staleIDs = lifecycleByID.values.compactMap { lifecycle in
            lifecycle.process == nil && lifecycle.lastSeen < cutoff
                ? lifecycle.id
                : nil
        }
        for id in staleIDs {
            forgetLifecycle(sessionID: id)
        }
    }

    /// One idempotent teardown path for SessionEnd, process exit, replacement,
    /// and a close-before-main-actor race.
    private func terminate(
        sessionID id: String,
        preserving preservedOwner: ProcessOwnerKey? = nil
    ) {
        guard let lifecycle = lifecycleByID.removeValue(forKey: id) else {
            store.endLifecycle(id)
            return
        }

        releasePane(lifecycle.pane, tool: lifecycle.tool, ownedBy: id)
        if let process = lifecycle.process {
            let owner = ProcessOwnerKey(process: process, tool: lifecycle.tool)
            if sessionIDByProcess[owner] == id {
                sessionIDByProcess[owner] = nil
                if owner != preservedOwner {
                    observationByProcess.removeValue(forKey: owner)?.cancel()
                }
            }
        }
        store.endLifecycle(id)
    }

    private func forgetLifecycle(sessionID id: String) {
        guard let lifecycle = lifecycleByID.removeValue(forKey: id) else { return }
        releasePane(lifecycle.pane, tool: lifecycle.tool, ownedBy: id)
        // Only processless lifecycles are forgotten by stale pruning today,
        // but keep this path correct if that policy broadens later.
        releaseProcess(lifecycle.process, tool: lifecycle.tool, ownedBy: id)
    }

    private func releaseProcess(_ process: ProcessIdentity?, tool: AgentTool, ownedBy id: String) {
        guard let process else { return }
        let owner = ProcessOwnerKey(process: process, tool: tool)
        guard sessionIDByProcess[owner] == id else { return }
        sessionIDByProcess[owner] = nil
        observationByProcess.removeValue(forKey: owner)?.cancel()
    }

    private func releasePane(_ pane: PaneIdentity?, tool: AgentTool, ownedBy id: String) {
        guard let pane else { return }
        let key = PaneOwnerKey(pane: pane, tool: tool)
        guard sessionIDByPane[key] == id else { return }
        sessionIDByPane[key] = nil
    }

    private static func paneIdentity(for event: HookEvent) -> PaneIdentity? {
        if let socket = nonempty(event.tmux_socket),
           let pane = nonempty(event.tmux_pane) {
            return .tmux(socket: socket, pane: pane)
        }
        if let socket = nonempty(event.wezterm_socket),
           let pane = nonempty(event.wezterm_pane) {
            return .wezterm(socket: socket, pane: pane)
        }
        guard let tty = nonempty(event.tty) else { return nil }
        return .tty(tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    isolated deinit {
        pruneTimer?.invalidate()
    }
}
