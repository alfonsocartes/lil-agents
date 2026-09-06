# Rename upgrade rehearsal (issue #6)

Run this on the Mac before tagging. Nothing in the rename branch has ever been
compiled — it was written on a Linux box with no Swift toolchain — so step 1 is
the first real signal.

Delete this file once the rename has shipped.

## 1. The actual gate

```sh
swift build && swift test
```

Everything below is worthless until this passes. ~360 lines of `HookInstallerTests`
changed, plus a new migration function and new legacy-path recognition.

## 2. Capture pre-upgrade state

Install the shipped **0.10.0** (`com.agentdeck.app`) build, launch it, and:

- turn **Track sessions** on, so hooks get written
- turn **Open at Login** on
- enable **Stay awake**, so `/etc/sudoers.d/agentdeck` is created
- click a session once to trigger the iTerm2 Automation (TCC) prompt and allow it

Then snapshot:

```sh
ls -la ~/Library/Application\ Support/AgentDeck/
defaults read com.agentdeck.app > /tmp/defaults-before.txt
sudo ls -l /etc/sudoers.d/agentdeck
grep -c 'Application Support/AgentDeck/forward-event.sh' ~/.claude/settings.json ~/.codex/hooks.json
ls ~/.grok/hooks/
sudo sfltool dumpbtm > /tmp/btm-before.txt
```

## 3. Upgrade

Build and install the rename build over it. Launch it once.

## 4. What must be true afterwards

| Check | Command | Expected |
|---|---|---|
| Support dir migrated | `ls ~/Library/Application\ Support/` | `LilAgents/` present, `AgentDeck/` **gone** |
| Token carried over | `sudo diff <(cat ~/Library/Application\ Support/LilAgents/token) /tmp/token-before` | identical (capture the old one in step 2 first) |
| Hook entries rewritten | `grep -c 'LilAgents/forward-event.sh' ~/.claude/settings.json ~/.codex/hooks.json` | ≥1 each |
| No orphaned old entries | `grep -c 'AgentDeck/forward-event.sh' ~/.claude/settings.json ~/.codex/hooks.json` | **0** |
| Grok file renamed | `ls ~/.grok/hooks/` | `lilagents.json` present, `agentdeck.json` **gone** |
| Hooks actually fire | start a Claude Code session | it appears in the overlay, no hook errors on stderr |

## 5. The sudoers fix (finding F1)

This is the one that was silently broken and is easy to mis-verify. The old rule
is functionally identical to the new one, so `sudo -n` succeeds either way — you
must check the **files**, not the behaviour.

```sh
sudo ls -l /etc/sudoers.d/
```

Toggle **Stay awake** off and on in Settings. Expect **one** admin prompt, then:

- `/etc/sudoers.d/lilagents` exists
- `/etc/sudoers.d/agentdeck` is **gone**

If `agentdeck` is still there, the force-install path in
`StayAwakeController.runPmsetDisableSleep` did not fire.

## 6. The no-install gate (finding F2)

With a pre-rename install present, this must **not** move the support dir:

```sh
LILAGENTS_NO_INSTALL=1 swift run
```

Then confirm `~/Library/Application Support/AgentDeck/` is still intact and your
installed build still works.

## 7. Expected breakage — all intended, do not "fix"

Phase 3 changed the bundle id with no compatibility shims, so on first launch:

- the iTerm2 **Automation prompt re-appears** (TCC is keyed to the bundle id)
- the **notification permission prompt re-appears**
- **all settings reset** — including `sessionsEnabled`, which defaults to `true`,
  so session tracking re-enables itself and rewrites the CLI hook configs
- **launch-at-login stops working**, and the one-shot "start at login?" prompt
  re-fires
- a stale `com.agentdeck.app` row may linger in System Settings → Login Items.
  There is no API to remove it; delete it by hand.

Keychain is *not* affected — both reads shell out to `/usr/bin/security`, so the
ACL subject is Apple's tool, not this app.

## 8. Sparkle (do this before tagging, not after)

Verified against Sparkle 2.6.0 and 2.9.6 source: `SUUpdateValidator` accepts on
`passedDSACheck || passedCodeSigning`, the EdDSA key is unchanged, and the `.app`
filename stays `lil agents.app`, so the bundle-id change should install. The
code-signing half *will* fail — that is expected and is why TCC resets.

Confirm it for real against a staging appcast before tagging:

1. serve this build from a scratch appcast
2. point an installed 0.10.0 at it
3. watch: `log stream --predicate 'sender CONTAINS "Sparkle" OR process IN {"Autoupdate","Updater"}' --info --debug`

A pass shows no `SUValidationError` / `SUMissingUpdateError`. The benign line
*"Code signature of the new version doesn't match the old version"* is expected.

If this fails, there is no in-app path forward from 0.10.0 — it becomes a
manual-download release.

## 9. Cleanup follow-up

Ten `TODO(rename cleanup)` markers tag the migration code:

```sh
grep -rn "TODO(rename cleanup)" Sources/
```

Delete all of it one release after this ships, once the machine is migrated.
`Uninstaller.legacySudoersPath` must be the **last** thing removed — drop it
while `/etc/sudoers.d/agentdeck` still exists anywhere and that root-owned
NOPASSWD rule is orphaned with no code that knows about it.
