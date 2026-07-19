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

/// The wire format posted by installed CLI hooks to `POST /event`.
/// The forwarder script merges the hook's stdin JSON with the captured tty.
struct HookEvent: Codable {
    var tool: String
    var event: String
    var session_id: String?
    var cwd: String?
    var tty: String?
    var notification_type: String?

    var agentTool: AgentTool { AgentTool(rawValue: tool) ?? .unknown }
}

/// A live session tracked in the overlay.
struct Session: Identifiable {
    let id: String              // session_id
    var tool: AgentTool
    var status: SessionStatus
    var cwd: String?
    var tty: String?
    var lastUpdate: Date

    /// Short human label — the working directory's last path component.
    var label: String {
        guard let cwd, !cwd.isEmpty else { return tool.display }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

}
