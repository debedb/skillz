---
name: review-pr-loop
description: |
  Iteratively review a specific GitHub pull request as the reviewer:
  read the underlying issue(s) the PR claims to address, read ALL
  prior review comments / issue comments / inline threads so prior
  context is not lost, then review the new diff or the author's
  latest response. If the author has not responded yet, wait and
  re-check rather than exiting. Leave structured feedback
  (REQUEST_CHANGES / COMMENT) or APPROVE, then keep watching until
  one of the stop conditions is reached. Loop exits when you approve,
  the PR is merged or closed, or the user stops the cycle.
  Use when: (1) you are the reviewer on a non-trivial PR and want
  the agent to drive the back-and-forth, (2) the author keeps
  pushing fixes and you want each new commit re-reviewed
  automatically, (3) you want to ensure each review round actually
  reads the linked issue and prior comments rather than just the
  latest diff in isolation. Differs from the one-shot
  `pr-review-toolkit:review-pr` skill: that one is a single sweep;
  this one drives the iterative cycle and pulls issue + comment
  context every round.
author: Claude Code
version: 1.1.0
date: 2026-05-13
---

# review-pr-loop

## Problem

Reviewing a PR across multiple rounds requires more than reading the
newest diff. Each round you need to:

- (Re)read the underlying issue(s) the PR claims to address so you
  can check that the PR actually solves the stated problem (not just
  whatever the author chose to implement).
- Read ALL prior review comments and issue comments — yours and
  others' — so you don't repeat feedback already given, don't miss
  prior context, and don't lose track of items that were promised
  but not yet addressed.
- Diff only the *new* commits since your last review so you don't
  re-review code you already approved.
- Leave structured feedback (REQUEST_CHANGES if anything blocks,
  COMMENT if observations only, APPROVE if done).
- Wait for the author to push and respond, then re-evaluate.

This loop is mechanical and easy to short-cut. The skill codifies it
so each round is consistent.

## Context / Trigger Conditions

Invoke when:

- User says "review PR #N", "watch PR #N for changes and re-review",
  "review this PR loop", "act as reviewer on PR #N".
- You are the assigned or self-appointed reviewer on a PR and the
  author is iterating, or you want the agent to keep waiting for the
  next author response / push.

Do NOT use when:

- You are the PR author — use `work-on-pr` instead.
- A one-shot review is enough — use `pr-review-toolkit:review-pr`.
- The PR is already approved or merged.

## Solution

One invocation owns the watch loop. If there is no new author
activity yet, that is an idle wait state, not completion: keep
waiting and re-checking. Prefer `ScheduleWakeup` when the host
supports it; otherwise sleep and poll again in the same invocation.
Do not return just because one idle poll or sleep completed. Each
iteration:

1. **Pull full context first — every round.** This is the most
   important rule.

   a. **Linked issue(s).** From the PR body, find `Closes #N`,
      `Fixes #N`, `Refs #N`, or any GitHub issue URL. For each:
      - `gh issue view <N> --comments` — body and all comments.
      - Note the acceptance criteria, reproductions, design notes.
      - The PR must address *those* requirements, not just whatever
        the author wrote.

   b. **All prior reviews on this PR.**
      - `gh api repos/:owner/:repo/pulls/<N>/reviews` — every review,
        not just yours, in submitted_at order.
      - For each, fetch body + any inline review-comment thread:
        `gh api repos/:owner/:repo/pulls/<N>/reviews/<id>/comments`
      - Build a mental ledger of: what was raised, who raised it,
        whether the author addressed it, whether the addressor
        explicitly confirmed.

   c. **All issue comments on this PR.**
      - `gh api repos/:owner/:repo/issues/<N>/comments`.
      - Include the author's "Addressed in <sha>" replies — those
        index which commits map to which feedback.

   d. **All inline review comments** (the diff-anchored threads):
      - `gh api repos/:owner/:repo/pulls/<N>/comments` returns the
        flat list; threads are reconstructed via `in_reply_to_id`.

   Skipping this step is the most common review failure mode: you
   re-raise an objection that was already discussed three rounds
   ago, or you miss that an earlier promise was never delivered.

2. **Resolve PR coordinates.**
   - `gh pr view <N> --json
     number,state,headRefName,headRefOid,baseRefName,mergeable,
     reviewDecision,url,body`.
   - If `state != OPEN` → stop, no reschedule.

3. **Check exit conditions.**
   - `reviewDecision == APPROVED` AND latest APPROVED review is
     yours → stop, already done.
   - PR merged/closed → stop.

4. **Determine what's new since your last review.**
   - "Last review anchor" = `submitted_at` of your last review on
     this PR, or `null` if none.
   - From `gh api repos/:owner/:repo/pulls/<N>/commits`, list
     commits added after `anchor`. These define the new diff scope.
   - From comment surfaces, list author responses since `anchor`.
   - If there are no new commits and no new author responses since
     `anchor`, skip the review steps for this pass and go to step 10.

5. **First round (no prior review by you)**:
   - Treat the entire PR diff as in scope.
   - Reconcile diff against the underlying issue's acceptance
     criteria from step 1a.
   - Optionally delegate the detailed code-quality pass to
     `pr-review-toolkit:review-pr` (one-shot) and consume its output
     as input to your synthesis.

6. **Subsequent rounds**:
   - Diff = commits since your last review:
     `gh api repos/:owner/:repo/compare/<your-last-review-sha>...<headRefOid>`
   - For each prior finding of yours not yet resolved, check whether
     the new commits address it.
   - For each new author reply ("Addressed in <sha>"), verify the
     cited commit actually fixes the cited concern.
   - Check for regressions in unrelated code (the author may have
     "fixed" one issue and broken another).

7. **Synthesize the review.**

   Structure findings as severity-tagged one-liners:
   - **blocking**: must fix before merge.
   - **non-blocking**: nit / suggestion.
   - **resolved**: prior concern now addressed (record this so it
     doesn't reappear).

   For each blocking finding, write a self-contained reproduction
   or concrete example. Reviewer one-liners that compress 4
   different concerns into one sentence force the author to guess.

8. **Decide the review event.**
   - Any blocking finding remains → `REQUEST_CHANGES` (or
     `COMMENT` if the project prefers non-blocking events; check
     prior reviews on this PR for the convention).
   - No blocking findings AND all prior concerns resolved AND PR
     addresses the linked issue → `APPROVE`.
   - No blocking findings but unresolved questions → `COMMENT`.

9. **Leave the review.**
   - Single-shot review with inline comments:
     `gh pr review <N> --request-changes --body-file /tmp/body.md`
     `gh pr review <N> --approve --body-file /tmp/body.md`
     `gh pr review <N> --comment --body-file /tmp/body.md`
   - Inline comments anchored to specific lines: use
     `gh api -X POST repos/:owner/:repo/pulls/<N>/reviews
      -f body=... -f event=...
      -f 'comments[][path]=...' -f 'comments[][line]=...'
      -f 'comments[][body]=...'`
     so each blocking finding lands next to the offending line.
   - Use `--body-file`, not `-b`, to dodge shell quoting (see
     [[gh-git-heredoc-body-file]]).
   - In approval-gated sandboxes, preflight the write operations
     likely to recur in this loop: `gh pr review` and any inline
     `gh api .../reviews` posts. Reuse already-approved prefixes when
     possible, and do not treat "approval needed" as loop completion.

10. **Schedule next wake-up** unless the loop terminated.
    - Default cadence: **30 seconds**, every pass, idle or active.
    - The loop continues until a stop condition fires (you approved,
      PR merged/closed, user interrupts). Both branches — goal
      reached and user-interrupt — terminate; everything else
      reschedules.
    - If `ScheduleWakeup` exists, use it; otherwise sleep 30s and
      loop in-process.
    - **Surface status every tick.** Each pass emits one short
      user-facing line so the operator can see what changed (or
      didn't) without opening GitHub. See "Status line" below.

### Pacing

- Default poll interval: **30 seconds** (idle and active alike).
  Frequent polling burns cache but matches user-stated preference
  for tight visibility on PR turnaround.
- The user can override by passing an explicit interval to /loop
  or by saying "slow down to <N>s".
- Stop conditions still take precedence over the cadence — never
  reschedule after approve / merge / close / user-stop.

### Status line

Every iteration emits a single status line to the user, even when
nothing changed. Format suggestion:

```
PR #<N> r<round> | state=<OPEN/MERGED/CLOSED> head=<sha7>
last-author-activity=<iso> new-since-last=<n commits, m comments>
action=<leaving REVIEW | idle wait | exit:<reason>>
next=<delaySeconds>s
```

If a review was posted this pass, also include the event type and a
1-line digest of findings. If the pass was idle, that fact alone is
the status — do not pad with prose.

### Tone

- One line per finding, severity-tagged.
- No praise, no scope creep, no formatting nits unless they change
  meaning.
- Match the project's reviewer convention by reading prior reviews
  (step 1b) — some projects prefer batched threads, others prefer
  inline comments.

### Approval

When approving, include a one-sentence summary of what's done in
this round (not the whole PR history). The author already has the
history.

**Reviewing your own PR.** GitHub rejects `--approve` and
`--request-changes` events when the reviewer is the PR author
(`GraphQL: Review Can not approve / request changes on your own
pull request`). On self-review, use `--comment` and include explicit
LGTM / "blocking" language so the paired `work-on-pr` skill (or a
later merger) can read intent. This is not a stop condition: keep
the watch loop alive until merge / close / user stop. Do not retry
the same `--approve` call expecting a different answer.

## Verification

After invoking, expect (per iteration):

- A short user-facing update: "Reviewing PR #N round R. Read issue
  #X (acceptance criteria: ...), K prior reviews, M issue comments.
  Found F blocking, G non-blocking. Leaving <REQUEST_CHANGES /
  COMMENT / APPROVE>." OR "No author activity since <timestamp>;
  waiting <delay>s before the next check."
- One `gh pr review` call.
- Either a `ScheduleWakeup`, an in-process sleep / poll loop, or
  termination.

Exit signals:

- You approved → stop.
- PR closed/merged → stop.
- User stops loop → stop.
- 20 idle wake-ups → escalate.

## Example

User: "/review-pr-loop 20"

Iteration 1:
- PR body: "Closes #16. Follow-up to #14."
- `gh issue view 16 --comments` → acceptance criteria:
  three reproductions must classify as `unsafe`.
- `gh api .../pulls/20/reviews` → empty (first round).
- Diff of all commits → 1 author commit.
- Cross-check diff against #16's three repros. Find:
  - blocking: alias resolution is source-order dependent.
  - blocking: imports inside dead branches still bind.
- `gh pr review 20 --request-changes --body-file /tmp/r1.md`
- `ScheduleWakeup(270s, "/review-pr-loop 20", reason="left
  REQUEST_CHANGES; expect quick turnaround")`

Iteration 2 (after author push):
- Re-read issue #16 (still same).
- Read prior reviews (round 1 by me + 1 author reply).
- New commits since my last review = 1.
- Verify the two prior blocking findings are addressed by the
  new commit.
- Find: blocking — top-level rebind retroactively erases an
  earlier destructive call. Leave REQUEST_CHANGES with the
  concrete repro.
- Sleep 270s.

... continue until:

Iteration 6:
- All prior blocking concerns resolved.
- Latest commit only adds annotation walk → identifies a new
  false-positive risk (PEP 563). Leave REQUEST_CHANGES.

Iteration 7:
- Author removed annotation walk. Re-read everything. No new
  blocking. `gh pr review 20 --approve --body-file /tmp/approval.md`
- Stop.

## Notes

- **Reading the linked issue every round is non-negotiable.** PR
  scope creep is easy to miss when you only look at the diff. A
  good check: can you state the acceptance criteria from the issue
  in your own words before reviewing the diff? If not, re-read.
- **Reading ALL comments every round** matters because:
  - The author may have explicitly responded to a prior concern in
    a comment without including it in a commit — verify the response
    actually resolves the concern.
  - Another reviewer may have raised a separate concern in parallel
    that you should not contradict without acknowledging.
  - The issue itself may have been updated by the user mid-cycle.
- **Diff scope**: review only commits since your last review unless
  this is your first round. Don't re-review approved code.
- **Invoking before the author responds is expected.** The skill's
  job is to keep watching until there is something new to review.
- **In a multi-reviewer PR**, prefer leaving comments addressed to
  the specific author's last response rather than top-level
  comments, so threads stay coherent.
- **First-round delegation**: for the initial sweep, consider
  spawning `pr-review-toolkit:review-pr` as an inner step to get a
  thorough quality pass; consume its output and add issue-fit
  reasoning on top. Subsequent rounds are usually narrow enough to
  do directly.
- **Approval phrase in comments**: if you choose to communicate
  approval via a plain comment ("LGTM") rather than the GitHub
  approve button, the paired `work-on-pr` skill recognizes this.
  Prefer the explicit `--approve` event so `reviewDecision`
  reflects it.
- **gh CLI vs API**: `gh pr review` for the event; `gh api` for
  per-thread inline comments and for fetching review bodies by ID.
- **Scheduler fallback**: if `ScheduleWakeup` is unavailable in the
  host agent, keep the current turn alive with `sleep` + re-poll
  instead of returning early on an idle pass.
- **Approval-aware execution**: in constrained sandboxes, GitHub
  review submissions and inline review-comment writes may need
  approval. Ask once with stable command shapes if needed, then keep
  the loop going until a real stop condition fires.

## References

- [GitHub REST: pulls/reviews](https://docs.github.com/en/rest/pulls/reviews)
- [GitHub REST: pulls/comments (inline)](https://docs.github.com/en/rest/pulls/comments)
- [GitHub REST: issues/comments (top-level)](https://docs.github.com/en/rest/issues/comments)
- [gh pr review](https://cli.github.com/manual/gh_pr_review)
- Related skills: [[work-on-pr]] (author side of the same loop),
  [[pr-review-toolkit:review-pr]] (one-shot review),
  [[gh-git-heredoc-body-file]] (body-file pattern).
