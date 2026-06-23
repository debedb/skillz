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
version: 1.0.0
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

Run a wave, integrate, then re-plan the next wave from what's left - dependencies
look different once the first wave merges.

## Make every agent a watchable cmux tab
The rule that keeps a multi-agent run legible: **every agent is its own cmux
surface you can watch and type into.** The runtimes differ - see the
[`cmux-agent-tabs`](../cmux-agent-tabs/SKILL.md) skill for the full why - but the
short version:

- **Claude Code** teammates only tab if the root session was launched through the
  `cmux claude-teams` wrapper (it prepends a tmux shim to PATH).
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` alone is a red herring. Diagnose with
  `which tmux` + `echo $TMUX`.
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

## Workflow
1. **Architect conversation.** Architect reads issues + repo, proposes the wave
   plan and squads, you approve.
2. **Launch the surface.** Start the root session via `cmux claude-teams` (or
   `cmux codex-teams`) so agents tab. Verify with `which tmux` / `cmux tree`.
3. **Spin up wave-1 squads.** One dev + reviewer + SDET per active issue, each on
   its own worktree (`multi-phase-feature-pr-worktrees`), each a named tab.
4. **Run the loops.** Developers use `work-on-pr`; reviewers use `review-pr-loop`
   / adversarial review; SDETs exercise the change and file findings.
5. **Productivity engineer watches** and logs confirmation/info/rework stalls.
6. **Integrate + re-plan.** Architect merges landed work, resolves conflicts,
   re-derives the next wave from remaining issues.
7. **Retrospective.** Turn telemetry into concrete process fixes; promote
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
  (`cmux-agent-tabs`).
- **Re-plan between waves.** A parallel set chosen up front goes stale once the
  first PRs merge; dependencies shift.

## Quick reference
| Goal | Command / skill |
|---|---|
| Plan parallel set | architect reads `gh issue list` / `gh issue view`, groups independent vs serialized |
| Claude agents -> tabs | launch via `cmux claude-teams ...` |
| Codex agents -> tabs | `cmux codex-teams ...` / `cmux hooks setup codex` |
| Is Claude bridge active? | `which tmux` (shim) + `TMUX` set |
| Name a squad tab | `cmux tab-action --action rename --tab surface:N --title "<proj>-<issue>-<role>"` |
| Per-issue isolation | `multi-phase-feature-pr-worktrees` |
| Dev loop | `work-on-pr` |
| Review loop | `review-pr-loop` / `/codex:adversarial-review` |
| QA pass | `sdet-explore`, `sdet-email-flow` |
| Promote learnings | `continuous-learning` / claudeception |
