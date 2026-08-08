import Foundation
import Observation
import ServiceManagement

/// Seam over `SMAppService.mainApp` so `LoginItemController` can be tested
/// without touching the real login-item registry (registering/unregistering
/// for real would actually add/remove AgentDeck from the user's login items
/// every time the test suite runs).
@MainActor
protocol LoginItemBackend {
    var isAvailable: Bool { get }
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Drives the "Open at Login" toggle backed by `SMAppService.mainApp`.
///
/// `SMAppService` doesn't push change notifications — the user can flip the
/// login item off from System Settings at any time without telling this
/// process — so `status` is only ever as fresh as the last `refresh()`. Call
/// sites are expected to `refresh()` on becoming active (e.g. when the
/// Settings window opens) rather than trust a stale value indefinitely.
@MainActor
@Observable
final class LoginItemController {
    private enum Keys {
        static let promptShown = "loginItem.promptShown"
    }

    private(set) var status: SMAppService.Status
    private(set) var lastError: String?

    private let backend: LoginItemBackend
    private let defaults: UserDefaults

    /// Mirrors `backend.isAvailable`. False for an unbundled `swift run` dev
    /// build, where there's no `.app` bundle for `SMAppService` to register.
    var isAvailable: Bool { backend.isAvailable }

    /// `.requiresApproval` still reads as "on": the user (or a previous
    /// launch of this app) already registered the login item, and macOS is
    /// just waiting on approval in System Settings — or the user revoked
    /// that approval after the fact. Either way the app's *intent* is still
    /// enabled, so the toggle should stay lit rather than silently flip back
    /// to off; `needsApproval` below is what drives the accompanying warning.
    var isEnabled: Bool {
        get { status == .enabled || status == .requiresApproval }
        set {
            lastError = nil
            guard isAvailable else { return }
            do {
                if newValue {
                    try backend.register()
                } else {
                    try backend.unregister()
                }
            } catch {
                refresh()
                // `register()` throws if already registered and `unregister()`
                // throws if already unregistered — both are benign no-ops as
                // far as the user is concerned. Only surface the error if the
                // resulting status disagrees with what they asked for.
                if isEnabled != newValue {
                    lastError = error.localizedDescription
                }
                return
            }
            refresh()
        }
    }

    /// True when the login item is registered but the user hasn't approved
    /// it (or has revoked approval) in System Settings > General > Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    init(backend: LoginItemBackend = SMAppServiceLoginItemBackend(), defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
        self.status = backend.status
    }

    /// Re-reads `backend.status`. Cheap and safe to call as often as needed —
    /// there's no caching or debouncing to worry about.
    func refresh() {
        status = backend.status
    }

    func openSystemSettings() {
        backend.openSystemSettings()
    }

    /// Returns `true` at most once, ever, for the very first launch where the
    /// login item is available but not yet enabled — the caller uses this to
    /// show a one-time "want AgentDeck to start at login?" prompt.
    ///
    /// The `promptShown` flag is written to `defaults` *before* returning
    /// `true`, not after the user answers: if the app crashes or is
    /// force-quit while the prompt is on screen, we'd rather lose that one
    /// prompt than have it reappear on every subsequent launch until the
    /// user happens to answer it.
    func consumeFirstLaunchPrompt() -> Bool {
        guard isAvailable, !isEnabled else { return false }
        guard !defaults.bool(forKey: Keys.promptShown) else { return false }
        defaults.set(true, forKey: Keys.promptShown)
        return true
    }
}

/// Real backend wrapping `SMAppService.mainApp`.
@MainActor
struct SMAppServiceLoginItemBackend: LoginItemBackend {
    /// A `swift run` dev build is a bare executable with no `.app` bundle.
    /// Registering it as a login item would point System Settings at
    /// `.build/debug/AgentDeck`, which won't exist past the next clean build
    /// — so treat anything without a `.app` bundle extension as unavailable,
    /// and guard `register`/`unregister` on it too rather than trusting
    /// every caller to check `isAvailable` first.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    func register() throws {
        guard isAvailable else { return }
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        guard isAvailable else { return }
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
