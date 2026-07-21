---
name: gh-pr-merge-delete-branch-closes-dependent-pr
description: |
  Fix the surprising auto-close of stacked / dependent PRs when their
  base branch gets deleted on GitHub. Use when: (1) you ran
  `gh pr merge --delete-branch` (or any branch-deleting merge action) on
  PR A, and PR B which was based on PR A is now CLOSED with no warning —
  not retargeted to the repo's default branch as you might expect,
  (2) a stacked-PR workflow where each PR in the chain has its base set
  to the previous PR's head, and you'd like to land them in sequence
  without losing the dependent PRs' review history, (3) you want to
  reopen a PR closed by the base-branch-delete cascade, (4) the repo has
  `delete_branch_on_merge: true` so merging the base PR deletes its
  branch automatically and closes the child even when you did not pass
  `--delete-branch`. Root cause: GitHub auto-retargets a dependent PR to
  the merged PR's base ONLY when the branch is deleted via the web merge
  box button; `gh pr merge --delete-branch`, an API/`git push --delete`
  ref-delete, and the repo `delete_branch_on_merge` auto-delete do NOT
  retarget — they auto-CLOSE the dependent PR, and it cannot be reopened
  because its base ref no longer exists. `gh pr reopen` fails with
  "GraphQL: Could not open the pull request". Fix: recreate the deleted
  ref via
  `gh api repos/OWNER/REPO/git/refs -f ref='refs/heads/<deleted>' -f sha='<some-sha>'`,
  reopen the PR, retarget its base to your real target (usually main),
  optionally delete the recreated ref again. Prevention: retarget every
  child PR to main BEFORE merging the base PR. Hit twice in one session
  on a 3-PR stack (#82 → #71 → #84) because the gh-merge of each PR's
  predecessor cascaded the close to the next.
author: Claude Code
version: 1.1.0
date: 2026-07-21
---

# `gh pr merge --delete-branch` closes (not retargets) dependent PRs

## Problem

You have a stacked PR chain on GitHub:

```
main ←— PR A (base=main,        head=feature/A)
        PR B (base=feature/A,   head=feature/B)
        PR C (base=feature/B,   head=feature/C)
```

You squash-merge PR A with `gh pr merge --delete-branch`. Two things
happen at the GitHub API level:

1. A squash commit lands on `main`.
2. The `feature/A` branch ref is **deleted** on the remote.

You'd expect GitHub to auto-retarget PR B's base to the repo's default
branch (`main`). It does not. Instead:

- **PR B is auto-CLOSED** (state goes to `CLOSED`, not `OPEN`).
- The review history, comments, approvals, and check results stay
  attached to PR B, but it's closed.
- `gh pr reopen B` fails with `GraphQL: Could not open the pull
  request. (reopenPullRequest)` because GitHub can't reopen a PR whose
  `baseRefName` points at a ref that no longer exists on the remote.

The cascade can chain: if you then merge PR B (after reopening), the
same thing happens to PR C, etc.

### Why "GitHub auto-retargets stacked PRs" doesn't save you

GitHub *does* have auto-retargeting (shipped 2020) — but it fires on a
**narrow path only**: merging the base PR **and deleting its branch via
the web merge-box button**. Every other deletion path skips retarget and
**closes** the child instead:

- `gh pr merge --delete-branch` (the CLI) — see cli/cli#1168.
- An API / `git push origin --delete <branch>` ref deletion.
- The repo setting **`delete_branch_on_merge: true`** — the branch is
  auto-deleted on merge regardless of how you merge, so *not* passing
  `--delete-branch` does **not** save you. This is the most surprising
  case: a plain `gh pr merge --squash` (no delete flag) still closes the
  child because the repo deletes the branch for you.

So on any repo with auto-delete enabled, or any merge done from the CLI,
treat the trap as **always armed** for stacked PRs.

### Check your exposure before merging

```bash
# 1. Does the repo auto-delete branches on merge? true => trap fires on ANY merge.
gh api repos/OWNER/REPO --jq '.delete_branch_on_merge'

# 2. Is a given PR stacked? base != main/master => exposed.
gh pr view <child> --repo OWNER/REPO --json baseRefName --jq '.baseRefName'

# 3. Confirm the failure mode on an already-dead PR (base_ref_deleted +
#    closed at the same timestamp, merged:null => auto-closed, not merged):
gh api "repos/OWNER/REPO/issues/<child>/timeline" \
  -H "Accept: application/vnd.github.mockingbird-preview+json" \
  --jq '[.[] | select(.event=="base_ref_deleted" or .event=="closed" or .event=="merged")]'
```

## Symptoms

- After `gh pr merge --delete-branch N`, querying a downstream PR M
  whose base was that branch shows:
  ```
  gh pr view M --json state,baseRefName,closed,closedAt
  → {"baseRefName":"feature/A","closed":true,"closedAt":"...","state":"CLOSED"}
  ```
- `gh pr reopen M` returns:
  ```
  GraphQL: Could not open the pull request. (reopenPullRequest)
  ```
- `gh pr edit M --base main` on the closed PR returns:
  ```
  GraphQL: Cannot change the base branch of a closed pull request. (updatePullRequest)
  ```

## Fix

Recreate the deleted base ref temporarily so the PR can be reopened
and retargeted:

```bash
# 1. Get a sensible SHA to point the resurrected branch at. main's tip
#    is fine — the PR's base ref just needs to *exist* for reopen to
#    succeed.
SHA=$(gh api repos/OWNER/REPO/branches/main --jq '.commit.sha')

# 2. Recreate the deleted branch ref at that SHA.
gh api repos/OWNER/REPO/git/refs \
  -f ref="refs/heads/<deleted-branch>" \
  -f sha="$SHA"

# 3. Reopen the dependent PR + retarget to your real base.
gh pr reopen M --repo OWNER/REPO
gh pr edit   M --repo OWNER/REPO --base main

# 4. Verify the PR is back open and pointed at main.
gh pr view M --repo OWNER/REPO --json state,baseRefName,mergeStateStatus,mergeable
# → state=OPEN, baseRefName=main

# 5. (Optional) clean up the resurrected branch — once PR M's base is
#    no longer pointed at it, it can be deleted again safely.
gh api -X DELETE repos/OWNER/REPO/git/refs/heads/<deleted-branch>
```

## Verification

After step 4:

- `state` is `OPEN`.
- `baseRefName` is `main` (or whichever real base you set).
- `mergeStateStatus` is `CLEAN` / `MERGEABLE` if the commits don't
  conflict against the new base. (If the rebased commits from the
  upstream PR are now duplicated in main via the squash, GitHub
  usually recognizes the diff is empty for those and the merge stays
  clean.)
- The PR's review history, comments, and approvals are unchanged from
  before the close.

## Prevention

Pre-emptively retarget downstream PRs **before** merging the upstream
PR with `--delete-branch`:

```bash
# Before merging PR A:
gh pr edit B --repo OWNER/REPO --base main
gh pr edit C --repo OWNER/REPO --base main  # if C exists too

# Then safe to:
gh pr merge A --repo OWNER/REPO --squash --delete-branch
```

This way the dependent PRs are already pointed at `main` when their
old base disappears, GitHub has nothing to close them over, and the
review state continues seamlessly.

For long chains, retarget the *whole* downstream chain to `main` up
front, then squash-merge the top of the stack normally. Downstream
PRs may need to be rebased onto the new base before they're clean,
which is usually expected on a stacked workflow anyway.

### Annotate the child PR the moment you stack it

The person who merges the base PR weeks later — possibly not you — won't
remember the stack. When you create a stacked PR, immediately prepend a
merge-order warning to its body so the trap is visible at merge time:

```markdown
> [!WARNING]
> **STACKED PR — merge order matters.** Base is `feature/A` (#A), and this
> repo auto-deletes head branches on merge. If #A is merged while this PR
> still points at its branch, GitHub will **auto-close this PR** (base ref
> deleted → child closed, not retargeted; unopenable).
> **Before merging #A:** `gh pr edit <this> --base main`, then merge #A,
> then rebase this PR onto `main` and merge.
```

`gh pr edit <child> --body-file /tmp/body.md` (prepend to the existing
body). Cheap insurance against a silent, unrecoverable close.

## Why this is non-obvious

- The `gh` CLI gives no warning that the merge will cascade-close
  downstream PRs.
- GitHub's web UI shows a small banner on the closed PR pointing at
  the original base branch, but it doesn't link to a recovery path.
- Many people expect "auto-retarget to default branch" because that's
  the behavior some other forges (GitLab, Bitbucket) implement.
- The error from `gh pr reopen` (`Could not open the pull request`)
  doesn't explain the root cause — you have to know to check whether
  the base ref still exists on the remote.

## Notes

- The exact same cascade applies to manual branch deletion via
  `gh api -X DELETE repos/OWNER/REPO/git/refs/heads/X` or
  `git push origin --delete X` — anything that removes the ref.
- **Repo `delete_branch_on_merge: true` is the sneakiest trigger.** The
  branch is deleted for you on every merge, so the trap fires even from a
  plain `gh pr merge --squash` with no delete flag, and even from a
  web-UI merge if the auto-delete (rather than the merge-box button) is
  what removes the branch. On such repos, retargeting children first is
  mandatory, not optional. Check with
  `gh api repos/OWNER/REPO --jq .delete_branch_on_merge`.
- It also applies to PRs from forks if the upstream fork branch is
  deleted, though those rarely sit in a stacked configuration.
- The resurrected ref doesn't have to point at the original SHA; any
  reachable commit works for `gh pr reopen` to succeed. We use
  `main`'s tip because it's stable and won't break anything.
- If you don't care about the dependent PR's review history (no
  approvals, no inline comments worth preserving), it's cleaner to
  let it stay closed and open a fresh PR from the same head branch
  against the correct base. The recovery procedure above is for when
  you *do* want the history.

## References

- [Pull request retargeting — GitHub Changelog (2020-05-19)](https://github.blog/changelog/2020-05-19-pull-request-retargeting/)
  — introduced retarget-on-merge; note it applies to the web merge path.
- [cli/cli#1168 — `gh pr merge --delete-branch` does not update base of dependent PRs](https://github.com/cli/cli/issues/1168)
  — the CLI path closes instead of retargeting.
- [community#70017 — Pulls marked closed instead of merged when pushing and deleting the branch](https://github.com/orgs/community/discussions/70017)
- [Merging a pull request — GitHub Docs](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-a-pull-request)

## Related skills

- `multi-phase-feature-pr-worktrees` — stacked-PR worktree
  conventions where this trap is most likely to appear.
