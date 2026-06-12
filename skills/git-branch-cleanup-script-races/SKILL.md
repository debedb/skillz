---
name: git-branch-cleanup-script-races
description: |
  Fix orphaned remote branches in scripts that bulk-delete ephemeral branches
  matching a name pattern (e.g. `temp-permissions-hack-*`, `feature/sandbox-*`,
  `pr-env-*`). Use when: (1) a cleanup script "ran successfully" but
  `gh api repos/:owner/:repo/branches` still shows branches matching the
  pattern, (2) the script does `git branch -a | grep PATTERN` then iterates
  to delete each one, (3) orphaned branches accumulate across runs even
  though every individual run looked clean. Two structural bugs collude:
  (a) `git branch -a` only lists locally-fetched remote-tracking refs, so
  branches created from another clone, CI, or a teammate's machine are
  invisible without `git fetch --prune`, (b) the list is captured once at
  the start, so any branch created concurrently during the cleanup loop is
  never picked up. Fix: `git fetch --prune` each iteration and loop to a
  fixed point, with a stall-detection escape so undeletable branches don't
  cause an infinite loop.
author: Claude Code
version: 1.0.0
date: 2026-04-29
---

# Git Branch Cleanup Script Races

## Problem

A script that bulk-cleans ephemeral branches matching a name pattern leaves
remote branches around even when each individual run appears successful.
Two distinct bugs typically collude:

1. **Stale local view.** `git branch -a` only enumerates refs already fetched
   into this clone's `refs/remotes/origin/*`. Branches pushed from another
   machine, a CI runner, or a teammate's clone are invisible until you fetch.

2. **Snapshot races.** The branch list is captured *once* at the start of
   cleanup. Any branch created concurrently (another session of the same
   tool, a teammate triggering it, a workflow auto-creating one) is never
   processed and remains orphaned after the script reports done.

## Context / Trigger Conditions

- Writing or reviewing a script that:
  - Lists branches matching a pattern (`temp-X-*`, `feature/sandbox-*`, etc.)
  - Iterates and deletes each one locally and on the remote
- Symptoms after running such a script:
  - `gh api repos/:owner/:repo/branches --paginate --jq '.[].name' | grep PATTERN`
    still shows branches the script claims to have cleaned
  - Open PRs left dangling for branches matching the pattern
  - Cleanup output looked successful but the next user/run sees stale state
  - Orphan count grows over time across multiple sessions / clones

## Solution

Wrap the listing in a loop that:

1. Calls `git fetch --prune origin` *before* listing each iteration, so
   remote branches from other clones become visible and locally-known but
   remote-deleted refs are removed.
2. Continues looping until the matched set is empty.
3. Bails out if the same set of branches reappears two iterations in a row
   (indelible — protection rules, permission errors, etc.). Without this,
   an undeletable branch becomes an infinite loop.

### Python sketch

```python
from typing import Optional
import subprocess

PATTERN = "temp-permissions-hack"

previous: Optional[set[str]] = None
while True:
    subprocess.run(
        ["git", "--no-pager", "fetch", "--prune", "origin"],
        cwd=REPO, check=False,
    )
    result = subprocess.run(
        ["git", "--no-pager", "branch", "-a"],
        cwd=REPO, capture_output=True, text=True, check=False,
    )
    branches: set[str] = set()
    for line in result.stdout.split("\n"):
        line = line.strip()
        if PATTERN not in line:
            continue
        branches.add(line.replace("remotes/origin/", "").replace("* ", ""))
    if not branches:
        break  # done
    if previous is not None and branches == previous:
        # Same set twice in a row -- give up and surface to caller
        raise RuntimeError(f"Cannot delete: {sorted(branches)}")
    previous = branches
    for branch in sorted(branches):
        cleanup_one(branch)
```

### Bash sketch

```bash
prev=""
while :; do
  git fetch --prune origin >/dev/null 2>&1
  cur=$(git --no-pager branch -a \
    | sed -e 's|^[* ]*||' -e 's|remotes/origin/||' \
    | grep -E "${PATTERN}" \
    | sort -u)
  [ -z "$cur" ] && break
  if [ "$cur" = "$prev" ]; then
    echo "Cannot delete:" >&2
    echo "$cur" >&2
    exit 1
  fi
  prev="$cur"
  while IFS= read -r br; do
    cleanup_one "$br"
  done <<<"$cur"
done
```

## Verification

After the script exits cleanly:

```bash
git fetch --prune origin
git --no-pager branch -a | grep "$PATTERN"                                   # empty
gh api repos/:owner/:repo/branches --paginate --jq '.[].name' | grep "$PATTERN"  # empty
gh pr list --state open --json headRefName --jq ".[].headRefName" | grep "$PATTERN"  # empty
```

## Example

A `perm-hack` tool creates `temp-permissions-hack-YYYYMMDD-HHMMSS` branches
per session and cleans them up after a timer expires. Without this fix, 22
orphaned remote branches accumulated across sessions because:

- Sessions on different clones each saw only their own branches via
  `git branch -a` (no `fetch --prune` first).
- A session that crashed or was Ctrl+C'd mid-cleanup left orphans the
  next session never knew about.
- A new `option 1` (create) run started during another session's cleanup
  loop produced a branch that wasn't in the original snapshot, so it
  survived.

The fix patched all three at once: each iteration starts with
`git fetch --prune origin`, the loop continues until the matched set is
empty, and a same-set-twice guard surfaces undeletable branches instead
of looping forever.

## Notes

- **Prefix vs full match.** If the filter is substring (e.g. `if PREFIX in
  branch_name`), keep the prefix consistent across all branch creators or
  cleanup will skip naming variants. Anchor with regex `^PREFIX-` if
  creators occasionally drift.
- **Silent delete failures.** `git push origin --delete` and `git branch -D`
  with `check=False` swallow permission / branch-protection errors. The
  fixed-point loop *will* detect this (same set twice) — but only if the
  caller respects the bail-out signal. Don't paper over it with try/except
  pass.
- **Related anti-pattern.** Using the return value of a `revert/destroy`
  step is critical — but a separate bug class. If a script ignores the
  return value and proceeds to delete the branch anyway, you've lost the
  only artifact that could undo the change. If revert fails, leave the
  branch alone and surface the failure.
- **Generalizes beyond git.** Any "scan + cleanup" loop over a shared
  resource (queues, temp files, IAM policies, k8s objects) has the same
  pair: snapshot-staleness from one-shot listing, and visibility-staleness
  from a stale local cache. The same fix shape applies — refresh the
  source of truth each iteration, loop to fixed point, bail on stall.

## References

- `git fetch --prune` — removes remote-tracking refs that no longer exist
  on the remote: https://git-scm.com/docs/git-fetch#Documentation/git-fetch.txt---prune
- `git branch -a` — lists local branches and locally-known remote-tracking
  refs only, not actual remote state:
  https://git-scm.com/docs/git-branch
- `gh api repos/:owner/:repo/branches` — authoritative list of branches on
  the GitHub remote: https://docs.github.com/en/rest/branches/branches
