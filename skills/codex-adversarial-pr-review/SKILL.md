---
name: codex-adversarial-pr-review
description: |
  Run an adversarial Codex review against a GitHub PR and post its findings as a
  single batched PR review (inline comments + summary body), instead of letting
  them die in stdout. Use when: (1) you want `/codex:adversarial-review` output to
  land ON a pull request where the author can act on it, (2) you are the reviewer
  role in an agent-team loop (skillz#87) and need the review to close the loop
  with the developer agent, (3) you want a deterministic, scriptable reviewer
  rather than an LLM hand-posting comments, (4) you need to sweep a whole PR
  backlog and post one review per PR. Encodes the codex-companion `--json`
  call, the finding->diff-line mapping, the GitHub gotchas: inline comments
  are rejected (422) on lines not in the PR diff (out-of-diff findings are rolled
  up into the body), self-review forbids APPROVE/REQUEST_CHANGES (default
  COMMENT), low-confidence findings are demoted to a collapsed section, and a
  `--dry-run` payload is byte-for-byte the POST body so it can be saved,
  edited, and posted later without a second Codex pass — plus the recurring
  false-positive shapes (type-strictness on coerced config, "missing
  attribution" demanding a refactor, stale-branch mass-deletion artifacts) and
  degenerate-output shapes (plan-only "zero findings", quiet background-launch
  failure) to judge before posting.
author: Claude Code
version: 1.3.0
date: 2026-08-29
source: https://github.com/voitta-ai/skillz
source_file: skills/codex-adversarial-pr-review/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file:
> `skills/codex-adversarial-pr-review/SKILL.md`). Updates go through the repo's
> worktree + PR workflow.

# codex-adversarial-pr-review

## Problem

`/codex:adversarial-review` (from the OpenAI Codex CLI plugin) is **review-only
and stdout-only**. It has no GitHub awareness — it diffs your local git state,
runs the model in a read-only sandbox, and prints a rendered result. In an
async, PR-centric loop (notably the agent-team meta-skill,
[skillz#87](https://github.com/voitta-ai/skillz/issues/87), where the reviewer
role *is* `/codex:adversarial-review`) those findings never reach the PR, so the
developer agent and the human can't see or act on them.

This skill bridges that gap deterministically: it calls the same Codex companion
runtime with `--json`, parses the structured findings, maps each to a commentable
diff line, and posts them as one batched GitHub PR review.

## What it does

```
codex-companion.mjs adversarial-review --json --base origin/<base> --scope branch
   -> { verdict, summary, findings[], next_steps[] }
      -> POST /repos/{owner}/{repo}/pulls/{N}/reviews
         { commit_id, event: COMMENT, body, comments: [ {path, line, side: RIGHT, body} ] }
```

The codex plugin is **not modified**. It is vendored under
`~/.claude/plugins/cache/openai-codex/codex/<version>/` and overwritten on
update, so the script locates the companion by globbing for the latest installed
version and never forks it.

## Usage

Run from (or point `--repo-dir` at) a local checkout whose working tree is the
PR head branch:

```bash
node skills/codex-adversarial-pr-review/scripts/codex-adversarial-pr-review.mjs \
  --pr 123 [--repo owner/repo] [--base origin/main] \
  [--min-confidence 0.6] [--event COMMENT] [--focus "tenant isolation"] \
  [--fetch] [--dry-run] [--json]
```

- `--pr` (required) — PR number.
- `--repo` — `owner/repo`; defaults to the current repo via `gh repo view`.
- `--repo-dir` — local checkout of the PR head (default: cwd).
- `--base` — base ref to diff against; defaults to `origin/<PR baseRefName>`.
- `--min-confidence` — inline only findings at/above this confidence (default
  `0.6`); the rest are demoted to a collapsed `<details>` block in the body.
- `--event` — `COMMENT` (default), `REQUEST_CHANGES`, or `APPROVE`.
- `--focus` — extra adversarial focus text passed through to Codex.
- `--fetch` — `git fetch origin <base>` before reviewing.
- `--dry-run` — print the review payload as JSON; post nothing.

Always `--dry-run` first to inspect what would be posted.

**The `--dry-run` output is the POST body, verbatim.** It is the exact
`{commit_id, event, body, comments}` object the script would send. So the
inspect-then-post loop is *save the payload, then post the payload* — never
re-run the script without `--dry-run`, which spends a second Codex pass and can
come back with different findings than the ones you approved:

```bash
node .../codex-adversarial-pr-review.mjs --pr 123 --dry-run > pr-123.json
# ... read it, optionally edit it ...
gh api repos/OWNER/REPO/pulls/123/reviews --method POST --input pr-123.json
```

Editing before posting is plain `jq` — this is how you drop a finding you
verified is wrong while keeping the rest of the review:

```bash
jq '.comments |= map(select((.body | test("return_data")) | not))' \
  pr-123.json > tmp && mv tmp pr-123.json
```

## Batch mode

`scripts/batch-review.sh` sweeps a whole PR backlog and `scripts/post-batch.sh`
posts the results:

```bash
# 1. review everything (dry-run; writes OUT/payloads/pr-N.json)
scripts/batch-review.sh --repo owner/name --repo-dir ~/src/name \
  --out /tmp/review --author some-login --workers 3 --min-confidence 0.75

# 2. see what would go out
scripts/post-batch.sh --repo owner/name --out /tmp/review --dry-run

# 3. post it
scripts/post-batch.sh --repo owner/name --out /tmp/review
```

Budget roughly **90s per PR**, divided by `--workers`.

How it stays out of its own way:

- **Detached worktrees, one per worker.** Each worker checks out the PR head
  *OID* detached, so it never fights "branch is already checked out", creates no
  local branches, and leaves the operator's own checkout alone.
- **One fetch up front** of every head ref, so per-PR checkouts are local.
- **Resumable.** A PR with a non-empty payload is skipped, so a killed run is
  fixed by re-running. An interrupted review leaves a *zero-byte* payload, which
  is why the emptiness check is `-s` / `-size +0` and not mere existence.
- **Round-robin chunking**, not a work queue — the PRs are known up front and
  bash job control is the whole scheduler.

### Judge the findings before you post them

Adversarial framing produces confident, well-written, wrong findings, and
confidence scores do not separate them. In one 41-PR sweep Codex asserted
*twice*, at 0.92, severity `critical`, that a quoted boolean
(`return_data = "true"`) "will fail Terraform plan/apply" — false, HCL coerces
it, and that exact form was already shipping on `main`. A single `grep` of the
tree refuted it. Type-strictness claims about dynamically-coerced config
languages are a recurring false-positive shape.

A second recurring shape: the **"missing observability / attribution"
finding**. Codex asserts a new code path is indistinguishable from existing ones
at the call site, escalates it to `high` with a "Do not ship yet" verdict, and
prescribes a typed-result refactor (a sealed `Result{Success, NotFound, Timeout,
Error, Shed}` threaded through callers). On one such PR — a P1 fix for a
production outage that had recurred twice that morning — the sibling counters providing
exactly that attribution already existed on the same `MeterRegistry`, and the new
one was added by the PR under review. One `grep` of the metric-name constants
file refuted it.

Before accepting an attribution finding, run two checks:

1. **`grep` the metric-name constants file** (`MetricNames`, `Telemetry`,
   `metrics.py`, whatever the project centralizes on) for sibling counters
   registered against the same registry. Codex reasons from the diff and does not
   reliably see them.
2. **Separate fleet-level from per-request attribution.** Fleet-level (a dedicated
   counter, so the rate is dashboard- and alert-visible) is usually already there
   and is what the finding actually demands. Per-request attribution (this
   specific call knows *why* it degraded) is usually the real gap — and is usually
   minor, often one line, not a refactor.

Both shapes share a tell: the remedy is disproportionate to the defect. Weigh a
blocking verdict against what the PR is for. Parking a P1 outage fix to thread a
sealed type through a money path is the wrong trade, and "needs-attention" on a
correct patch reads to the author as a real defect.

A third shape: the **stale-branch mass-change artifact**. In a 61-PR sweep, a
`critical` 0.86 finding read "1,918 deletions — mass removal of tests and
dashboards". The branch was merely old: the "deleted" files landed on the base
branch *after* this PR's merge-base, and the reviewer's narrative showed it had
reasoned over a two-dot `origin/main..HEAD` range. The PR's real (merge-base,
three-dot) diff was 4 files, +109/−4. Before believing any finding about mass
deletions or sweeping changes, measure the PR's actual diff yourself:

```bash
git fetch origin "refs/pull/N/head:refs/remotes/pr/N"
git diff --stat origin/main...refs/remotes/pr/N   # three dots: merge-base diff
```

If that diffstat and the finding disagree, the finding is describing branch
staleness, not the PR — drop it, and consider telling the author to rebase
instead.

The same artifact also arrives one file at a time, and then nothing about it
looks like staleness. On a docs-only PR one commit behind `main`, the sole
finding was `critical` 0.93: "observability safety net removed:
`MeterCatalogCompletenessTest` deleted (141 lines)". The branch never touched
the file — it had been *added* to `main` by the previous PR, minutes earlier.
A single-file deletion reads as a deliberate act, so a diffstat sanity check
does not flag it; list the phantom deletions explicitly instead:

```bash
# files "deleted" only because the branch predates their arrival on main
git diff --name-only --diff-filter=D origin/main..refs/remotes/pr/N     # two dots
git diff --name-only --diff-filter=D origin/main...refs/remotes/pr/N    # three dots
```

Any file in the first list and not the second is a phantom; a finding that
names it is describing `main`, not the PR. On a fast-moving base (an author
merging every few minutes) expect this on *every* unrebased PR in the sweep.

A fourth shape: **"the cited file does not exist in this repo"**. Codex's
sandbox search skips dot-directories and can miss ordinary source files too.
It reported, at 0.82 inline, that a doc's citations were "unverifiable — the
Java file and the `.deploy/` overlays are not in this repo"; `git ls-files`
listed all of them, at the cited lines. Before accepting any
existence/citation finding, check the path yourself:

```bash
git ls-files -- src/main/java/**/AnalyticsProperties.java .deploy/  # empty ⇒ truly absent
```

A non-empty listing refutes the finding outright — it is a tooling gap, not a
doc error.

Spot-check at least every `critical` finding against the existing tree before
posting; drop the bad ones with the `jq` filter above. Posting a wrong critical
costs the author more time than the review saves.

## Why it works the way it does (the gotchas)

1. **Out-of-diff findings.** GitHub returns **422** for an inline comment on a
   line not in the PR diff. Adversarial review can flag context lines outside the
   diff (especially in Codex's "self-collect" mode on large diffs). The script
   computes the commentable RIGHT-side line set by parsing `gh pr diff`, posts
   in-diff findings inline, and **rolls up out-of-diff findings into the review
   body** so none are lost.
2. **Target alignment.** The review must diff the same range GitHub shows, so it
   runs `--base origin/<baseRefName> --scope branch` (i.e. `merge-base...HEAD`).
   A mismatched base makes line numbers not line up with the diff.
3. **Self-review limits.** If the posting identity is the PR author (the norm
   when an agent opened the PR), GitHub forbids `APPROVE`/`REQUEST_CHANGES` —
   only `COMMENT` works. Default is `COMMENT`; the verdict is surfaced in the
   body. Use a dedicated reviewer-bot token to upgrade the event.
4. **Noise control.** Adversarial framing is deliberately aggressive; without a
   confidence floor the diff gets spammed. Sub-threshold findings go to a
   collapsed section instead of inline.
5. **The companion's own parse of the model output is flaky, and it fails
   *quietly*.** Codex intermittently emits its JSON object followed by trailing
   prose. The companion then reports

   ```
   Codex review returned no findings:
     Unexpected non-whitespace character after JSON at position 183 (line 1 column 184)
   ```

   and leaves `result` empty. Read that message carefully: it is **not** the
   wrapper failing to parse the companion, and it is **not** "Codex found
   nothing" — a complete review was produced and discarded. Observed twice in a
   row on one PR and not at all on the next run of the same diff, so re-running
   is a coin flip rather than a fix.

   The companion does keep the model's untouched output in `rawOutput`, so the
   script now salvages it: decode the first complete JSON value and ignore the
   trailing text (`salvageResult()`). It prints a `note: recovered N finding(s)`
   line to stderr when it does, and still returns null — so the caller still
   fails loudly — when nothing usable is there.

6. **Re-run idempotency.** Re-running on an updated PR posts a fresh review
   (GitHub threads them). The body carries a `<!-- codex-adversarial-review
   sha=<headOid> -->` marker so prior runs are identifiable; dismissing/minimizing
   old reviews is intentionally out of scope for v1.

7. **A saved payload does not expire, but its anchor does.** The payload pins
   `commit_id` to the head SHA at review time. If the author pushes before you
   post, GitHub rejects the stale commit — re-review that PR rather than forcing
   the old payload through.

8. **A "clean pass" can be a degenerate run: zero findings with a body that is
   the model's PLAN.** A run can exit successfully with an empty `findings[]`
   and a summary/body that reads like intent, not conclusion — "Kicking off a
   targeted diff read of ... Next steps: inspect ...". That is not "no issues
   found"; it is a review that never happened. Treat *empty findings + body in
   planning language* as a failed run and re-run it. One diff re-run three
   times produced three different outcomes (plan-only, parse failure, real
   findings), so a single run's shape is evidence about the run, not the diff.
   Grep payloads for planning tells before trusting a batch's "clean" set:

   ```bash
   jq -r 'select((.comments|length)==0) | .body' OUT/payloads/pr-*.json \
     | grep -nE "Kicking off|Next steps:|I will|Plan:" && echo "degenerate run(s) present"
   ```

9. **Backgrounding the wrapper can fail with no output at all.** Launching the
   `.mjs` as a background job quiet-failed twice — no payload file, no error,
   nothing in the log — and the identical command run in the foreground worked
   first try. Run single-PR reviews in the **foreground** (budget ~90s, large
   diffs several minutes). If you must background (the batch scripts do,
   under their own job control), treat a missing or zero-byte payload with a
   silent log as a launch failure to retry, never as a clean empty review —
   the same `-s` rule batch mode's resume logic applies.

## Requirements

- `node`, `git`, `jq`, and an authenticated `gh`. (`gh` has no `--no-pager`
  flag; that convention is git-only.)
- The OpenAI Codex CLI plugin installed (provides the companion runtime), and
  `codex` logged in (`/codex:setup`).

## Related

- [skillz#87](https://github.com/voitta-ai/skillz/issues/87) — agent-team
  meta-skill; this is the reviewer role's posting mechanism.
- `agent-team-orchestration` — the team skill that consumes this.
- `review-pr-loop` — reviewer-side iteration loop (Claude/Codex hosted).
