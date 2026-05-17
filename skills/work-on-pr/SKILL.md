---
name: work-on-pr
description: |
  Iteratively work on a GitHub pull request as the author. Watch for new review comments, issue comments, and inline threads; if nothing new exists yet, wait and re-check instead of exiting. For each actionable item, implement the fix in the PR worktree, run relevant tests, commit and push, then reply with a summary and commit SHA. Continue until the PR is approved, merged or closed, or the user stops the loop. Also accepts an issue reference instead of a PR: in that case the skill creates the PR (if absent), guarantees the PR body contains `Closes #<issue>`, and then enters the watch loop. Use when you want the agent to own the start-PR or address-test-push-reply-wait cycle across multiple review rounds rather than handling a single review comment.
author: Claude Code
version: 1.6.0
date: 2026-05-16
source: https://github.com/voitta-ai/skillz
source_file: skills/work-on-pr/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file: `skills/work-on-pr/SKILL.md`).
> Updates go through the repo's worktree + PR workflow — open an issue,
> branch, PR. The repo replaced gist 5f606018eb36a75dc292016268f08e7c,
> which is preserved as a redirect.

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
- The user supplies an **issue** reference (URL or `#N`) and asks
  the agent to start a PR. The skill creates the PR (if not yet
  open) and then enters the watch loop. The created PR body MUST
  contain `Closes #<issue>` so merging the PR auto-closes the
  issue.

Do NOT use when:

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

1. **Resolve invocation target.**
   - Parse the skill args. Two valid shapes:
     - **PR ref**: number, PR URL, or branch name. Skip to 1a.
     - **Issue ref**: issue URL (`https://github.com/<owner>/<repo>/issues/<N>`)
       or `#<N>` plus repo context. Go through 1b first.
   - **1a. Existing PR:** `gh pr view <N> --json
     number,state,headRefName,headRefOid,baseRefName,mergeable,reviewDecision,url,body`.
     If `state != OPEN` → report and stop (no reschedule). Then run
     step 1c (issue-linkage repair).
   - **1b. Issue → PR (create if absent):** check whether a PR
     already exists for the issue:
     - `gh pr list --repo <owner>/<repo> --search "Closes #<N> in:body" --state open --json number,url`,
       or grep the user-author's open PRs for a branch matching the
       issue.
     - If no PR exists, create the worktree (step 3) and the feature
       branch, scaffold the work needed by the issue, push, then run
       `gh pr create` with a body that includes `Closes #<N>` (use a
       `--body-file` heredoc so quoting survives). The PR's first
       commit on the branch is fine even if it is just a scaffolding
       commit; subsequent rounds add real fixes. After creation,
       continue with step 2 on the just-created PR.
     - If a PR exists, hand off to step 1a.
   - **1c. Issue-linkage repair (existing PR + known issue):**
     when the invocation arg is an issue ref AND an open PR was
     found, check whether the PR's body contains a closing keyword
     for that issue:
     ```
     /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#<N>\b/i
     ```
     (also accept `<owner>/<repo>#<N>` form). If absent, edit the
     PR body to append `Closes #<N>`:
     ```
     body=$(gh pr view <PR> --json body --jq .body)
     printf '%s\n\nCloses #%s\n' "$body" <N> > /tmp/pr-body.md
     gh pr edit <PR> --body-file /tmp/pr-body.md
     ```
     Use `--body-file` so multiline bodies and backticks survive.
     This step is idempotent; running it on a PR that already has
     `Closes #<N>` is a no-op.

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
   - Run subsequent git operations in single-shot form via
     `git -C <worktree-path> <subcommand> ...`. Do NOT chain a
     `cd <worktree>` with `&&` in front of `git`. The compound
     does not match any single `Bash(git ...)` allow pattern, so
     it forces a permission prompt every time even when the
     standalone git command would have been auto-allowed. See the
     "Auto-approved operations" section below for the matching
     allow entries.
   - For ad-hoc reads (`git status`, `git --no-pager diff`, etc.)
     the same rule applies: use `git -C <worktree> --no-pager
     <subcommand>` rather than `cd <worktree> && git ...`.
   - If the host uses sandbox approvals, preflight the operations
     this loop is likely to need: `git -C <worktree> add` /
     `git -C <worktree> commit`, `git -C <worktree> push origin
     <branch>`, `gh pr comment`, and inline `gh api .../replies`.
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
      `gh-git-heredoc-body-file` skill). Invoke the commit as
      `git -C <worktree> commit -F /tmp/...` so the call matches a
      single allow entry; chained `cd <worktree> && git commit ...`
      will prompt every time.

   e. **Push** the feature branch via
      `git -C <worktree> push origin <branch>`. The allow block
      below pairs `Bash(git push origin feature/*)` with the
      `Bash(git -C * push origin feature/*)` form so either cwd
      shape works without a prompt.

   f. **Post a reply.** Body explains what was done and references
      the commit SHA. Use `gh pr comment <N> --body-file /tmp/...` —
      `--body-file`, not `-b`, to dodge shell quoting.
      For inline review-thread replies, use
      `gh api repos/:owner/:repo/pulls/<N>/comments/<comment_id>/replies
       -f body=@/tmp/reply.md` or the `--in-reply-to` form of `gh
      api`. When host/model identity is known, prefix the body with a
      short tag (e.g. `[claude]`, `[codex]`) — see "Reply convention"
      below. This mirrors the reviewer-side rule in `review-pr-loop`
      so the reader can tell who/what generated each post in a
      multi-round thread.

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

### Auto-approved operations (self-PR workflow)

When the agent is iterating on its own PR (author side, not
reviewing someone else's), the following operations should be on
the user's `permissions.allow` list so the loop does not stall on
permission prompts every iteration. Add these patterns to
`~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(gh pr create:*)",
      "Bash(gh pr edit:*)",
      "Bash(gh pr comment:*)",
      "Bash(gh pr merge:*)",
      "Bash(gh pr ready:*)",
      "Bash(gh issue create:*)",
      "Bash(gh issue comment:*)",
      "Bash(gh issue edit:*)",
      "Bash(gh api repos/*/pulls/*/comments)",
      "Bash(gh api repos/*/pulls/*/comments/*)",
      "Bash(gh api repos/*/pulls/*/comments/*/replies)",
      "Bash(gh api repos/*/issues/*/comments)",
      "Bash(git push origin feature/*)",
      "Bash(git push -u origin feature/*)",
      "Bash(git -C * push origin feature/*)",
      "Bash(git -C * push -u origin feature/*)",
      "Bash(git -C * add:*)",
      "Bash(git -C * commit:*)",
      "Bash(git -C * status)",
      "Bash(git -C * --no-pager log:*)",
      "Bash(git -C * --no-pager diff:*)",
      "Bash(git -C * --no-pager show:*)",
      "Write(/tmp/**)",
      "Edit",
      "Write",
      "MultiEdit"
    ]
  }
}
```

**Why the `-u` push variants.** The first push of a new branch is
typically `git push -u origin feature/<name>` to set upstream
tracking. CC's allow matcher matches the full command verbatim and
does not strip flags, so `Bash(git -C * push origin feature/*)`
does NOT match a `-u` push. Both shapes are listed so the first
push and subsequent follow-up pushes are both auto-allowed.

**Why `Write(/tmp/**)`.** The skill writes commit-body, reply-body,
and PR-body heredocs to `/tmp/<file>` and passes them via
`--body-file` / `git commit -F`. The `Write` tool prompts on every
new file without this entry. `/tmp` is process-local scratch — no
risk of overwriting persistent data.

**The `Edit` / `Write` / `MultiEdit` tradeoff.** Listing the tools
without a path scope allows edits to ANY file from ANY cwd, not
just the worktree. This is the simplest way to silence per-edit
prompts because CC's allow matcher does not accept a path glob for
`Edit` / `Write` (e.g. `Edit(/path/to/repo-wt-*/**)` is not
honored). If you'd rather keep `Edit` prompting outside the loop
and only auto-allow inside the worktree, omit those three entries
and accept one prompt per file edit per iteration.

Rationale: every entry is a *write* the loop does on the agent's
own work — opening the PR, replying to its reviews, pushing
follow-up commits to its feature branch. None of them touch shared
infrastructure or master directly. Static `Bash(...)` entries in
`permissions.allow` short-circuit CC's native permission layer and
its PreToolUse hooks (see
[[claude-code-static-allow-bypasses-hook]]), so once these are in
place the loop runs without prompts **from CC's own permission
matcher**. A separately-installed PreToolUse hook may still
intercept — see "YOLT-specific gotcha" below for the one case we
know of in practice.

**Why the `git -C *` patterns matter.** Claude Code matches each
`Bash(...)` allow entry against the *full* command string. A
compound like `cd <worktree> && git push origin <branch>` starts
with `cd`, so `Bash(git push origin feature/*)` never fires on it
even though the second segment would match on its own. The
host's Bash-tool description is explicit:

> never prepend `cd <current-directory>` to a `git` command —
> the compound triggers a permission prompt

The loop avoids that trap by running every git operation in
single-shot form via `git -C <worktree-path>` instead of
`cd <worktree> && git ...`. The `git -C * <subcommand>` allow
entries above cover that form; the original `Bash(git push origin
feature/*)` is kept for the (rarer) case where the agent really is
in the worktree's cwd.

The same compound-matching rule applies to multi-step chains like
`git -C X commit ... && git -C X push ...`. Issue separate Bash
tool calls instead of chaining with `&&`. CC's allow matcher does
not split compounds for you.

For commands that an allowlist cannot reasonably cover — the most
common one being a quick `cat <file> | python3 -c "<inline>"`
introspection — expect a prompt. The YOLT hook (when installed)
classifies `python3 -c "<inline>"` as `unknown` rather than `safe`
because it cannot statically analyze a single-string script
without parsing it as Python, and the matcher conservatively asks.
Pulling the snippet into a real `.py` file and invoking
`python3 path/to/file.py` makes it analyzable.

What is intentionally NOT on the auto-approve list:

- `git push origin master` / `git push --force` — never auto-allow
  pushing to a default branch.
- `gh pr merge` of someone else's PR — the pattern above covers
  `gh pr merge <N>` of any PR, so use scoped prefixes
  (e.g. `Bash(gh pr merge:*)`) only when you trust the agent to
  judge merge readiness. If not, drop that one entry.
- `gh release create` — release artifacts deserve a human gate.
- `gh repo delete` / `gh repo archive` — irreversible.

### YOLT-specific gotcha: allow patterns ignored on UNSAFE

The above `permissions.allow` block is sufficient on its own only
when no PreToolUse hook is installed, or when the installed hook
defers to CC's allow list. The bundled `voitta-yolt` hook's
`rules/shell.json` classifies `gh pr / issue / api` writes as
`safe` and so agrees with the allowlist, but classifies core git
mutations (`git add`, `git commit`, `git push`) and several `gh`
mutations as UNSAFE — and crucially its `_maybe_allow` (in
`hooks/grammar_classifier.py`) consults the user allow list only
when its own decision is UNKNOWN. UNSAFE decisions ignore the
allow list entirely, so the documented `Bash(...)` entries do NOT
silence those prompts even though they're present. Tracked as
voitta-ai/voitta-yolt#35.

Workarounds today (do at least one if running with YOLT):

1. Override the classification per command in
   `~/.claude/yolt/shell.json` so YOLT sees the loop's writes as
   `safe`. YOLT merges this with the bundled `rules/shell.json`
   at load. Cover BOTH the `gh` writes and the `git` writes, since
   both subcommand families have UNSAFE-classified entries the
   loop relies on:

   ```json
   {
     "commands": {
       "gh": {
         "safe_subcommands": ["pr create", "pr edit", "pr comment",
                              "pr ready", "pr merge",
                              "issue create", "issue comment",
                              "issue edit"]
       },
       "git": {
         "safe_subcommands": ["add", "commit", "push"]
       }
     }
   }
   ```

   Caveat: promoting `git push` to safe here also auto-allows
   `git push origin master` / `git push --force` from YOLT's
   perspective; the `permissions.allow` block above still does NOT
   allow those (no matching pattern), so CC's native matcher
   continues to prompt on them. The two layers compose
   restrictively — both must allow for a command to run silent.

2. Disable the YOLT plugin (`/plugin disable yolt`) for the
   duration of the loop and rely on `permissions.allow` alone.

3. Wait for voitta-ai/voitta-yolt#35 — once `_maybe_allow` is
   relaxed to apply allow patterns on UNSAFE too, the documented
   `Bash(...)` entries will short-circuit YOLT directly and no
   per-command override is needed.

### Skill-activation prompt

The first time the host invokes this skill in a given working
directory, Claude Code shows a one-time confirmation:

```
Use skill "work-on-pr"?
 1. Yes
 2. Yes, and don't ask again for work-on-pr in <cwd>
```

Pick **option 2** so the loop doesn't pause on every restart in
the same project. This is separate from `permissions.allow` —
skill activation is gated independently.

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
- When the host/model identity is known, prefix the reply body with
  a short tag such as `[codex]` or `[claude]` (e.g.
  `[claude] Addressed in 6f23a45.`). If the identity cannot be
  determined, omit the tag rather than guessing. This mirrors the
  reviewer-side rule in [[review-pr-loop]] — once a PR has several
  rounds the tag is the fastest way to scan who-said-what without
  opening every comment.

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

When invoked with an issue reference, additionally expect:

- A new PR whose body contains `Closes #<issue>` (idempotent — the
  agent must not add a duplicate `Closes` line if one already
  exists).
- OR, if a PR for that issue already exists, the PR body edited
  exactly once to append `Closes #<issue>` if it was missing.

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

### Example: issue-mode invocation

User: "/work-on-pr Issue https://github.com/voitta-ai/voitta-yolt/issues/18, start a PR"

Iteration 1:
- Parse arg → issue ref: owner=`voitta-ai`, repo=`voitta-yolt`, N=18.
- Search for an open PR linking issue 18 → none.
- Read issue body. Implement the scoped work in a fresh worktree
  on `feature/issue-18-<slug>` tracking `origin/master`.
- `gh pr create --body-file /tmp/pr.md` where the body contains
  a `## Summary` section and the line `Closes #18`.
- Confirm in the PR's `body` field that `Closes #18` is present
  (idempotency guard: do not add a second `Closes #18` if one is
  already there).
- Enter the watch loop on the just-created PR.

Iteration 2+: identical to the PR-mode flow above.

### Example: existing PR + missing `Closes`

User: "/work-on-pr Issue https://github.com/foo/bar/issues/42"

- Parse arg → issue ref. PR search finds open PR #99 on a branch
  whose name contains `issue-42`.
- `gh pr view 99 --json body` → body lacks any `Closes #42` /
  `Fixes #42` / `Resolves #42`.
- `gh pr edit 99 --body-file /tmp/pr-body.md` with the original
  body + `\n\nCloses #42\n` appended.
- Continue with normal watch loop on PR 99.

## Notes

- **State derivation, not persistence**: each invocation re-derives
  what's new from GitHub timestamps and the bot's own posted
  comments. No local state file is needed.
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
- **Issue closing keywords**: GitHub honors `close[sd]?`, `fix(es|ed)?`,
  `resolve[sd]?` (case-insensitive) followed by `#N` or
  `owner/repo#N`. The detection regex must accept all of these so
  the skill does not append a second `Closes #N` when the user
  already wrote `Fixes #N`. Default to `Closes #N` when adding one,
  since "closes" is the most generic verb.
- **Idempotency**: every issue-linkage step must be safe to re-run.
  The repair appends exactly one `Closes #N` line, only when none
  of the recognized keywords match `#N` in the existing body. The
  same holds for PR-create when an issue ref is supplied — never
  emit a second `Closes #N`.
- **Bumping the version**: when editing this skill, increment
  `version:` in the frontmatter so installed copies can be compared
  against the canonical source.
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

