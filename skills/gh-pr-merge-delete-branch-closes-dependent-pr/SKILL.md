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
  reopen a PR closed by the base-branch-delete cascade. Root cause:
  GitHub auto-closes (does not retarget) dependent PRs when their base
  ref vanishes. `gh pr reopen` then fails with
  "GraphQL: Could not open the pull request" because the base ref no
  longer exists. Fix: recreate the deleted ref via
  `gh api repos/OWNER/REPO/git/refs -f ref='refs/heads/<deleted>' -f sha='<some-sha>'`,
  reopen the PR, retarget its base to your real target (usually main),
  optionally delete the recreated ref again. Hit twice in one session
  on a 3-PR stack (#82 → #71 → #84) because the gh-merge of each PR's
  predecessor cascaded the close to the next. Also covers (4) the
  fallback where you abandon the closed PR and open a replacement from
  the same head branch — that path needs
  `git rebase --onto origin/master <old-base-head> <branch>` first, or
  the new PR's diff re-includes the whole already-merged base PR and
  reads as a revert-and-reapply of someone else's work.
author: Claude Code
version: 1.1.0
date: 2026-08-14
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
- It also applies to PRs from forks if the upstream fork branch is
  deleted, though those rarely sit in a stacked configuration.
- The resurrected ref doesn't have to point at the original SHA; any
  reachable commit works for `gh pr reopen` to succeed. We use
  `main`'s tip because it's stable and won't break anything.
- If you don't care about the dependent PR's review history (no
  approvals, no inline comments worth preserving), it's cleaner to
  let it stay closed and open a fresh PR from the same head branch
  against the correct base. The recovery procedure above is for when
  you *do* want the history. **That fallback needs a rebase first —
  see the next section.**

## The fresh-PR fallback needs a rebase the recovery path doesn't

If you take the "let it stay closed, open a fresh PR" route, do **not**
push the head branch at the new base as-is. It still carries the base
branch's original commits, while the target branch holds that same
content as a *single squash commit*. Git sees two histories with no
commits in common, so the replacement PR's diff re-includes the whole
upstream PR — it reads as though you reverted and reapplied someone
else's already-merged work.

Drop the already-absorbed commits first:

```bash
# <old-base-head> = last commit of the branch that was merged and
# deleted. Get it from the merged PR, or locally before it ages out:
#   git rev-parse <deleted-branch>@{1}
git rebase --onto origin/master <old-base-head> <feature-branch>

# Confirm only your own change remains:
git --no-pager diff origin/master --stat
git --no-pager log --oneline origin/master..HEAD

git push -f origin <feature-branch>
gh pr create --base master --head <feature-branch> ...
```

Then comment on the auto-closed PR pointing at the replacement, so the
old review history stays discoverable from it:

```bash
gh pr comment <closed-pr> --repo OWNER/REPO \
  --body "Superseded by #<new>. Auto-closed when its base branch was
deleted on merging #<base>; a closed PR whose base ref no longer exists
cannot be reopened or retargeted."
```

**Why only this path needs it:** the recreate-the-ref recovery leaves the
PR's own commits untouched and lets GitHub compare against the real base,
where it resolves the duplicated content to an empty diff (see
*Verification*). The fresh-PR path asks git to diff two histories that
share content but no commits, which git cannot resolve on its own. That
asymmetry is exactly why the rebase is easy to forget — the recovery path
trains you to expect GitHub to sort it out.

## Related skills

- `multi-phase-feature-pr-worktrees` — stacked-PR worktree
  conventions where this trap is most likely to appear.
