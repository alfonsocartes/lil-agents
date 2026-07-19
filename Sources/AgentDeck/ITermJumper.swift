import Foundation

/// Jumps to the iTerm2 tab/pane whose controlling TTY matches a session shown in
/// the overlay. The interface is FROZEN — `OverlayView.swift` / `MenuBarController`
/// call `jump(tty:cwd:)` directly. Do not change the signature.
///
/// NOTE: The first run triggers a macOS Automation (TCC) prompt to control
/// "iTerm2". If denied, osascript exits non-zero and we log and return.
enum ITermJumper {
    static func jump(tty: String?, cwd: String?) {
        guard let tty, !tty.isEmpty else {
            NSLog("ITermJumper: no tty for session (cwd=\(cwd ?? "nil")); skipping jump")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            runAppleScript(forTTY: tty)
        }
    }

    private static func runAppleScript(forTTY tty: String) {
        let escaped = escapeForAppleScriptString(tty)
        // Raise the matching session's window by setting its index to 1 (frontmost),
        // select the tab + session, then activate. Reading `tty of s` is wrapped in a
        // try so an odd session can't abort the whole scan.
        let script = """
        tell application "iTerm2"
            set targetTTY to "\(escaped)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set stty to ""
                        try
                            set stty to tty of s
                        end try
                        if stty is targetTTY then
                            select s
                            select t
                            set index of w to 1
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
            return "nomatch"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus != 0 || out != "focused" {
                NSLog("ITermJumper: tty=\(tty) status=\(process.terminationStatus) out='\(out)' err='\(err)'")
            }
        } catch {
            NSLog("ITermJumper: failed to launch osascript for \(tty): \(error)")
        }
    }

    private static func escapeForAppleScriptString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }
}
