<p align="center">
  <img src="assets/lil-agents-icon.png" alt="lil agents — live status overlay for Claude Code and Codex CLI sessions" width="128" />
</p>

<h1 align="center">lil agents</h1>

<p align="center">A live status overlay for Claude Code &amp; Codex CLI sessions on macOS.</p>

---

**Stop alt-tabbing to check if your AI coding agent is done.** `lil agents` (aka **AgentDeck**) is a tiny, native macOS menu-bar app that shows the live status of every [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [OpenAI Codex CLI](https://developers.openai.com/codex/) session in a always-on-top overlay — working, idle, or waiting for you — and lets you jump straight to the terminal pane that needs attention.

> Built for developers running **multiple AI agents in parallel** across terminal tabs and windows. One glance tells you which session is blocked on a permission prompt, which finished its turn, and which is still crunching.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![UI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-blue)
![Status](https://img.shields.io/badge/status-v0.1.0-brightgreen)

<p align="center">
  <img src="assets/overlay-screenshot.png" alt="lil agents floating overlay showing live Claude Code and Codex sessions with traffic-light status" width="300" />
  &nbsp;&nbsp;
  <img src="assets/menu-screenshot.png" alt="lil agents menu bar menu with session list, jump-to-pane, stay awake toggle, and overlay hotkey" width="300" />
</p>

<p align="center"><sub>The always-on-top overlay (left) and the menu-bar menu (right) — every live agent session at a glance.</sub></p>

---

## Why lil agents?

When you drive several coding agents at once, they spend most of their time out of sight — in a background tab, another window, or a pane you scrolled away from. You end up context-switching constantly just to check "is it waiting on me yet?"

`lil agents` collapses that whole problem into a **single traffic-light glance**:

- 🔴 **Red** — a session is **blocked on a permission / approval prompt** and needs you *now*.
- 🟡 **Yellow** — a session **finished its turn** and is waiting for your next prompt.
- 🟢 **Green** — a session is **actively working** (running a tool or thinking).

Click any session and it **brings the matching iTerm2 tab to the front** — no more hunting through windows.

## Features

- **Real-time agent monitoring** — tracks Claude Code and Codex CLI sessions as they start, work, prompt, and finish.
- **Floating overlay** — a compact, near-transparent, always-on-top list of live sessions. Toggle it anywhere with a global hotkey (**⌥⌘J**).
- **Menu bar status icon** — the menu-bar glyph changes color to reflect the most attention-worthy session (red → yellow → green), so you know the state without even opening the overlay.
- **One-click jump to terminal** — click a session (in the overlay or the menu) to focus the exact **iTerm2** tab/pane that owns it, matched by controlling TTY.
- **Project-aware labels** — each session is labeled by its working-directory name, so you can tell your repos apart at a glance.
- **Stay awake (lid closed)** — an optional toggle keeps your Mac awake with the lid shut, so long agent runs don't get suspended mid-task.
- **Zero-config hook install** — one action wires the lifecycle hooks into both CLIs; config files are *merged, never clobbered*, and install is idempotent and self-healing.
- **Private by design** — everything is local. Events are sent over **loopback only** (`127.0.0.1:8787`), never your LAN, never the internet.
- **Native & lightweight** — pure Swift 6, SwiftUI + AppKit, no Electron, no bundled runtime. Dock-less and unobtrusive (`LSUIElement`).

## How it works

`lil agents` installs small **lifecycle hooks** into the CLIs you already use:

- **Claude Code** → `~/.claude/settings.json`
- **Codex CLI** → `~/.codex/hooks.json`

On each lifecycle event (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Notification`/`PermissionRequest`, `Stop`, `SubagentStop`, `SessionEnd`), a tiny generated forwarder script reads the hook's JSON, tags it with the terminal's TTY, and `POST`s it to the app's local listener. The app maps those events to a coarse status (`working` / `idle` / `waitingApproval`) and updates the overlay and menu-bar icon instantly.

```
Claude Code / Codex CLI
        │  (lifecycle hook fires)
        ▼
 forward-event.sh  ──POST──▶  127.0.0.1:8787/event  ──▶  lil agents overlay + menu bar
   (adds tty/tool/event)          (loopback only)          🔴 🟡 🟢  +  jump-to-pane
```

Existing hooks from other tools and plugins are preserved — the installer only ever adds or removes its own entries.

## Requirements

- **macOS 14 (Sonoma) or later**
- **Swift 6 toolchain** (Xcode 16+) to build from source
- **[iTerm2](https://iterm2.com/)** for click-to-jump (matches sessions by TTY)
- **Claude Code** and/or **Codex CLI** installed — whichever agents you want to monitor

## Install & build

Clone and build the `.app` with the included script:

```bash
git clone https://github.com/<your-org>/lil-agents.git
cd lil-agents
scripts/build-app.sh          # release build → dist/lil agents.app
open "dist/lil agents.app"
```

Or build the raw binary with SwiftPM:

```bash
swift build -c release
```

On first launch, use the app's install action to wire up the CLI hooks, then start (or restart) a Claude Code or Codex session — it should appear in the overlay immediately.

> **First-run permissions:** macOS will show a one-time **Automation** prompt so the app can control iTerm2 when you jump to a pane. The build is ad-hoc code-signed so this grant persists across launches.

## Usage

| Action | How |
| --- | --- |
| Show / hide the overlay | Global hotkey **⌥⌘J**, or the menu-bar menu |
| Jump to a session's terminal | Click the session row (overlay) or menu item |
| Keep Mac awake with lid closed | Menu bar → **Stay awake (lid closed)** |
| Quit | Menu bar → **Quit lil agents** |

Status at a glance:

| Dot | Meaning |
| --- | --- |
| 🟢 Green | Working — running a tool or thinking |
| 🟡 Yellow | Idle — finished its turn, waiting for your prompt |
| 🔴 Red | Needs input — blocked on a permission/approval prompt |

## Privacy & security

- **Loopback only.** The listener binds to `127.0.0.1` and is never exposed to the network.
- **No telemetry.** Nothing leaves your machine. There is no analytics, no account, no cloud.
- **Non-destructive config edits.** Existing hooks are backed up and merged; uninstall removes only what `lil agents` added.

## Uninstall

Use the app's uninstall action (removes its hook entries from both CLI config files and deletes the generated forwarder scripts), then delete `dist/lil agents.app`.

## Tech stack

Swift 6 · SwiftUI · AppKit · Network.framework (embedded loopback listener) · Carbon global hotkey · AppleScript/osascript (iTerm2 automation) · SwiftPM.

## Roadmap ideas

- Support for additional terminals (Terminal.app, Ghostty, WezTerm, tmux)
- Notification Center / sound alerts when a session needs input
- Per-session elapsed-time and turn counts

Contributions and issues welcome.

## License

_Add your license here (e.g. MIT)._

---

<sub>**Keywords:** Claude Code monitor · Codex CLI status · AI coding agent dashboard · macOS menu bar app · terminal session overlay · parallel AI agents · iTerm2 jump-to-pane · Claude Code hooks · Codex hooks · agent session tracker · SwiftUI menu bar app.</sub>
