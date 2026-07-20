import AppKit
import Foundation
import UserNotifications

/// Fires a system notification the moment a session starts needing the
/// user's attention (blocked on approval, or finished its turn and idle).
/// Wraps `UNUserNotificationCenter`; every call is gated by `AppSettings` so
/// SessionStore can call in unconditionally and let preferences decide.
///
/// Delegate callbacks arrive off the main actor (UNUserNotificationCenter
/// calls them from its own queue), so — mirroring StayAwakeController's
/// `onLidClosed` pattern — they're `nonisolated` and hop back to the main
/// actor via `Task { @MainActor in … }` before touching `settings` or
/// `sessionLookup`.
@MainActor
final class Notifier: NSObject {
    enum Reason: String {
        case approval
        case idle
    }

    private let settings: AppSettings
    private let sessionLookup: (String) -> Session?

    // `nonisolated` — read from the delegate's nonisolated didReceive callback
    // as well as from `notify(session:reason:)` on the main actor. A plain
    // immutable String is trivially Sendable, so this is safe either way.
    private nonisolated static let sessionIDKey = "sessionID"

    init(settings: AppSettings, sessionLookup: @escaping (String) -> Session?) {
        self.settings = settings
        self.sessionLookup = sessionLookup
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Requests alert+sound authorization. Safe to call once at launch — the
    /// system only actually prompts the user the first time; subsequent calls
    /// just report back the existing decision.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("AgentDeck: notification authorization request failed: \(error)")
            } else {
                NSLog("AgentDeck: notification authorization granted: \(granted)")
            }
        }
    }

    /// Schedules an immediate notification for a session's attention
    /// transition, unless preferences say not to. Uses `session.id + reason`
    /// as the request identifier so a newer notification for the same
    /// session/reason replaces any still-pending one rather than piling up.
    func notify(session: Session, reason: Reason) {
        guard settings.notificationsEnabled else { return }
        switch reason {
        case .approval: guard settings.notifyOnApproval else { return }
        case .idle: guard settings.notifyOnIdle else { return }
        }

        let content = UNMutableNotificationContent()
        content.title = "lil agents"
        switch reason {
        case .approval: content.body = "\(session.label) needs your approval"
        case .idle: content.body = "\(session.label) finished its turn"
        }
        content.sound = settings.playSound ? .default : nil
        content.userInfo = [Self.sessionIDKey: session.id]

        let request = UNNotificationRequest(
            identifier: "\(session.id).\(reason.rawValue)",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("AgentDeck: failed to schedule notification: \(error)")
            }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show the banner (with sound) even while the app is already frontmost —
    /// the default behavior suppresses banners for a foreground app, which
    /// would make notifications invisible for an accessory app the user just
    /// happens to have focus near.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// A tap on the notification (or its default action) jumps to the
    /// session's terminal pane, same as clicking it in the overlay/menu.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = response.notification.request.content.userInfo[Self.sessionIDKey] as? String
        Task { @MainActor in
            if let sessionID, let session = self.sessionLookup(sessionID) {
                TerminalJumpers.jump(session.jumpTarget)
            } else {
                // The session is gone by the time the tap arrives — either
                // SessionEnd removed it right away, or `pruneStale` dropped
                // it after an hour of silence. Idle/waiting sessions are
                // exactly the long-lived ones a user comes back to after a
                // while, so this is the common case, not an edge case: a
                // silent no-op here would make the tap look broken. Log the
                // miss (diagnosable via Console) and at least bring the app
                // forward so the tap visibly does something.
                //
                // Notifier only has `sessionLookup` and `settings` to work
                // with — it has no reference to AppDelegate's floating panel
                // or the menu-bar panel, so it can't reveal the overlay
                // itself without threading one through from outside. Falling
                // back to activating the app is the best available response
                // without touching other files.
                NSLog("AgentDeck: notification tap for missing session id \(sessionID ?? "<nil>") — session already ended or was pruned")
                NSApp.activate(ignoringOtherApps: true)
            }
            completionHandler()
        }
    }
}
