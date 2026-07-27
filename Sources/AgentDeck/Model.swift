import Foundation

/// Which AI CLI a session belongs to.
enum AgentTool: String, Codable {
    case claude
    case codex
    case unknown

    var display: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .unknown: return "Agent"
        }
    }

    /// SF Symbol used as the per-tool glyph in a row.
    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .unknown: return "terminal"
        }
    }
}

/// Coarse lifecycle status shown in the overlay.
enum SessionStatus: String, Codable {
    /// Actively processing a turn / running a tool.
    case working
    /// Blocked on a permission / approval prompt — needs the user now.
    case waitingApproval
    /// Turn finished; waiting for the user's next prompt.
    case idle
}

/// Which terminal emulator (or multiplexer) hosts a session's pane, as detected
/// by the hook forwarder script (see HookInstaller.swift's generated bash).
/// Mirrors the `AgentTool` pattern: `HookEvent.terminal` stays a raw `String?`
/// and is mapped here via `TerminalKind(rawValue:) ?? .unknown` rather than
/// decoded directly, so an unrecognized or missing value never fails the whole
/// `HookEvent` decode — old forwarders that don't send `terminal` at all decode
/// just fine and land on `.unknown`.
enum TerminalKind: String, Codable {
    case iterm2
    case appleTerminal = "apple_terminal"
    case wezterm
    case tmux
    case ghostty
    case unknown
}

/// The wire format posted by installed CLI hooks to `POST /event`.
/// The forwarder script merges the hook's stdin JSON with the captured tty,
/// owning CLI PID, and (best-effort) terminal-detection fields.
struct HookEvent: Codable, Sendable {
    var tool: String
    var event: String
    var session_id: String?
    var cwd: String?
    var tty: String?
    var notification_type: String?
    /// PID of the long-lived Claude/Codex process that owns this lifecycle.
    /// Optional so events from an older installed forwarder remain decodable.
    var agent_pid: Int32?
    /// True when the owning CLI has no controlling terminal of its own — a
    /// scripted or nested run (`codex exec`, `claude -p`, CI) rather than a
    /// session someone is sitting in front of. Set by the forwarder, which
    /// reads the tty of the owning process ONLY, never an ancestor's. Optional
    /// so events from an older installed forwarder remain decodable (and
    /// decode as "not headless", i.e. the pre-existing behavior).
    var headless: Bool?

    // Terminal-jump fields — all optional and additive, so events from an
    // older forwarder that doesn't send them still decode cleanly. See
    // HookInstaller.swift for how each is captured and TerminalJumpers.swift
    // for how they're consumed.
    var terminal: String?
    var wezterm_pane: String?
    var wezterm_socket: String?
    var wezterm_exe: String?
    var tmux_pane: String?
    var tmux_socket: String?
    var tmux_host: String?
    var host_tty: String?

    var agentTool: AgentTool { AgentTool(rawValue: tool) ?? .unknown }
    var terminalKind: TerminalKind { TerminalKind(rawValue: terminal ?? "") ?? .unknown }
    var resolvedSessionID: String { session_id ?? "\(tool):\(tty ?? "?")" }
}

/// A live session tracked in the overlay.
struct Session: Identifiable {
    let id: String              // session_id
    var tool: AgentTool
    var status: SessionStatus
    var cwd: String?
    var tty: String?
    var lastUpdate: Date

    // Terminal-jump fields, merged in from HookEvent by SessionStore.apply —
    // see `jumpTarget` below for how they're assembled for a jump.
    var terminal: TerminalKind = .unknown
    var weztermPane: String?
    var weztermSocket: String?
    var weztermExe: String?
    var tmuxPane: String?
    var tmuxSocket: String?
    var tmuxHost: TerminalKind?
    var hostTTY: String?

    /// Short human label — the working directory's last path component.
    var label: String {
        guard let cwd, !cwd.isEmpty else { return tool.display }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Builds the `JumpTarget` consumed by `TerminalJumpers.jump(_:)` — the
    /// single conversion point call sites use instead of reading these fields
    /// directly.
    var jumpTarget: JumpTarget {
        JumpTarget(
            terminal: terminal,
            tty: tty,
            cwd: cwd,
            weztermPane: weztermPane,
            weztermSocket: weztermSocket,
            weztermExe: weztermExe,
            tmuxPane: tmuxPane,
            tmuxSocket: tmuxSocket,
            tmuxHost: tmuxHost,
            hostTTY: hostTTY
        )
    }
}

/// Everything a `TerminalJumper` needs to raise the pane/window that owns a
/// session.
struct JumpTarget {
    var terminal: TerminalKind
    var tty: String?
    var cwd: String?
    var weztermPane: String?
    var weztermSocket: String?
    var weztermExe: String?
    var tmuxPane: String?
    var tmuxSocket: String?
    var tmuxHost: TerminalKind?
    var hostTTY: String?
}
