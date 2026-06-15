---
name: github-closing-keywords-default-branch-only
description: |
  Explains why GitHub issues stay OPEN even though their PRs say
  `Closes #N`/`Fixes #N` and merged successfully. Use when: (1) you
  merged a stack of PRs that each reference an issue with a closing
  keyword but the issues are all still open, (2) the PRs merged into a
  long-lived integration / feature / migration branch (e.g. `eks`,
  `develop`, `release/*`) rather than the repo's DEFAULT branch
  (`main`/`master`), (3) you're auditing "did we close all the issues?"
  after a multi-PR effort. Root cause: GitHub auto-closes a referenced
  issue ONLY when the closing keyword lands on the repository's DEFAULT
  branch. Merges to any other branch never close issues. Compounded in
  squash-only repos: when the integration branch later squash-merges to
  main, the single squash commit body carries only the integration PR's
  description — the sub-PRs' `Closes #N` keywords are gone, so they
  still won't auto-close. Fix: close manually, or put the `Closes #N`
  lines on the PR that merges INTO the default branch.
author: Claude Code
version: 1.0.0
date: 2026-06-03
---

# GitHub closing keywords only fire on the default branch

## Problem

A batch of PRs each had `Closes #N` (or `Fixes`/`Resolves`) in the body,
all merged green — yet every referenced issue is still OPEN. Looks like
GitHub "forgot" to close them.

## Context / Trigger Conditions

- Multiple merged PRs that reference issues with closing keywords.
- The PRs merged into a **non-default** branch — a long-lived
  integration / migration / release branch (e.g. `eks`, `develop`,
  `staging`, `release/x`) — NOT `main`/`master`.
- Symptom: `gh issue list --state open` still shows all the "done" issues.

## Root cause

GitHub only auto-closes an issue from a closing keyword when the commit
/ PR carrying that keyword is merged into the **repository's default
branch**. A merge into any other branch does not close the issue, no
matter how the keyword is written. This is by design (the issue is only
"done" when the fix reaches the default line).

Compounding factor in **squash-only** repos: when the integration branch
is eventually merged to the default branch, a squash merge collapses all
its commits into ONE commit whose body is the *integration PR's*
description. The individual sub-PRs' `Closes #N` lines are not in that
body, so even the final main merge won't auto-close them — unless the
integration PR itself lists the closing keywords.

## Solution

Pick one:

1. **Close manually now** (when the work is genuinely done on the
   integration branch and validated), with a comment linking the
   implementing PR:
   ```bash
   gh issue close 207 --comment "Done in #224 (merged to eks, verified in dev). Prod rollout tracked in #213/#214."
   ```
2. **Defer closure to the default-branch merge**: put the closing
   keywords on the PR that merges the integration branch INTO main, e.g.
   the integration PR body:
   ```
   Closes #207, #208, #209, #210, #212, #216
   ```
   Then a (squash) merge of that PR to `main` closes them all at once.

Distinguish "done on integration branch / in dev" from "shipped to the
default branch / prod" — close the substrate subtasks that are truly
complete; leave cutover/teardown subtasks open.

## Verification

`gh issue list --state open` no longer lists the completed issues; each
closed issue has a comment pointing at its implementing PR.

## Notes

- Same rule applies to closing keywords in commit messages, not just PR
  bodies — they must land on the default branch.
- This is easy to miss in an ECS->EKS / blue-green / trunk-vs-release
  workflow where lots of PRs merge to a long-lived branch first.
- Don't assume a green merge == closed issue; explicitly audit after a
  multi-PR push.

## References

- GitHub docs: "Linking a pull request to an issue" — auto-close happens
  when the PR is merged into the repository's default branch.
