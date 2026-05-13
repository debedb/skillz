---
name: work-on-pr
description: |
  Iteratively work on a specific GitHub pull request as the PR author:
  watch for new review comments / issue comments / inline review
  threads. If none exist yet, wait and re-check rather than exiting.
  Address each one (implement fix in a worktree, run tests, commit,
  push), post a reply summarizing the fix + commit SHA, then keep
  waiting until one of the stop conditions is reached. Loop exits
  when the PR is approved
  (`reviewDecision == APPROVED`, or a reviewer leaves an approval-
  phrase comment), when the PR is merged / closed, or when the user
  stops the cycle. Use when: (1) you opened a PR and are now in a
  back-and-forth review cycle and want the agent to drive each
  iteration end-to-end, (2) reviewer keeps catching new issues across
  multiple rounds and a one-shot reply is not enough, (3) you want to
  hand off the address-reply-wait loop to the agent so the human only
  intervenes at approval / scope changes. Differs from the one-shot
  `pr-review-toolkit:review-pr`: that one reviews; this one is the
  author side and drives the entire iterative cycle.
author: Claude Code
version: 1.0.2
date: 2026-05-12
---

# work-on-pr

## Problem

A non-trivial PR usually goes through several review rounds. The
mechanical loop — fetch the latest review, understand it, implement
the fix, run tests, commit + push, post a reply with the commit SHA,
wait, repeat — is well-defined and tedious. If the agent owns the
loop, the human only needs to step in for scope decisions and the
final merge. Without a structured loop the agent forgets to:

- check for *new* reviews vs ones already addressed,
- run tests before pushing,
- include the commit SHA in the reply,
- reuse the existing worktree instead of creating a new one,
- pace polling against the prompt-cache TTL,
- keep waiting when the PR is quiet and no comments have landed yet,
- avoid ad hoc sub-minute polling that burns turns without reaching a
  stop condition,
- detect the approval / merge exit conditions.

This skill codifies that loop.

## Context / Trigger Conditions

Invoke when:

- User says "address this comment", "address the next comment",
  "iterate on PR #N", "work on PR #N", "watch PR #N for feedback".
- A PR is open and either feedback already exists or is expected
  soon, and the user wants the agent to drive the iteration.
- After an initial PR has been opened (e.g. by the feature-dev or
  rapid-prototyper flow) and review feedback is starting to arrive.

Do NOT use when:

- Opening a brand new PR (use the normal feature-branch + `gh pr
  create` flow first, then hand off here).
- Just reviewing someone else's PR — see `review-pr-loop` instead.
- The PR is already approved or merged — nothing to drive.

## Solution

One invocation owns the watch loop until a termination condition is
reached or the user interrupts it. If there is no actionable
reviewer activity yet, that is an idle wait state, not success: keep
waiting and re-checking. Prefer `ScheduleWakeup` when the host
supports it; otherwise sleep and poll again in the same invocation.
Do not return just because a quiet poll or one sleep interval
completed. A loop round only ends early if it actually scheduled a
continuation elsewhere, or if a real stop condition fired.

### Single-iteration flow

1. **Resolve PR coordinates.**
   - PR identifier from skill args: number, URL, or branch.
   - `gh pr view <N> --json
     number,state,headRefName,headRefOid,baseRefName,mergeable,reviewDecision,url`
   - If `state != OPEN` → report and stop (no reschedule).

2. **Check exit condition: approved.**
   - `reviewDecision == "APPROVED"` → stop, report success.
   - Or fetch latest review: `gh api repos/:owner/:repo/pulls/<N>/reviews`,
     last entry `state == "APPROVED"` → stop.
   - Or an issue comment whose body matches `/\b(lgtm|ship it|approved|approve)\b/i`
     from a maintainer → stop.

3. **Reuse or create the worktree.**
   - Naming convention: `<repo-root>-wt-<N>` (matches the
     `feedback-worktree-pr-workflow` convention).
   - `git worktree list` to check; if absent, create one at
     `feature/<branch-name>` tracking `origin/<headRefName>`.
   - `cd <worktree>` for all subsequent edits.
   - If the host uses sandbox approvals, preflight the operations
     this loop is likely to need: `git add` / `git commit`,
     `git push origin <branch>`, `gh pr comment`, and inline
     `gh api .../replies`.
   - Reuse already-approved command prefixes when possible.
   - If approvals are likely to recur, request scoped prefix
     approvals up front rather than waiting until after tests pass.
   - An approval request is not a stop condition; once granted,
     continue the loop.

4. **Determine what's new since last addressed.**
   - "Last addressed" anchor = max(committed_at of head commit,
     created_at of last issue comment posted by the authenticated
     user). Compute via:
     - `gh api repos/:owner/:repo/commits/<headRefOid> --jq .committer.date`
     - `gh api repos/:owner/:repo/issues/<N>/comments
        --jq '[.[] | select(.user.login == "<me>")] | last | .created_at'`
   - Take the MAX. Call it `anchor_ts`.
   - Fetch all three comment surfaces:
     - reviews: `gh api repos/:owner/:repo/pulls/<N>/reviews`
     - issue comments: `gh api repos/:owner/:repo/issues/<N>/comments`
     - inline review comments: `gh api repos/:owner/:repo/pulls/<N>/comments`
   - Filter to items with `submitted_at > anchor_ts` (reviews) or
     `created_at > anchor_ts` (comments) AND author != self.
   - Approval-only reviews (no body, state=APPROVED) → handled in
     step 2; otherwise treat the body as actionable.

5. **No new actionable items yet → keep waiting.**
   - No comments yet is not completion; the reviewer may simply not
     have responded yet.
   - Recent activity (anchor < 10 min old) → short delay
     (`270s` to stay inside the 5-minute prompt-cache TTL).
   - Quiet (anchor > 30 min) → long delay (`1800s` or `3600s`).
   - If the environment exposes `ScheduleWakeup`, schedule the next
     check with the same `/work-on-pr <N>` prompt and end the current
     iteration.
   - Otherwise send a brief user-facing wait update, sleep for the
     chosen delay, and jump back to step 1 in the same invocation.
   - Do not substitute ad hoc `30s` sleeps unless the user explicitly
     asked for aggressive polling.
   - Only terminate on approval / merge / user stop / hard-cap
     escalation.

6. **For each new actionable item:**

   a. Read the full body.

   b. **Plan + implement** in the worktree. Edit files, follow
      the project's conventions (read CLAUDE.md / README).

   c. **Run the project's test suite.** No commits / pushes if tests
      fail. Diagnose, fix, re-run. If a test failure surfaces an
      ambiguity in the reviewer's ask, fall back to step 7 (escalate).

   d. **Commit** in the worktree with a real message describing the
      fix and which review/comment ID it addresses. Use HEREDOC via a
      `/tmp` file for the commit body to avoid shell-quoting traps
      when the body contains quotes or backticks (see
      `gh-git-heredoc-body-file` skill).

   e. **Push** the feature branch.

   f. **Post a reply.** Body explains what was done and references
      the commit SHA. Use `gh pr comment <N> --body-file /tmp/...` —
      `--body-file`, not `-b`, to dodge shell quoting.
      For inline review-thread replies, use
      `gh api repos/:owner/:repo/pulls/<N>/comments/<comment_id>/replies
       -f body=@/tmp/reply.md` or the `--in-reply-to` form of `gh
      api`.

7. **Escalate to the user** when:
   - A reviewer asked for a scope change you cannot interpret without
     guidance.
   - Tests fail in a way that suggests the fix would have to touch
     unrelated code.
   - Conflicting requests across reviewers.
   - Merge conflicts with base branch.
   - Stop the loop, summarize, ask the user how to proceed.

8. **Re-check exit condition** (step 2) after each address cycle. A
   reviewer that approved AND left a final comment is still
   approved.

9. **After each addressed cycle, return to waiting.** Adaptive delay:
   - Just pushed a fix → 270s (cache-warm, expect quick reviewer
     turn).
   - Quiet period → 1800s.
   - User instructed "check daily" → 3600s.
   - If `ScheduleWakeup` exists, use it; otherwise sleep and loop
     in-process.
   - Keep the same delay policy in-process; do not collapse to short
     ad hoc sleeps just because the loop is already running.
   - Skip further waiting if the loop has terminated.

### Pacing rules

- Anthropic prompt cache TTL is 5 min. Stay under 270s when
  expecting quick turn; jump to ≥1200s when genuinely idle. Don't
  pick 300s — worst-of-both.
- "No new comments yet" is an idle state, not a success condition.
- Sub-minute sleeps are only for explicit user overrides, not the
  default watch loop.
- One iteration = one poll / action cycle.
- Hard cap suggested: 20 idle polls without progress → stop and
  escalate to the user with the current status.

### Reply convention

- Always reference the commit SHA: `Addressed in 6f23a45.`
- Summarize the fix in ≤4 sentences, then a short code block when
  useful.
- Don't restate the reviewer's text.
- Don't promise future work in the same PR scope — open a new issue
  if needed.

### Worktree + branch hygiene

- Branch name: `feature/<kebab-name>` (matches PRs #8-#13 lineage in
  voitta-yolt; carry-over from the user's worktree-PR memory).
- Never amend or force-push unless the user explicitly requests it.
  Add new commits per round so the review history is intact.
- Don't skip hooks (no `--no-verify`).
- Use `--body-file` everywhere (`gh pr create`, `gh pr comment`,
  `gh issue comment`) to avoid quoting traps. See
  [[gh-git-heredoc-body-file]].

## Verification

After invoking, expect to see (per iteration):

- A single short user-facing update: "Iteration N on PR #X. Found M
  new comment(s). Addressing comment <id>." OR "No new comments yet
  as of <timestamp>; waiting <delay>s before the next check."
- One commit pushed per round (only when there were actionable
  comments).
- One reply posted per addressed comment.
- Either a `ScheduleWakeup` call or an in-process sleep / poll loop
  unless the loop exited.

Exit signals:

- `reviewDecision == APPROVED` → summary + stop.
- PR merged/closed → summary + stop.
- User says "stop" / interrupts → summary + stop.

## Example

User: "/work-on-pr 20"

Iteration 1:
- `gh pr view 20` → state=OPEN, headRefName=`feature/foo`,
  reviewDecision=`CHANGES_REQUESTED`.
- Worktree at `<repo>-wt-20` doesn't exist → create.
- Anchor = head commit committed_at = `2026-05-12T18:00:00Z`.
- No review activity yet. Wait 270s via `ScheduleWakeup` (or sleep
  270s and re-poll if no scheduler exists).

Iteration 2:
- `gh pr view 20` → state=OPEN, headRefName=`feature/foo`,
  reviewDecision=`CHANGES_REQUESTED`.
- Reviews since anchor → one new review (id 999, state COMMENTED).
- Read body: "Annotation calls flagged as destructive — that's
  wrong under PEP 563."
- Implement fix in worktree, run `python3 -m unittest discover
  tests`, commit, push.
- Post reply via `gh pr comment 20 --body-file /tmp/reply.md`
  starting with "Addressed in <sha>."
- `ScheduleWakeup(delaySeconds=270, prompt="/work-on-pr 20",
  reason="just pushed reply to review 999; expect fast turnaround")`

Iteration 3 (270s later):
- Anchor = new head commit committed_at.
- No new reviews/comments. Bump to `ScheduleWakeup(delaySeconds=1800,
  ...)`

Iteration 8:
- Latest review state == APPROVED → exit. Final summary:
  "PR #20 approved by @reviewer in 7 rounds. Ready to merge."

## Notes

- **State derivation, not persistence**: each invocation re-derives
  what's new from GitHub timestamps and the bot's own posted
  comments. No `.claude/work-on-pr-state.json` needed.
- **Invoking before comments exist is expected.** The skill's job is
  to watch the PR until feedback arrives, not to treat an empty poll
  as completion.
- **Approval phrase detection** is heuristic. A maintainer comment
  with the literal words "I approve" without using the GitHub
  approve button counts here; if false-positive risk is high in a
  given project, restrict to the `reviewDecision` field only.
- **Inline review comments** (`pulls/N/comments`) are threaded;
  replying requires `--in-reply-to` or the dedicated `/replies`
  endpoint. Issue comments use `gh pr comment` / `gh issue comment`.
- **Worktree cleanup**: don't remove the worktree until the PR
  merges. After merge, `git worktree remove <path> && git branch -D
  <branch>`.
- **gh CLI vs API**: prefer `gh pr view --json` for top-level state;
  drop to `gh api` for the per-thread surfaces and for fields the
  high-level commands don't expose (committed_at, individual review
  bodies by ID).
- **Scheduler fallback**: if `ScheduleWakeup` is unavailable in the
  host agent, keep the current turn alive with `sleep` + re-poll
  instead of returning "nothing to do".
- **Approval-aware execution**: in constrained sandboxes, `git add` /
  `git commit` may need approval for shared git metadata writes, and
  `git push` / `gh pr comment` / inline `gh api` replies may need
  approval for network writes. Anticipate those operations, keep the
  command forms stable so prefix approvals can be reused, and do not
  treat "approval needed" as loop completion.
- **Multiple new comments in one wake-up**: address them in
  submitted_at order; one commit per coherent fix-set is fine, as
  long as each addressed comment gets its own reply with the same
  commit SHA referenced.
- **CI failures** that come in as a check (not a review) can be
  treated like a comment if the user opted into "address CI
  failures too"; default is to surface CI failures to the user
  rather than auto-fix.

## References

- [GitHub REST: list reviews on a PR](https://docs.github.com/en/rest/pulls/reviews)
- [GitHub REST: list issue comments](https://docs.github.com/en/rest/issues/comments)
- [GitHub REST: list review comments on a PR](https://docs.github.com/en/rest/pulls/comments)
- [gh pr view / gh pr comment](https://cli.github.com/manual/gh_pr)
- Related skills: [[review-pr-loop]] (reviewer side),
  [[gh-git-heredoc-body-file]] (body-file pattern),
  [[python-ast-static-analyzer-scoping]] (worked example of an
  iterative review cycle this skill drove).
