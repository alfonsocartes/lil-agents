# Rename upgrade rehearsal (issue #6)

Run this on the Mac before tagging. The rename branch was originally written on
a Linux box with no Swift toolchain, but that gap is closed: CI (`.github/workflows/ci.yml`)
now runs `swift build` and `swift test` on `macos-26` on every push, and it is
green on this branch (321 tests in 47 suites). The full suite has also been run
directly on the Mac and passed.

That means step 1 below is a local re-confirmation, not the first real signal —
the automated gate already covers it. What CI *cannot* cover is everything from
§2 onward: TCC prompts, login items, sudoers, and Sparkle staging all require a
real GUI session and a real prior install, so that is where this runbook's
remaining value is. Nothing below has been run yet — this is still a checklist,
not a report of a completed rehearsal.

Delete this file once the rename has shipped.

## 1. The actual gate

```sh
swift build && swift test
```

Already green in CI and on the Mac; run again locally if you want to re-confirm
before tagging. ~360 lines of `HookInstallerTests` changed, plus a new migration
function and new legacy-path recognition.

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

Verified against Sparkle **2.9.4** source, which is what `Package.resolved` pins:

- `SUUpdateValidator.m:375` — `if (passedDSACheck || passedCodeSigning) { return YES; }`,
  and the EdDSA public key is unchanged from v0.10.0, so the code-signing mismatch
  caused by the bundle-id change is tolerated.
- `SUInstaller.m:81-82` — the update app is located by `.app` filename
  (`lil agents.app`, unchanged), so the bundle-identifier fallback at
  `SUInstaller.m:104-105`, which *would* fail, is never reached.

So the bundle-id change should install, and the code-signing half *will* fail
— that is expected, and is why TCC resets (§7). This is a static read,
not a substitute for actually running it — confirm it for real against a
staging appcast before tagging:

1. serve this build from a scratch appcast
2. point an installed 0.10.0 at it
3. watch: `log stream --predicate 'sender CONTAINS "Sparkle" OR process IN {"Autoupdate","Updater"}' --info --debug`

A pass shows no `SUValidationError` / `SUMissingUpdateError`. The benign line
*"Code signature of the new version doesn't match the old version"* is expected.

If this fails, there is no in-app path forward from 0.10.0 — it becomes a
manual-download release.

## 9. Tag placement matters

`.github/workflows/release.yml` ends with `git push origin HEAD:main` — a plain
fast-forward push of the tagged commit plus the appcast commit onto `main`, with
no fetch, rebase or retry. Consequences:

- Right now `origin/main` IS an ancestor of the branch tip, so tagging the branch
  tip works — and as a side effect fast-forwards `main` to all five rename
  commits without a PR merge. `main` is unprotected, so nothing prevents this.
- If the PR is merged into `main` FIRST (squash or merge commit) and the tag is
  then placed on the branch tip, `origin/main` is no longer an ancestor of the
  tag. The push is rejected as non-fast-forward, `set -euo pipefail` fails the
  step, and — with the release-workflow reorder in place — the GitHub Release
  will already exist but the appcast will not have been published, requiring a
  manual appcast commit to `main`.
- The rule: either tag the branch tip *before* merging, or merge first and tag
  the resulting commit *on `main`*. Never merge and then tag the old branch tip.

Also: `CFBundleVersion` is derived from `git rev-list --count HEAD`
(`scripts/release.sh:79`), so it is only monotonic if tags are placed on
ever-advancing history — v0.10.0 was 80, the branch tip is 86. Tagging a release
from a branch cut off older history would produce a **lower** build number, and
Sparkle would silently never offer that release.

## 10. Cleanup follow-up

Ten `TODO(rename cleanup)` markers tag the migration code:

```sh
grep -rn "TODO(rename cleanup)" Sources/
```

Delete all of it one release after this ships, once the machine is migrated.
`Uninstaller.legacySudoersPath` must be the **last** thing removed — drop it
while `/etc/sudoers.d/agentdeck` still exists anywhere and that root-owned
NOPASSWD rule is orphaned with no code that knows about it.
