---
name: github-api-list-endpoint-staleness-fresh-pr
description: |
  Diagnose and work around stale `[]` responses from GitHub list endpoints
  on freshly opened PRs / issues, where reviews and comments that
  demonstrably exist do not appear in
  `GET /repos/:owner/:repo/issues/<N>/comments`,
  `GET /repos/:owner/:repo/pulls/<N>/reviews`, or
  `GET /repos/:owner/:repo/pulls/<N>/comments` for several minutes after
  creation. Use when: (1) a watch-loop skill (work-on-pr, review-pr-loop,
  custom poller) polls a freshly opened PR and the list endpoints keep
  returning `[]` even though you (or the user) can see comments in the
  browser, (2) `gh pr view <N> --json reviewDecision` returns the empty
  string while a real review exists, (3) the user pastes a specific
  comment URL like `.../pull/<N>#issuecomment-<id>` and `gh api ...
  /comments/<id>` returns the comment but the corresponding list endpoint
  does not include it, (4) an ESTABLISHED PR (hours/days old) gets a
  brand-new review/comment after you push a fix, and the re-review's
  list endpoint lags the timeline — staleness keys on the freshness of
  the write, NOT the age of the PR, so an old PR awaiting re-review is
  just as exposed. The list endpoints appear to be edge-cached more
  aggressively than single-resource lookups (`/issues/comments/<id>`,
  `/pulls/comments/<id>`, `/pulls/<N>/reviews/<rid>`) and the PR
  *timeline* endpoint (`/issues/<N>/timeline`); those endpoints can
  surface the activity while the list view is still serving `[]`. The
  trap: an empty list response is indistinguishable from "the PR is
  genuinely quiet," so a naive watch loop treats the cache miss as a
  reason to wait longer, and the LGTM / blocking review sits invisible
  until the cache invalidates (observed: 16+ minutes on a single PR).
author: Claude Code
version: 1.1.0
date: 2026-06-11
---

# GitHub API list-endpoint staleness on fresh PRs

## Problem

Watch-loop skills that drive PR iteration (author-side `work-on-pr`,
reviewer-side `review-pr-loop`, or any custom poller) rely on the
GitHub REST list endpoints to decide whether new reviewer activity
exists since the last anchor timestamp:

- `gh api repos/:owner/:repo/pulls/<N>/reviews`
- `gh api repos/:owner/:repo/issues/<N>/comments`
- `gh api repos/:owner/:repo/pulls/<N>/comments` (inline review threads)

Immediately after a PR is opened, these list endpoints can return
`[]` even when a real comment or review already exists. The same
data is available via single-resource lookups (`/issues/comments/<id>`,
`/pulls/comments/<id>`, `/pulls/<N>/reviews/<rid>`) and via the PR
timeline (`/issues/<N>/timeline`). The list view appears to be
served from an edge / proxy cache with a TTL that can lag the
write-through path by many minutes; observed lag in one case was
roughly 16 minutes for a single comment to surface on the list
endpoint after it was already fetchable by ID.

The failure mode is silent. An empty list response looks identical
to "the PR is genuinely quiet." A watch loop with reasonable
pacing (270s for warm, 1800s for quiet) will see three consecutive
`[]` reads, conclude the PR has no feedback, and continue waiting
while a "LGTM" exit signal sits invisible.

## Context / Trigger Conditions

Use this skill when ANY of these symptoms appear during a PR
watch loop or one-off polling task:

1. A freshly opened PR (< ~30 minutes old) shows comments / reviews
   in the browser, but `gh api .../issues/<N>/comments` and/or
   `gh api .../pulls/<N>/reviews` return `[]`.
2. The user pastes a specific comment / review URL and the
   corresponding single-resource lookup
   (`gh api /repos/.../issues/comments/<id>` or
   `gh api /repos/.../pulls/comments/<id>` or
   `gh api /repos/.../pulls/<N>/reviews/<rid>`) returns the
   payload, but the list endpoint that should contain it does not.
3. `gh pr view <N> --json reviewDecision` returns `""` while a
   review actually exists (the high-level command derives that
   field from the same cached list).
4. Two or more back-to-back list polls in a short window (within
   the prompt-cache TTL) both return `[]` against a PR you have
   reason to believe is not idle (recent push, user mentioned a
   reviewer, etc).
5. **An ESTABLISHED PR (hours/days old) with a brand-new review or
   comment.** The staleness keys on the freshness of the *write*,
   not the age of the PR: a review submitted minutes ago can be
   missing from `pulls/<N>/reviews` (or show only the older
   reviews) while the PR timeline already has it. Do not assume an
   old PR is immune — if you pushed a fix and are waiting on a
   re-review, the incoming approval is a *fresh write* and is
   exactly as cache-vulnerable as one on a day-old PR.

Do NOT use this skill when:

- The list endpoint is empty AND nothing recent could have
  produced a write — no push since the last anchor, no reviewer
  pinged, no re-review expected. Age of the PR alone does NOT
  clear it: an old PR awaiting a re-review after your latest push
  is still exposed (trigger #5). The reliable "genuinely quiet"
  signal is that the *timeline* (not just the list) also shows
  nothing newer than your anchor.
- You have not yet established that the comment / review exists
  by some independent means (single-resource lookup, user URL,
  email notification, or a timeline event). Without that ground
  truth you cannot tell cache staleness from a quiet PR.

## Solution

### Detection

1. **Establish ground truth first.** If the user pastes a
   comment URL like `https://github.com/<owner>/<repo>/pull/<N>#issuecomment-<id>`,
   pull the comment by ID:

   ```bash
   gh api repos/<owner>/<repo>/issues/comments/<id>
   ```

   For inline review comments, the URL fragment is
   `#discussion_r<id>`; fetch with:

   ```bash
   gh api repos/<owner>/<repo>/pulls/comments/<id>
   ```

   For full reviews, the URL fragment is `#pullrequestreview-<id>`;
   fetch with:

   ```bash
   gh api repos/<owner>/<repo>/pulls/<N>/reviews/<rid>
   ```

   Single-resource lookups bypass the list-endpoint cache and are
   the authoritative read.

2. **Compare against the list endpoint.** If the list endpoint
   returns `[]` but the single-resource lookup returns a payload
   with `created_at` newer than the anchor timestamp, you are
   looking at the list-cache staleness pattern.

### Workaround during a watch loop

When all three list endpoints return `[]` AND the head commit
`committer.date` is more than ~2 minutes ago AND you have any
reason to suspect activity (user nudge, recent push to a PR with
known reviewers, paging notification), fall back to the **timeline**
endpoint:

```bash
gh api repos/<owner>/<repo>/issues/<N>/timeline \
  --paginate \
  --jq '[.[] | select(.created_at > "<anchor_ts>") |
         {event, created_at, actor: .actor.login,
          url: (.url // .html_url),
          body: (.body // .source.issue.body // null)}]'
```

The timeline merges `commented`, `reviewed`, `merged`, `closed`,
`labeled`, etc. events into one chronological stream. It is less
aggressively cached in practice; events that the list endpoints
will not surface for several minutes typically appear in the
timeline immediately.

For each event newer than anchor:

- `event == "commented"`: timeline entry includes the comment body
  inline.
- `event == "reviewed"`: timeline entry includes `state`
  (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`) and `body`.
- For inline review comments, hydrate via the per-thread URL
  exposed in the event payload, or pull the full inline-comment
  list via the pulls/comments endpoint (which sometimes has a
  shorter cache TTL than the issue-comments list — anecdotal,
  but worth a retry).

### Defensive pacing

- After receiving `[]` from a list endpoint on a PR opened in the
  last ~30 minutes, treat the result as **suspicious**, not
  authoritative. The next poll should re-query and explicitly hit
  the timeline fallback before concluding the PR is idle.
- If the user supplies a comment / review URL mid-loop, parse the
  ID out, fetch by ID, and treat as authoritative regardless of
  what the list endpoint says.
- Do not lengthen the polling interval (270s → 1800s) on the
  first two consecutive `[]` reads of a freshly opened PR; the
  cache may invalidate at any moment, and a 30-minute wait can
  needlessly delay a fast review cycle.

### Reporting to the user

If you suspect this pattern is the reason a comment was missed,
say so directly. The user will otherwise assume the watch loop
itself is broken. Useful diagnostic data to surface:

- The single-resource lookup that succeeded.
- The list-endpoint lookup that returned `[]`.
- The lag (e.g. "comment was 16 minutes old before the list
  endpoint surfaced it").

## Verification

Confirm the staleness pattern (rather than a real bug in the
watch loop) by:

1. `gh api repos/<owner>/<repo>/issues/comments/<id>` returns the
   comment payload (proves it exists).
2. `gh api repos/<owner>/<repo>/issues/<N>/comments` returns `[]`
   (proves the list view is stale).
3. Wait 5-15 minutes and re-run step 2. If the comment now
   appears, the diagnosis is confirmed.

If step 2 returns the comment immediately, this is not the
pattern — investigate the watch loop's filtering logic instead
(wrong anchor jq path, wrong author-filter, etc).

## Example

PR voitta-ai/skillz#32 was opened at `19:50:32Z`. A `LGTM`
comment by `debedb` was posted at `19:57:05Z`.

```
20:05Z poll: gh api repos/voitta-ai/skillz/issues/32/comments
  → []
20:08Z poll: gh api repos/voitta-ai/skillz/issues/32/comments
  → []
(user pastes the comment URL)
20:13Z direct: gh api repos/voitta-ai/skillz/issues/comments/4472326824
  → {"id": 4472326824, "body": "LGTM", "user": {"login":"debedb"}, ...}
20:13Z poll: gh api repos/voitta-ai/skillz/issues/32/comments
  → [{"id": 4472326824, ...}]
```

The list endpoint served `[]` for ~16 minutes after the comment
was already addressable by ID. The watch loop interpreted that
as "PR is quiet" and scheduled a 30-minute wakeup; without the
user's manual nudge it would have continued waiting.

## Notes

- **Root cause is conjecture.** This skill documents the
  observable symptom and a working mitigation; the underlying
  cause is most likely edge-cache TTL on `api.github.com` list
  endpoints, but could also be a write-replication lag on the
  origin or a per-resource quirk after PR creation. The fix
  works regardless of the exact cause: do not trust a fresh
  `[]` from a list endpoint as authoritative.
- **Not all list endpoints are equally affected.** Anecdotal
  pattern: `issues/<N>/comments` is the worst offender;
  `pulls/<N>/reviews` is next; `pulls/<N>/comments` (inline)
  recovers fastest. Verify against your case before assuming the
  same ordering.
- **GraphQL does not help.** `gh api graphql` queries against
  `pullRequest.comments` / `pullRequest.reviews` appear to read
  from the same cached view; switching protocols does not
  mitigate the lag.
- **Single-resource lookups are not free.** Each comment ID
  costs one API call; do not fan out across hundreds of
  hypothesized IDs. Use the timeline as the *list* fallback;
  use single-resource lookups only when an ID is already in hand
  (e.g. from a user-pasted URL or from a previous timeline
  event).
- **Watch-loop-skill integration.** Both `work-on-pr` and
  `review-pr-loop` should run the timeline fallback when any of
  their three list endpoints return `[]` on a PR younger than
  ~30 minutes. Tracked in voitta-ai/skillz#33. Note the
  age gate is a heuristic, not a guarantee — see the next bullet
  for why an *anchor-relative* gate is safer than a PR-age gate.
- **Staleness keys on write-freshness, not PR age (observed
  voitta-yolt#51, 2026-06-11).** PR #51 was ~6 hours old when a
  `[codex] LGTM` approving review was submitted at 04:11:38Z. A
  poll a few minutes later ran
  `gh api pulls/51/reviews --jq '[.[]|select(.submitted_at>ANCHOR)]'`
  and got `0` new — the list endpoint still served only the older
  COMMENTED review — while
  `gh api issues/51/timeline` already carried the new `reviewed`
  event, hydratable via `pulls/51/reviews/<rid>`. The approval
  would have stayed invisible if the loop had trusted the empty
  list because "the PR is old." Lesson: gate the timeline fallback
  on `anchor_ts` age (did anything happen since my last action?),
  NOT on PR-creation age. `work-on-pr` step 4 already does this
  (timeline fallback when `anchor_ts` > ~2 min old, any PR age),
  which is why the LGTM was caught; the older "< 30 min PR" framing
  in the bullet above would have missed it.
- **Don't conflate with jq-path bugs.** The `work-on-pr` skill
  separately had a wrong jq path (`.committer.date` should be
  `.commit.committer.date`) that produced an empty anchor
  timestamp. That bug is distinct from this caching pattern —
  check both when an anchor + new-since-anchor comparison
  silently misbehaves. Tracked in voitta-ai/skillz#34.

## References

- [GitHub REST: List issue comments](https://docs.github.com/en/rest/issues/comments#list-issue-comments)
- [GitHub REST: Get an issue comment](https://docs.github.com/en/rest/issues/comments#get-an-issue-comment)
- [GitHub REST: List reviews for a pull request](https://docs.github.com/en/rest/pulls/reviews#list-reviews-for-a-pull-request)
- [GitHub REST: List review comments on a pull request](https://docs.github.com/en/rest/pulls/comments#list-review-comments-on-a-pull-request)
- [GitHub REST: List timeline events for an issue](https://docs.github.com/en/rest/issues/timeline#list-timeline-events-for-an-issue)
- Related skills: [[work-on-pr]] (author watch loop),
  [[review-pr-loop]] (reviewer watch loop),
  [[gh-git-heredoc-body-file]] (companion gh-CLI gotcha).
