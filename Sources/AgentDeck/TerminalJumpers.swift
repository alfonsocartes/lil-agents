import Foundation

/// A per-terminal strategy for raising the pane/window that owns a session.
/// Implementations run entirely OFF the main thread (Process + osascript both
/// block) and fail quietly via NSLog on any error — never surfaced to the UI.
protocol TerminalJumper {
    func jump(_ target: JumpTarget)
}

/// Routes a `JumpTarget` to the jumper for its terminal kind, off the main
/// thread. This is the single entry point call sites (`MenuBarController`,
/// `OverlayView`) use — they no longer talk to a specific jumper directly.
enum TerminalJumpers {
    static func jump(_ target: JumpTarget) {
        DispatchQueue.global(qos: .userInitiated).async {
            jumper(for: target.terminal).jump(target)
        }
    }

    private static func jumper(for terminal: TerminalKind) -> TerminalJumper {
        switch terminal {
        case .iterm2:        return ITermJumper()
        case .appleTerminal: return AppleTerminalJumper()
        case .wezterm:       return WezTermJumper()
        case .tmux:          return TmuxJumper()
        case .ghostty:       return GhosttyJumper()
        case .unknown:       return FallbackJumper()
        }
    }
}

/// Resolves a CLI tool (tmux, wezterm) to an absolute path.
///
/// A GUI app launched by launchd / `open` inherits a MINIMAL PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) — it does NOT include `/opt/homebrew/bin`,
/// `/usr/local/bin`, or `/opt/local/bin` where these tools actually live. So
/// running `/usr/bin/env tmux` from inside the app fails ("env: tmux: No such
/// file or directory") for the common Homebrew/MacPorts install, and the jump
/// silently no-ops. We instead:
///   1. use an absolute `hint` captured by the forwarder (the exact binary the
///      user runs), if it exists and is executable; else
///   2. search the common install locations ourselves; else
///   3. fall back to the bare name (last resort — same behavior as before).
enum ExecutableResolver {
    /// Homebrew (Apple silicon), Homebrew (Intel), MacPorts, then the system
    /// dirs that are already on the minimal PATH.
    private static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"]

    static func resolve(_ name: String, hint: String? = nil) -> String {
        let fm = FileManager.default
        if let hint, hint.hasPrefix("/"), fm.isExecutableFile(atPath: hint) {
            return hint
        }
        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return name
    }
}
