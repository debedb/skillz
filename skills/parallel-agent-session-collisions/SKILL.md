---
name: parallel-agent-session-collisions
description: |
  Avoid duplicating, superseding, or clobbering work done by another agent
  session (or teammate) operating on the same repos concurrently. Use when:
  (1) you are about to open a PR and have not checked whether one already exists
  for the same change, (2) you are about to write a fix for a bug and have not
  checked whether an open PR already fixes it, (3) you are about to run
  `terraform apply` / a deploy from a plan you generated more than a few minutes
  ago, (4) you discover a duplicate PR and are deciding which to close,
  (5) a resource you are about to create already exists but is absent from
  terraform state, (6) a plan's change count shrinks between two runs with no
  action from you, (7) you work in an environment where several coding-agent
  sessions run against one repo, (8) you are about to start a sizeable piece of
  work and other agent sessions are live but you have not asked any of them what
  they are doing. Covers the three collision shapes -- duplicate
  work, pre-existing better work, and state changing under you -- the cheap
  pre-flight check for each, and how to reconcile without losing the better
  version.
author: Claude Code
version: 1.1.0
date: 2026-08-20
---

# Colliding with a parallel agent session

## Problem

When more than one agent session (or a human and an agent) works the same repos,
**anything you observed more than a few minutes ago may be false.** Not stale in
the mild sense — actively wrong, in ways that make you do damage or waste work.

Agents make this worse than humans do. A human opening a PR usually remembers
whether they already opened one. A fresh session has no such memory, moves fast,
and is confident.

## The three shapes

They fail differently and need different checks.

### 1. Duplicate work — two sessions do the same task

Two PRs, same story, functionally identical diffs. Both green, both blocked on
review. Neither author knows about the other.

**Before opening a PR**, check whether one already exists for these files:

```bash
gh pr list --state open --json number,title,headRefName \
  --jq '.[] | "\(.number) \(.title)"'

# narrower: PRs touching a file you are about to change
for n in $(gh pr list --state open --json number --jq '.[].number'); do
  gh pr diff "$n" --name-only 2>/dev/null | grep -q "path/to/file" && echo "#$n touches it"
done
```

### 2. Pre-existing better work — an older PR already fixes it, and fixes it more

The dangerous one. You investigate a bug, find a cause, write a fix — and an
unmerged PR from weeks earlier already covers it **plus a second defect you
missed**. Merging yours would half-fix the problem and make it look resolved,
which is worse than leaving it visibly broken because it stops anyone looking.

**Before writing a fix**, search open PRs and issues for the symptom, not just
the file:

```bash
gh pr list --state open --search "alarm" --json number,title
gh issue list --state open --search "in:title,body <symptom>" --json number,title
```

Age is not evidence of irrelevance. A PR open for weeks is often open because it
is waiting for review, not because it is wrong.

### 3. State changed under you — someone acted between your plan and your act

You generate a plan, spend ten minutes analysing it, then recommend or apply. In
between, another session applied. Your analysis describes a world that no longer
exists.

Tells that this happened:

- A plan's change count **shrinks** between two runs with no action from you.
- A resource exists in the live system but terraform says `will be created` —
  someone created it out of band, and applying will likely fail on a name
  conflict or duplicate it.
- A resource is in state but you never applied it.

**Re-plan immediately before acting.** A plan older than a few minutes is a
claim, not a fact:

```bash
terraform plan -out=/tmp/now.tfplan ...   # then apply THAT file, not a bare apply
terraform apply /tmp/now.tfplan
```

Using `-out` and applying the saved plan is the real fix: it makes terraform
refuse if the world moved, instead of silently applying something else.

## Reconciling a collision — do not just close yours

When you find a duplicate, the instinct is to close one and move on. Diff them
first: the loser almost always contains something the winner lacks.

1. **Diff the two.** `gh pr diff N > a.diff; gh pr diff M > b.diff; diff a.diff b.diff`
2. **Pick the survivor by inbound references, not authorship.** Whichever is
   already cited by issues, tickets, or other PRs — keeping it means those links
   stay valid.
3. **Port the difference before closing.** A ticket reference, a sharper comment,
   a measured verification. Commit it to the survivor.
4. **Close with a comment saying what was kept from each**, so the record shows
   nothing was dropped.
5. **Repoint anything that referenced the loser** — issues that say "fixed by
   #N".

If the *other* PR is better than yours, say so plainly, including what you got
wrong. That is the useful outcome, not the embarrassing one.

## The check that fires before any artifact exists

Every check above reads an **artifact** — an open PR, a branch, a changed plan.
That only works once the other session has produced one. Two sessions that are
both *about to* do the same work have nothing for each other to find, and this is
the most expensive moment to collide: both are about to spend the full cost.

In that window the only detector is the other session itself. If your host
exposes live peer sessions, enumerate them and ask:

```
ListAgents                      # who else is live
SendMessage -> <peer name>      # "are you working on X?"
```

A real case: two sessions independently resumed the same handoff document and
independently chose the same lane — adversarial review of the same four PRs.
Neither had pushed anything, so `gh pr list` was silent for both. The collision
surfaced only because one session asked the other directly, roughly one minute
before four duplicate reviews would have been posted to four PRs.

### Deconflict into lanes, then gate

Splitting the work is not enough; the two lanes usually have an ordering
dependency, and without a gate the second lane races the first.

1. **Name the lanes explicitly** and say which session owns which. Not "you do
   some of it" — one session owns review, the other owns merge; one owns the fix,
   the other owns re-review.
2. **Declare what each side will NOT do.** The valuable half. "I will post
   nothing to those PRs" is what makes the split safe.
3. **Gate the downstream lane.** If merging before review makes the review
   pointless, the merge lane blocks on the review lane *by design*, and says so.
4. **Route the decision through the shared human.** Two agents agreeing a split
   between themselves is not authorization. Surface it and let the human rule.
5. **Preserve the loser's work.** The session standing down usually has real
   output already. Hand it over rather than discarding it — in the case above the
   stood-down session's dry-run findings were folded into the surviving review as
   an independently-produced corroborating pass.

### Treat a peer's claim as evidence, not authority

A peer session can be wrong, and it can also be right in a way that overrides
your own source. Both happened in the case above:

- The peer corrected a claim inherited from a handoff document (that an
  append-only conflict would hit the second *and* third merge). It had actually
  simulated the sequence with `git merge-tree --write-tree` against synthetic
  commits, touching no refs. The simulation beat the document, and the correction
  was accepted.
- The peer was asked whether some agents had survived a restart and answered "no
  evidence either way" — explicitly refusing to let its own empty listing read as
  a negative result, since it had never observed the earlier state.

So: verify a peer's factual claims the way you would your own, and state plainly
which of your claims are verified versus inherited. A peer that distinguishes
"I checked" from "I did not observe that" is worth more than one that answers
every question.

### The asymmetry that bites

Session-to-session addressing is not symmetric with parent-to-teammate
addressing: a peer session and a spawned teammate may need different names for
the *same* target. Briefing an agent with the wrong reply address produces
silence that is indistinguishable from a wedge. The authoritative value is echoed
back on any outbound message you send — read it from the tool result rather than
assuming one name works in both directions.

## Pre-flight, in one place

Before opening a PR, writing a fix, or applying anything:

```bash
git fetch --prune                              # your local view is also stale
gh pr list --state open --limit 50             # is someone already on this?
gh issue list --state open --limit 50
# for infra: re-plan, and apply a saved plan file rather than a bare apply
```

Cheap. A single `gh pr list` costs seconds; a duplicate PR costs a review cycle
from someone else, and a stale apply can cost an outage.

## Verification

You have collided if any of these are true. Check before acting, not after:

- `gh pr list` shows an open PR touching your files.
- A re-plan differs from the plan you were about to act on.
- A resource you intend to create already exists in the live system.
- `git log origin/<default-branch>` moved since you branched.

## Notes

- **This compounds with worktrees.** Sessions in separate worktrees of one repo
  share the remote and the terraform state but not the working tree, so they can
  each look internally consistent while disagreeing.
- **Branch from a freshly fetched default branch, always.** A branch cut from a
  local default that is hours behind produces a plan missing whatever landed
  since — which reads as "my change is small" right up until the merge applies
  someone else's work too.
- **A merge applies more than your diff.** Where CI auto-applies from the default
  branch, merging applies everything the branch describes, including drift you
  did not create. Read the plan, never infer it from your own diff.
- The failure is not carelessness — it is a fresh session's missing memory. The
  remedy is the pre-flight check, not trying harder to remember.
- Related: `github-api-list-endpoint-staleness-fresh-pr` (list endpoints can
  return `[]` for minutes on a fresh PR, so an empty result is not proof of
  absence).
