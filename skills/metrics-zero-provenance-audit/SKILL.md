---
name: metrics-zero-provenance-audit
description: |
  Audit a multi-source metrics / telemetry / scoring client before
  believing its zeros, then split the findings into PR-able and
  issue-only. Use when: (1) a scanner, agent, or SDK collects the same
  named fields from several sources (Claude Code / Codex / Cursor,
  iOS / Android / web, multiple agents into one schema) and your
  report shows a field as `0` or `{}`, (2) a score or grade looks
  wrong and you're about to conclude you're doing something wrong,
  (3) you want to contribute a fix upstream but can't tell which part
  is the client and which part is the closed server, (4) you're
  reviewing a rubric-style tool that grades behavior from named tool
  or event invocations. The core trap: in a shared schema, a `0` far
  more often means "this source never populates this field" than "the
  user didn't do it" — and the two are indistinguishable on the wire.
  Covers the grep-the-incrementer check, the three meanings of zero,
  the proxy-vs-outcome distinction, and the PR-vs-issue split.
author: Claude Code
version: 1.0.0
date: 2026-08-02
source: https://github.com/aiqrank/plugin
source_file: skills/metrics-zero-provenance-audit/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file:
> `skills/metrics-zero-provenance-audit/SKILL.md`).

# Metrics Zero-Provenance Audit

## Problem

A tool scans your local activity, rolls it into a fixed schema, uploads it,
and grades you. Several fields read `0`. The natural reading is "I don't do
that." That reading is usually wrong.

When one schema is shared by several collectors, any field that only one
collector increments serializes as `0` for everyone else. The wire format has
no way to say "not applicable here," so three completely different facts
collapse into the same byte:

1. the user genuinely didn't do it
2. this source never reports the field at all
3. the user did it by a means the collector doesn't recognize

Acting on (1) when the truth is (2) or (3) means changing your behavior to
satisfy a parsing gap.

## Context / Trigger Conditions

- A local scanner / plugin / SDK writes a metrics blob keyed by *source*
  (`claude_code`, `codex`, `cursor`, `ios`, `web`, ...) with a shared field set
- Your report shows `0`, `{}`, or `[]` for something you know you do
- The score is computed **server-side** and the repo contains no weights
- Fields are named for tools (`Agent`, `ExitPlanMode`, `TaskCreate`) rather
  than for outcomes
- You're deciding whether to open a PR or an issue and the boundary is unclear

## Solution

### Step 1 — grep the incrementer before believing any zero

For every zero-valued field, find *which function writes it*. Do not read the
schema, the docs, or the field name. Read the assignment.

```bash
# where is the field declared vs where is it actually incremented
grep -n '"my_field"' scanner.py
grep -n 'my_field' scanner.py

# then map increments to their enclosing function
grep -n "^def " scanner.py    # note the line ranges
```

If every increment sits inside `scan_codex(...)` and you're a Claude Code
user, the zero is provenance, not behavior. This single check reclassified
four fields in the worked example below — a conclusion delivered before doing
it was wrong.

Build a table:

| field | incremented in | reachable from my source? | meaning of my `0` |
|---|---|---|---|
| `file_changes` | `_apply_codex_tool_effects` | no | not-applicable |
| `plan_mode_invocations` | shared path | yes | genuine |

### Step 2 — check the recognizer, not just the counter

A field can be reachable from your source and still read zero because the
*detector* encodes one convention. Look for hardcoded allowlists:

```python
PLAN_ARTIFACT_PARENT_DIRS = {"docs", ".context"}   # your repo uses .claude/
ORCHESTRATION_TOOLS = {"Agent"}                     # you fan out via worktrees
CONTEXT_LEVERAGE_TOOLS = {...9 first-party names...} # you use cron / CI
```

Each set is a claim about the one correct way to work. Same act, different
mechanism, zero credit. That's meaning (3).

### Step 3 — separate proxy from outcome

Ask, per dimension: is the metric counting a **named invocation** or an
**achieved outcome**?

- proxy: `Agent` tool calls
- outcome: concurrent independent workstreams — worktree spawns, concurrent
  sessions, PRs opened

Proxies are cheap to collect and cheap to game, and they punish anyone whose
mechanism differs. Outcomes are mechanism-agnostic. Where the outcome evidence
is *already being collected*, proposing the swap is a concrete ask, not a
philosophical one.

### Step 4 — split PR-able from issue-only, and lead with PRs

Draw the line at the process boundary:

- **collector-side** (parsing, detection, which fields get populated) -> **PR**
- **server-side** (weights, rubric, wire format changes) -> **issue**

Lead with the PRs. Check the maintainer's actual response pattern first:

```bash
gh pr list  --repo OWNER/REPO --state all --limit 10
gh issue list --repo OWNER/REPO --state open
gh issue view N --repo OWNER/REPO --comments   # zero maintainer replies?
```

A maintainer who merges PRs but never answers issues is telling you the format
their attention takes. File the issue anyway — but after the code, and citing
it.

### Step 5 — verify each PR on real data, before and after

Run the scanner against your own history and record a before/after table with
an **unrelated control field** that must not move:

| field | before | after |
|---|---|---|
| `command_diversity` | 0 | 254 |
| `worktree_spawns` (control) | 30 | 30 |

The control is what makes the number credible to someone who can't run your
data.

### Step 6 — state your own PR's kill condition

If a change moves an existing test case from the "should not count" list to
"should count," say so in the PR body, in your own words, along with the
reading under which your PR is *wrong*. Example: *"if the allowlist was
deliberate false-positive defense rather than oversight, this PR is wrong and
I'd rather know that than have it merged."*

Also state when a change does **nothing** for your own score. That removes the
read that you're score-farming, and it costs nothing when it's true.

## Verification

- Every zero you kept in the report survives Step 1 (you found a reachable
  incrementer)
- Each PR has a before/after table with a control field that didn't move
- Test suite delta is stated against the pre-existing baseline, including any
  failure that was already broken on `main` and is not yours
- The issue argues only from things the PRs demonstrated, not from grievance

## Example

Worked end to end against `github.com/aiqrank/plugin`, a Claude Code plugin
that scans local transcripts and uploads metrics to a closed scorer:

1. Report showed `file_changes: 0`, `command_diversity: 0`,
   `reasoning_blocks: 0`, `effort_usage: {}` for a heavy Claude Code user.
2. `grep -n "^def "` + increment line numbers showed all four increments lived
   inside `scan_codex` / `_apply_codex_tool_effects`. Not behavior — provenance.
3. Before proposing anything, verified the raw evidence existed on the Claude
   Code side: `thinking` content blocks and a top-level `effort` key were both
   present in the JSONL (404 occurrences). Grounded, not speculative.
4. Three PRs, each reusing the collector's own existing helpers so both sources
   compute the metric identically. Real-data verification:
   `file_changes` 0 -> 405, `reasoning_blocks` 0 -> 1681,
   `effort_usage` `{}` -> `{'high': 4265}`, `command_diversity` 0 -> 254, with
   `worktree_spawns` flat at 30 as control.
5. A fourth PR replaced a two-entry parent allowlist (`docs`, `.context`) with
   the directory name itself at any depth — and reported that it changed
   nothing for the author's own score.
6. One issue for the residue: publish the rubric and its version, stop
   conflating not-observed with zero, score outcomes where the evidence is
   already collected, and state what the score is for.

Two claims made confidently earlier in that session were wrong and had to be
retracted: MCP tool calls *were* already counted, and `sessions_with_*` are
per-(session, day), not a day-set. Both would have been caught by Step 1
applied to the specific field rather than reasoning from the field name.

## Notes

- **The field name is not evidence.** `sessions_with_orchestration` sounds like
  a session count; confirm the increment site and the rollup aggregation
  before quoting a ratio built on it.
- **Reuse the collector's existing helpers.** If a source-specific helper
  (`_increment_codex_dict`) is actually source-agnostic, reuse it and offer the
  rename in the PR body rather than renaming unilaterally.
- **Privacy is part of the argument.** When adding a field, say exactly what
  leaves the machine: "two integer counters and one normalized short-label
  histogram, the same shape as an existing field. No paths, no content."
- **Reflexivity.** A public per-user score creates pressure to work the way it
  rewards, so the protocol embedded in the weights becomes normative in
  practice. That's the strongest reason to ask for the rubric to be published
  — not that the score was unflattering.
- **Cost is the signal.** Merged PRs with tests and real numbers earn the
  standing to make the harder architectural argument. Blunt critique with no
  code attached is as cheap as politeness with no substance.
