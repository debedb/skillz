---
name: cmux-session-restore-forensics
description: |
  Work out what cmux actually restored after a quit/relaunch, and bring back
  workspaces and panes it dropped. Use when: (1) cmux reopened "some but not
  all" tabs and the result looks haphazard, (2) an agent-teams session did not
  come back at all, (3) tabs reappeared that you had already closed, (4) you
  need to tell "cmux silently lost this pane" apart from "I closed it myself",
  (5) you want to resurrect a Claude Code session whose tab is gone but whose
  session id still exists. Covers the on-disk session/closed-history JSON, the
  Core Data epoch gotcha in their timestamps, diffing two snapshots correctly
  (workspaceId is NOT stable across restarts), and replaying a pane's stored
  resumeBinding through `cmux new-workspace`.
author: Claude Code
version: 1.0.0
date: 2026-07-31
source: https://github.com/voitta-ai/skillz
source_file: skills/cmux-session-restore-forensics/SKILL.md
---

# cmux Session Restore Forensics

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file:
> `skills/cmux-session-restore-forensics/SKILL.md`).

## Problem

cmux restores workspaces and panes after a relaunch on a best-effort basis. When
it only partly succeeds you get a window that looks roughly right but is missing
work, and cmux surfaces no error saying so. Worse, the restore path *recreates*
workspaces rather than preserving them, so the obvious way to compare before and
after — match workspaces by id — reports total churn and tells you nothing.

Agent panes are the expensive case: a lost pane means a Claude Code session you
can no longer reach from the UI, even though the session itself still exists on
disk and is resumable.

## Context / Trigger Conditions

- After a cmux quit/relaunch, noticeably fewer tabs than you had.
- A Claude Teams / agent-teams workspace did not reopen, or reopened as an empty
  shell that does nothing.
- Tabs you had closed earlier are back.
- You need to prove whether a given pane was dropped by cmux or closed by you.

## The state files

All under `~/Library/Application Support/cmux/` on macOS:

| File | What it is |
|---|---|
| `session-com.cmuxterm.app.json` | live state, rewritten as you work |
| `session-com.cmuxterm.app-previous.json` | **the snapshot from before the last relaunch — your recovery source** |
| `closed-item-history-com.cmuxterm.app.json` | full snapshots of individually closed workspaces/panels/windows |

Shape of the session files:

```
windows[] -> tabManager.workspaces[] -> panels[]
```

A workspace carries `workspaceId`, `customTitle`, `currentDirectory`, `layout`.
A panel carries `id`, `customTitle`, `directory`, and `terminal`, and
`terminal.resumeBinding.command` is the command cmux replays to bring that pane
back. **A panel with no `resumeBinding.command` cannot be restored by anything.**

`closed-item-history` is a dict with a `records` list; each record is
`{closedAt, id, entry}` where `entry` is a single-key dict — `workspace`,
`panel`, or `window` — whose `_0.snapshot` holds the same structure as above.

## Three gotchas that will mislead you

**1. `closedAt` uses the Core Data reference date, not the Unix epoch.**
It counts seconds from 2001-01-01, so `datetime.fromtimestamp()` reports dates
31 years too early — a close from last night shows up as 1995. Convert with
`datetime(2001,1,1) + timedelta(seconds=closedAt)`. Getting this wrong makes
every closed item look ancient and irrelevant.

**2. `workspaceId` is not stable across a relaunch.** Restore mints new ids, so
a set-difference on `workspaceId` reports "everything lost, everything new" and
is useless. Diff on something that survives: for agent panes, the session UUID
embedded in `resumeBinding.command` (`claude --resume <uuid>`). That id is the
same session before and after, so it is the only reliable join key.

**3. Extracting that UUID is fiddly.** The stored command is heavily
shell-quoted, e.g. `'\''--resume'\'' '\''<uuid>'\''`. A regex expecting
`--resume <uuid>` with plain spacing silently matches nothing and you conclude
no pane had a binding. Search for the first UUID *after* the index of the
literal `--resume` instead of trying to match the separator.

## Solution

### Step 1 — classify every pane

For each panel in `-previous.json`, extract `(workspace title, panel title, cwd,
resume command, session uuid)`. Do the same for the current session file, and
read the closed-item history for anything closed since the relaunch. Then bucket:

- **has a binding, present now** — restored fine.
- **has a binding, absent now, present in closed-history after the relaunch** —
  you closed it. Leave it.
- **has a binding, absent now, not in closed-history** — **silently dropped by
  cmux. This is what you recover.**
- **no binding at all** — unrecoverable; nothing was ever stored to replay.

### Step 2 — recover the dropped panes

Replay each stored command as a new workspace:

```bash
CMUX="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
"$CMUX" new-workspace --name "<panel title>" --cwd "<cwd>" --command "<resumeBinding.command>" --focus false
```

Use `--focus false` so a batch of restores does not yank your focus around.

`closed-item-history` is a second recovery source with the same shape, for tabs
closed further back than the last relaunch.

### Step 3 — expect a trust prompt on each rescued tab

The pane comes back in a *new* workspace, and Claude Code's folder trust is
scoped to the original one. Every rescued agent tab therefore stops at
"Quick safety check: is this a project you created or one you trust?" and waits
for a keypress. That is expected, not a failure — walk the tabs and confirm each.

## Verification

```bash
python3 - <<'PY'
import json
d=json.load(open('/Users/<you>/Library/Application Support/cmux/session-com.cmuxterm.app.json'))
n=0
for w in d['windows']:
    for ws in w['tabManager']['workspaces']:
        n+=len(ws['panels'])
        print(' %-16s panels=%d'%(str(ws.get('customTitle'))[:16], len(ws['panels'])))
print('total panels:', n)
PY
```

The rescued names should appear, and the total should have risen by exactly the
number you replayed. The live file is rewritten within a second or two of the
`new-workspace` call.

## Example

A relaunch that looked mostly fine actually broke down as: 26 panels before the
quit, 16 of them carrying a `resumeBinding`, 7 restored, 3 restored and then
closed by hand, and **5 silently dropped**. The remaining 10 had no binding at
all. Replaying those 5 commands brought every one back.

## Notes

- **Panes spawned by `cmux claude-teams` never get a `resumeBinding`** — neither
  the launcher pane nor the teammates. They fall in the "unrecoverable" bucket
  by construction, which is why an agent-teams session characteristically fails
  to reopen while ordinary agent tabs survive. Do not plan work that assumes a
  teams session will still be there after a relaunch; treat teams runs as
  ephemeral and keep durable state in git, issues, or notes.
- Do not diff the two session files by hand. The interesting difference is
  almost never visible at the workspace level; it lives in per-panel bindings.
- `-previous.json` is overwritten by the *next* relaunch. If a restore looks
  wrong, copy that file aside before doing anything else — including before
  relaunching again to "see if it fixes itself".
- The `cmux` CLI is often not on `PATH`; resolve it via
  `${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}`.
- Related: `cmux-autoresume-after-reboot` diagnoses the adjacent question of *why*
  restore under-performed — cmux not relaunching at login, or the
  `wasAgentRunning == false` gate making panes come back as fresh agents. Reach
  for that one when panes return but have lost their conversation; reach for this
  one when panes do not return at all and you want them back.
- Related: `cmux-agent-tabs` (getting agents to appear as tabs in the first
  place), `cmux-search` (searching across live panes and transcripts).
