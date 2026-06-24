---
name: agent-team-orchestration
description: |
  Run a team of AI agents against the outstanding issues of a GitHub repo:
  an architect plans what can be parallelized, then each issue gets a small
  squad - a developer, an adversarial reviewer, an SDET/QA, and a productivity
  engineer that watches for process bottlenecks - with every agent a watchable
  cmux tab. Use when: (1) you want to work a whole backlog (not one issue) with
  agents and need a division of labor that an architect derives from the issue
  graph; (2) you want per-issue dev + review + QA roles rather than a single
  do-everything agent; (3) you want each agent visible/steerable as its own
  cmux surface; (4) you want to capture where the run stalled (what needed your
  confirmation, what info was missing) as telemetry for improving the loop.
  Encodes the role set, the parallelization decision, the cmux tab convention,
  and the bottleneck-telemetry pass. cmux is the default interaction surface but
  not required; the same structure works over plain terminals or other
  multiplexers.
author: Claude Code
version: 1.1.0
date: 2026-06-22
source: https://github.com/voitta-ai/skillz
source_file: skills/agent-team-orchestration/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file:
> `skills/agent-team-orchestration/SKILL.md`). Updates go through the repo's
> worktree + PR workflow - open an issue, branch, PR.

# agent-team-orchestration

## Problem
You have a repo with a backlog of open issues and you want a *team* of agents to
work them - not a single agent grinding one issue at a time. Two things make
that more than "spawn N agents":

1. **What can run in parallel is a judgment call.** Some issues touch the same
   files, share a migration, or must land in order. Deciding the parallel set is
   architectural work that should happen *before* any developer agent starts.
2. **One agent per issue is too few.** A lone developer agent marks its own
   homework. Real throughput-with-quality comes from giving each issue a small
   squad with separated concerns (build / attack / verify) plus a meta-role that
   watches the *process*, not the code.

This skill is the orchestration recipe: the roles, who reports to whom, how the
parallel set is chosen, and how to keep every agent watchable and steerable.

## The shape
```
                        ┌─────────────┐
        you  ◄────────► │  architect  │   (plans parallel set; owns the conversation)
                        └──────┬──────┘
            ┌──────────────────┼──────────────────┐
        ┌───┴───┐          ┌───┴───┐          ┌───┴───┐
        │issue A│          │issue B│          │issue C│      (parallel where safe)
        └───┬───┘          └───┬───┘          └───┬───┘
       dev│rev│qa         dev│rev│qa         dev│rev│qa       (a squad per issue)
              └──────── productivity engineer ───────┘        (watches the whole run)
```

## Start with a conversation, not a spawn
The run **begins with the architect**, in a conversation with you - not by
immediately fanning out agents. The architect:
- reads every open issue (`gh issue list`, `gh issue view`) and the repo,
- groups issues into a **parallel set** (independent) vs **serialized chains**
  (shared files / ordering / a migration that must land first),
- proposes the wave plan and the per-issue squad assignments,
- gets your go-ahead before squads start.

Arm the architect with the team's own reusable knowledge: this `skillz`
catalog (https://github.com/voitta-ai/skillz) and any internal playbook repo, so
its plan reuses existing skills (e.g. `work-on-pr`, `review-pr-loop`) instead of
reinventing the loop.

## Step 0: runtime precondition (before any spawn)
Detect the surface **before** the first agent is spawned, not at spawn time. The
architect runs, as a precondition:
```bash
which tmux        # is a tmux/cmux shim on PATH?
echo "$TMUX"      # are we inside a tmux/cmux session?
which cmux        # is cmux installed at all?
```
This is a **once-per-run** check whose result drives an **opinionated default**:

- **If under `cmux claude-teams`** (shim on PATH, `TMUX` set): proceed with
  watchable per-agent tabs - the cmux path below.
- **If not under cmux**: **proceed automatically via the Workflow /
  background-agent surface** - state that you're doing so, don't ask. The role
  structure and wave plan work fine without tabs; you only lose the live-watch
  ergonomics.

Only surface a choice if the user explicitly wants watchable tabs and isn't under
cmux - then they restart the root session under `cmux claude-teams`. Do **not**
add a spawn-time default that steers away from cmux: the precondition has already
decided, opinionatedly, and it decided once.

**Ask each surface/runtime decision at most once.** Once step 0 has resolved the
surface, no later step re-asks it (gate 4 must not re-pose gate 2). Record the
resolved surface and reuse it for the whole run.

## The roles
Each issue in the active wave gets a squad. Roles are deliberately separated so
no agent both writes and blesses the same code.

| Role | Job | Tool / skill it leans on |
|---|---|---|
| **Architect / integrator** | Plans the parallel set, assigns squads, integrates merged work, resolves cross-issue conflicts. One per run. | `gh`, the issue graph; `multi-phase-feature-pr-worktrees` for isolation |
| **Developer** | Implements the issue on its own branch/worktree, opens the PR, addresses review. | `work-on-pr` (author-side PR loop) |
| **Adversarial reviewer** | Tries to *break* the developer's PR, not rubber-stamp it. Separate agent from the developer. | `review-pr-loop`; Codex `/codex:adversarial-review` |
| **SDET / QA** | Exercises the change like a user - crawls routes/forms, watches console+network, files real findings. | `sdet-explore`, `sdet-email-flow` |
| **Productivity engineer** | Meta-role. Watches the whole run for *process* bottlenecks: what needed your confirmation, what info was missing, where agents stalled. Feeds improvements back. | telemetry pass below; `continuous-learning` / claudeception |

Keep the developer and reviewer as **distinct agents**. The value of the
adversarial review collapses if the same context that wrote the code also
reviews it.

## Choosing the parallel set
The architect's core deliverable. Heuristics:
- **Independent** (parallelize): different directories/modules, no shared
  schema, no ordering dependency, separate PRs that won't conflict on merge.
- **Serialize** (one wave after another): issues that edit the same files, a
  migration or interface change others build on, or anything where issue B's
  acceptance depends on A having landed.
- **Cap the wave** to the number of squads you can actually watch and unblock.
  Parallelism you can't supervise just moves the bottleneck onto you.

**Scope/wave default (don't ask when you don't have to).** The default scope is
**all ready/independent issues, parallelized up to the supervision cap.** The
architect picks the wave by that rule and proceeds; it only asks you to narrow
scope when the ready set **exceeds** what the supervisor can watch (then it asks
which subset, once). Don't ask "how many issues?" or "which ones?" when the
independent set already fits under the cap - that's a decision the default
already makes.

Run a wave, integrate, then re-plan the next wave from what's left - dependencies
look different once the first wave merges.

## Idempotency pre-flight (before creating any issue or PR)
**Mandatory.** Before the architect (or any squad) creates an issue or opens a
PR, it first checks for work that already covers the same change:
```bash
gh issue list --state all        # is this already filed?
gh pr list --state all           # is there already a PR for it?
git branch -a                    # is there already a branch/worktree?
```
If existing work is found, **extend or reference it instead of duplicating** -
comment on the existing issue, push to the existing branch, or note the overlap
in the plan. Duplicate issues/PRs/branches are pure friction at integration time.
(Concretely: running `gh issue list` before filing surfaced pre-existing overlap
that would otherwise have become a duplicate.)

**Merge-order default.** Independent PRs **merge on green review** - no human
gate, because they were chosen as independent in the first place. Escalate to you
**only** for genuine ordering or shared-file conflicts (two PRs touch the same
file, or B's acceptance depends on A landing). Don't ask "which merges first?"
when the PRs don't actually interact.

## Cross-repo / cross-lane coordination
When the backlog spans **multiple repos** (one feature whose lanes live in
separate services), the issue graph is not enough - the friction moves to the
*seams between lanes*. The architect maintains a lightweight **coordination
contract**, kept current as waves land:

- **Team-handoff doc** - one scannable page, the architect's + every lane's entry
  point. Per repo: folder, branch/PR, issue(s), current state; plus the goal,
  cost, and the gates below. Link each repo's own detailed handoff rather than
  inlining it.
- **Inter-lane dependency registry** - the concrete outputs one lane hands
  another, named explicitly so a lane never blocks guessing. (e.g. infra lane ->
  consumer lane: the exact cross-cluster DNS the consumer must call; the consumer
  cannot deploy without it.)
- **Gates / freeze-windows** - "do NOT apply X while Y is live", "do NOT merge A
  until B verifies". The multi-repo analogue of the serialized chains above - make
  the ordering explicit so no lane trips another's live state.
- **Per-project handoff files** - each repo keeps its own detailed handoff
  (`.claude/` / `.handoffs/`); the team doc links them. A lane resuming mid-run
  reads its own file; the architect reads the team doc.

Treat the contract as living: re-publish it each time a gate clears or a
dependency is delivered. Most multi-repo stalls trace to a missing entry here -
an unstated address, an unflagged freeze - not to the code.

## Make every agent a watchable cmux tab
The rule that keeps a multi-agent run legible: **every agent is its own cmux
surface you can watch and type into.** This applies when step 0 resolved the
surface to cmux; if it didn't, you're on the background-agent surface and skip
this section. The runtimes differ - see the
[`cmux-agent-tabs`](../cmux-agent-tabs/SKILL.md) skill for the full why - but the
short version:

- **Claude Code** teammates only tab if the root session was launched through the
  `cmux claude-teams` wrapper (it prepends a tmux shim to PATH).
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` alone is a red herring. (This is what
  the step-0 `which tmux` + `echo $TMUX` check detects.)
- **Codex** subagents tab automatically under `cmux codex-teams` /
  `cmux hooks setup codex`.

Name tabs `<project>-<issue>-<role>` so the wall of panes is readable:
```bash
cmux tab-action --action rename --tab surface:N --title "<project>-<issue>-dev"
# ...-rev, ...-qa, ...-arch
cmux tree --all      # list every surface + ref
```
cmux is the default surface because you can watch and steer mid-run, but it is
**not required** - the role structure and wave plan work over plain terminals,
tmux, or any multiplexer. If you skip cmux, just lose the live-watch ergonomics.

## Bottleneck telemetry (the productivity engineer's output)
The reason to instrument the run, not just complete it. Throughout the wave the
productivity engineer records:
- **Confirmation stalls** - every point an agent had to stop for your approval.
  Which were genuinely judgment calls vs. things a better-scoped permission or
  skill could have pre-authorized?
- **Missing-info stalls** - where an agent lacked context (a convention, a
  credential, an acceptance criterion) and had to ask or guess.
- **Rework** - review/QA findings that a sharper initial brief would have
  prevented.

Each recurring stall is a candidate fix: a new skill, a permission allowlist
entry, a sharper issue template, or a default the architect should set next
time. Promote the reusable ones via `continuous-learning` / claudeception into
this catalog; keep the project-specific ones in memory or the project's docs.

## Defaults: don't ask for cheap process decisions
A confirmation stall is only worth it for a real judgment call. **Cheap process
decisions default to *yes*, with an opt-out** the supervisor can flip at any time:
- **Auto-save reusable learnings.** When the productivity engineer spots a
  durable learning, it's saved via claudeception by default - no "should I save
  this?" prompt. Opt out if you don't want catalog churn this run.
- **Auto-continue the SDET pass.** Once a deploy/preview is up, the SDET starts
  its exploration automatically rather than asking permission to begin.

These are reversible, low-cost, and not architectural - so they don't earn a gate.
Reserve your attention for the decisions below.

## Decisions that stay human gates - posed once
Some decisions are genuine architectural judgment and should **not** be
auto-resolved:
- **Design reconciliation** (e.g. which navbar/header/component wins when two
  issues disagree) stays a **human gate**. The architect does not pick for you.

But a real gate must still be **de-duplicated**: once a decision is posed, the
architect **records it and never re-poses the same decision.** The architect
maintains an explicit list of open vs. decided decisions, so an integration-time
question isn't re-asked just because it resurfaces in a later wave (the F10
meta-bug: gate 13 duplicating gate 12). Posing a kept gate once is correct;
posing it twice is friction.

## Workflow
1. **Step-0 runtime precondition.** Architect runs `which tmux` + `echo $TMUX` +
   `which cmux` and resolves the surface (cmux vs. background-agent) **once**,
   opinionatedly - no spawn-time re-ask.
2. **Architect conversation.** Architect reads issues + repo, proposes the wave
   plan and squads. Default scope = all ready/independent issues up to the
   supervision cap; only narrow if it exceeds what you can watch.
3. **Idempotency pre-flight.** Before filing/creating anything, run
   `gh issue list` / `gh pr list` / `git branch -a`; extend existing work rather
   than duplicate.
4. **Launch the surface.** If step 0 resolved to cmux, start the root session via
   `cmux claude-teams` (or `cmux codex-teams`) so agents tab; otherwise proceed on
   the background-agent surface. Verify cmux with `cmux tree`.
5. **Spin up wave-1 squads.** One dev + reviewer + SDET per active issue, each on
   its own worktree (`multi-phase-feature-pr-worktrees`), each a named tab.
6. **Run the loops.** Developers use `work-on-pr`; reviewers use `review-pr-loop`
   / adversarial review; SDETs exercise the change (auto-started once a deploy is
   up) and file findings.
7. **Productivity engineer watches** and logs confirmation/info/rework stalls;
   auto-saves durable learnings by default.
8. **Integrate + re-plan.** Architect merges independent PRs on green review,
   escalating only genuine ordering/shared-file conflicts; tracks open vs.
   decided design gates so none is re-posed; re-derives the next wave.
9. **Retrospective.** Turn telemetry into concrete process fixes; promote
   reusable learnings as skills.

## Outcomes this is built to produce
- The backlog gets worked with build/attack/verify separation per issue.
- You get **telemetry on how the team ran** - where it stalled and why.
- The recurring stalls become durable improvements (skills, permissions,
  templates) so the next run needs less of your intervention.

## Caveats
- **Supervision is the real cap.** More squads than you can watch and unblock
  just relocates the bottleneck to you - size the wave to your attention.
- **Don't merge the dev and review roles** to save agents; that defeats the
  adversarial review.
- **cmux tabbing is asymmetric** across runtimes - if Claude teammates aren't
  tabbing, you almost certainly didn't launch via `cmux claude-teams`
  (`cmux-agent-tabs`). Resolve this at step 0, not at spawn time.
- **Re-plan between waves.** A parallel set chosen up front goes stale once the
  first PRs merge; dependencies shift.
- **Ask each decision at most once.** Surface/runtime, scope, and design gates are
  all resolved once and recorded; re-posing a settled decision is friction, not
  diligence.
- **Keep real gates; drop cheap ones.** Design reconciliation stays a human gate;
  reversible process decisions (save-learning, start-SDET) default to yes.

## Quick reference
| Goal | Command / skill |
|---|---|
| Step-0 surface check (once) | `which tmux` + `echo $TMUX` + `which cmux` |
| Idempotency pre-flight | `gh issue list` / `gh pr list` / `git branch -a` before creating |
| Plan parallel set | architect reads `gh issue list` / `gh issue view`, groups independent vs serialized |
| Default scope | all ready/independent issues up to the supervision cap |
| Default merge order | independent PRs merge on green; escalate only ordering/shared-file conflicts |
| Cheap process decisions | default yes with opt-out (auto-save learnings, auto-continue SDET) |
| Design conflicts | human gate, posed once, recorded - never re-posed |
| Claude agents -> tabs | launch via `cmux claude-teams ...` |
| Codex agents -> tabs | `cmux codex-teams ...` / `cmux hooks setup codex` |
| Is Claude bridge active? | `which tmux` (shim) + `TMUX` set |
| Name a squad tab | `cmux tab-action --action rename --tab surface:N --title "<proj>-<issue>-<role>"` |
| Per-issue isolation | `multi-phase-feature-pr-worktrees` |
| Dev loop | `work-on-pr` |
| Review loop | `review-pr-loop` / `/codex:adversarial-review` |
| QA pass | `sdet-explore`, `sdet-email-flow` |
| Promote learnings | `continuous-learning` / claudeception |
