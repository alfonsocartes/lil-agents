# Optional session tracking

Date: 2026-09-04
Status: draft
Issue out of scope: [Rename AgentDeck to LilAgents](https://github.com/alfonsocartes/lil-agents/issues/6)

## Goal

Session tracking (hooks, overlay, listener, session list) is optional, the same way usage is. One Settings switch. Default on, so existing installs do not change.

Enable installs the CLI hooks and starts the session surfaces. Disable uninstalls those hooks and tears the session surfaces down. No app restart.

Usage, login-at-login, stay-awake, and full Uninstall stay independent.

## Non-goals

- Per-CLI session toggles.
- Default-off, or a migration that turns tracking off for existing users.
- Usage-only overlay. When sessions are off, the overlay is hidden; usage stays in the menu bar.
- Renaming AgentDeck (see issue #6).
- iOS / widget changes.

## Settings model

Add `AppSettings.sessionsEnabled`.

| | |
|---|---|
| UserDefaults key | `sessions.enabled` |
| Missing key | **on** (`object(forKey:) as? Bool ?? true`) |
| Persistence | `didSet` writes immediately |
| Side effect | `onSessionsEnabledChange: ((Bool) -> Void)?`, same shape as `shareTokensWithIPhone` and `showBackgroundSessions` |

`showBackgroundSessions` is unchanged. Its UI is nested under the new switch and disabled when tracking is off.

## Settings UI

Settings → **Sessions**:

1. Toggle **Track sessions**, bound to `sessionsEnabled`.
2. Caption: wires lifecycle hooks into Claude Code, Codex CLI, and Grok CLI. Off removes those hooks.
3. Existing **Show background agents** toggle and caption, indented, `.disabled(!settings.sessionsEnabled)`.

Settings → **Notifications**: keep the current controls. Disable the whole section when `sessionsEnabled` is false. Those alerts are session-only.

General, AI usage, Uninstall: no change. Full Uninstall still removes hooks, login item, stay-awake, and support files, then quits.

## Apply path

Launch and the Settings toggle share one apply function in `AppDelegate`. Wire `settings.onSessionsEnabledChange` to it, then call it once with the current value after the listener, lifecycle coordinator, overlay, and hotkey objects exist.

`AGENTDECK_NO_INSTALL=1` still skips hook file mutation (both install and uninstall). Listener, overlay, and hotkey still follow `sessionsEnabled`.

### On (`sessionsEnabled == true`)

- `HookInstaller.install(port:)` on a detached utility task. Same call as today's launch path. After [#5](https://github.com/alfonsocartes/lil-agents/pull/5) this is skip-if-correct for Claude/Codex (no rewrite when our entries already match) and leaves invalid JSON untouched. Do not reintroduce per-launch rewrites.
- `EventListener.start()` (no-op if already running).
- Register ⌥⌘J.
- `overlay.show()`.
- Request notification permission (current `Notifier.requestAuthorization()`).

### Off (`sessionsEnabled == false`)

- `HookInstaller.uninstall()` on a detached utility task. This is hook uninstall only, not `Uninstaller.performUninstall()`.
- `EventListener.stop()` (no-op if not running). Port 54173 is unbound.
- Unregister ⌥⌘J.
- `overlay.hide()`.
- Drop every tracked session: add `SessionLifecycleCoordinator.dropAllSessions()` that terminates every lifecycle the same way `dropBackgroundSessions()` terminates background ones. Rows, process watches, and pane ownership go with them.

### Launch with tracking already off

Still run uninstall so leftover hooks from an older always-on build are removed. Skip listener start, overlay show, and hotkey registration.

### Toggle while running

Same apply path. No restart.

Rapid on/off: keep one hook-mutation `Task`. Cancel it before starting the next so the last requested state wins. Do not run two file-writing tasks at once.

### Failures

Install or uninstall errors: `NSLog`, keep the toggle as the user’s intent. Do not revert `sessionsEnabled`. Same as today’s launch-install failure.

`install()` already continues other CLIs if one config is unreadable, then throws the first error. `uninstall()` already no-ops a Claude/Codex file it cannot parse. Do not change that.

## Event listener

Add `EventListener.stop()`: cancel the `NWListener`, clear the retention slot, log. `start()` after `stop()` must bind again. `start()` while running is a no-op. `stop()` while stopped is a no-op.

## UI when sessions are off

- Overlay is hidden. The hotkey is unregistered, so ⌥⌘J does nothing.
- Menu: drop the session list, the “N active” badge, and Show/Hide overlay.
- Menu keeps: title “lil agents”, `UsageMenuSection` (empty when all usage providers are off), stay-awake, Settings, Check for Updates, Quit.
- Menu-bar icon: session attention is `.none` because the store is empty. Usage rows still appear when any provider is enabled. Otherwise the idle glyph.

`MenuBarContentView` (and `StatusIconLabel` if needed) must observe `AppSettings` / `sessionsEnabled` to hide those session surfaces. Pass `settings` in from `AgentDeckApp` the same way the other services are passed.

## Surfaces that stay on

- Usage polling and gauges (menu bar only while sessions are off).
- Stay-awake.
- Login item.
- Sparkle.
- Token file and support directory (full Uninstall still deletes them).
- iPhone token handoff.

## Tests

Use `InMemoryDefaults` for settings tests (existing `TestSupport` pattern).

- `sessionsEnabled` is true when the key is missing.
- Writing it persists and fires `onSessionsEnabledChange`.
- `EventListener.stop()` on an unstarted listener is a no-op. start → stop → start binds again. Suite `.serialized` so it cannot collide with a live app on 54173; skip the bind-again assertion if the production port is already taken.
- `SessionLifecycleCoordinator.dropAllSessions()` ends every lifecycle, including non-background ones.
- Existing `HookInstaller` install/uninstall tests stay as-is, including the skip-if-correct and unreadable-JSON cases from #5.

`AppDelegate` launch/toggle wiring stays untested, same as today.

## Docs

README (after #5 it already says install runs automatically on launch and is skip-if-correct):

- Sessions are on by default and can be turned off in Settings.
- Enable installs hooks; disable uninstalls them.
- Overlay exists only while sessions are on.
- Usage is unchanged (opt-in, menu bar + overlay header while sessions are on; menu bar only while off).
- Qualify “hooks install automatically on launch” and “zero-config hook install”: that is only while **Track sessions** is on. Off removes the hooks.

## Files

| File | Change |
|---|---|
| `Sources/AgentDeck/AppSettings.swift` | `sessionsEnabled` + callback |
| `Sources/AgentDeck/SettingsView.swift` | Track sessions toggle; nest background; disable notifications when off |
| `Sources/AgentDeck/AppDelegate.swift` | Shared apply path; launch respects the flag |
| `Sources/AgentDeck/EventListener.swift` | `stop()`; start/stop idempotent |
| `Sources/AgentDeck/SessionLifecycleCoordinator.swift` | `dropAllSessions()` |
| `Sources/AgentDeck/AgentDeckApp.swift` | Pass `settings` into the menu |
| `Sources/AgentDeck/MenuBarContentView.swift` | Hide session list, badge, overlay row when off |
| `tests/AgentDeckTests/` | Settings, listener, `dropAllSessions` |
| `README.md` | Opt-out sessions, hook install/uninstall |

No iOS files. No package/module rename.
