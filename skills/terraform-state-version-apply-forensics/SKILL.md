---
name: terraform-state-version-apply-forensics
description: |
  Prove (or disprove) that a terraform change was actually applied to an environment,
  without trusting a PR description or a human's memory. Use when: (1) someone asks
  "did we test/apply this on dev?" and the only evidence is prose in a PR body,
  (2) you need to know WHICH variant of a change was applied and in what order
  (e.g. a stacked PR pair applied separately vs. all at once), (3) live AWS shows
  resources that a teardown was supposed to delete and you must tell "apply never ran"
  apart from "resource was never terraform-managed", (4) you suspect a manual env apply
  was later reverted or overwritten by a CI apply. Method: census the versioned S3
  tfstate objects over time (serial + resource-type counts per version) and cross-check
  with CloudTrail delete/create events. Read-only; safe to run against prod.
author: Claude Code
version: 1.0.0
date: 2026-07-27
---

# Terraform state-version apply forensics

## Problem

A PR body says "applied end-to-end on dev". Maybe it was. Maybe it was applied and then
reverted, or applied in a different order than claimed, or a CI apply on the default
branch put everything back an hour later. `terraform plan` only tells you where the
environment is *now* — not what happened, when, or in what order.

Meanwhile the live cloud API shows resources the change was supposed to delete, and you
can't tell whether the apply silently failed or those resources were never in state.

## Context / Trigger conditions

- "Did we test this on dev?" with no plan/apply log attached.
- Stacked PRs (A, then B on top of A) where the claim is "each applies cleanly on its own"
  and you need to confirm A was applied *alone* at some point.
- Teardown/destroy work where live resources survive: is that a failed destroy or an
  untracked orphan?
- Suspicion of the manual-apply-then-CI-reapply race.

Prerequisite: the S3 backend bucket has **versioning enabled** (standard for TF backends).
Without versioning you get only the current object and this method degrades to CloudTrail
alone.

## Solution

### 1. Locate the state object

Backend config is in the `terraform { backend "s3" {...} }` block plus the per-env
`-backend-config` file (bucket in the block, `key` usually in `env/<env>-backend.tfvars`).

### 2. List state versions over the window of interest

```bash
aws s3api list-object-versions \
  --bucket "$BUCKET" --prefix "$KEY" --profile "$PROFILE" --no-cli-pager \
  --query 'Versions[?LastModified>=`YYYY-MM-DD`].{v:VersionId,t:LastModified}' \
  --output text | sort -k2
```

Each apply writes at least one new version. Bursts of 2-3 versions seconds apart are one
apply (terraform writes state more than once per run) — read the burst, not each line.

### 3. Census each version by resource type

This is the step that makes it evidence rather than a guess. Download each version and
count the resource types you care about:

```bash
aws s3api get-object --bucket "$BUCKET" --key "$KEY" \
  --version-id "$VID" --profile "$PROFILE" --no-cli-pager /tmp/s.json >/dev/null

python3 -c "
import json
s = json.load(open('/tmp/s.json'))
res = s.get('resources', [])
hits = [r['type'] for r in res if any(k in r['type'] for k in ['ecs','autoscaling_group','appmesh','launch_template'])]
print('serial=%-5s total=%-4d matched=%-3d %s' % (s.get('serial'), len(res), len(hits), sorted(set(hits))))
"
```

Swap the keyword list for whatever the change adds or removes. Build a table:

| time | serial | total resources | matched types |
|---|---|---|---|

The **shape of the matched set** identifies *which* variant was applied. Example: a state
holding `ecs_cluster` + `autoscaling_group` + `appmesh_*` but **no** `ecs_service` and no
`ecs_task_definition` is unambiguously "PR A applied alone" — no other config produces
that combination. That is how you confirm a stacked pair was exercised separately.

### 4. Cross-check with CloudTrail

State says what terraform *recorded*. CloudTrail says what AWS *did*, and by whom:

```bash
aws cloudtrail lookup-events --region "$REGION" --no-cli-pager \
  --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteAutoScalingGroup \
  --start-time YYYY-MM-DD \
  --query 'Events[].{t:EventTime,u:Username,r:Resources[0].ResourceName}' --output text
```

Repeat per destructive API (`DeleteAutoScalingGroup`, `DeleteLaunchTemplate`,
`DeleteCapacityProvider`, `DeleteService`, …). Timestamps should line up with the state
bursts from step 2.

### 5. Discriminate orphans from failed destroys

If a live resource looks like it should have been destroyed, check the **exact name**
against the names in the CloudTrail delete events and in the module's naming scheme.

Real signal from this pattern: a live ASG named `<svc>-<region>-dev-asg` survived, while
CloudTrail showed deletes of `<svc>-<region>-dev-default-asg` and `-dev-canary-asg`. The
survivor used an **older naming scheme** — never in current state, so terraform never
touched it. Corroborate with `CreatedTime` (predates the module's current shape) and with
the resource referencing an already-deleted dependency (e.g. an ASG pointing at a launch
template ID that no longer exists).

Also useful: provider `default_tags` (`application` / `environment` / `terraform-repo`)
usually appear on TF-managed resources. Absent tags are a hint — but not proof, since some
resource types (notably `aws_autoscaling_group`) don't receive provider default tags.

## Verification

You have an answer when you can state: at time T the state held N resources including
{types}, at T+1 it held M including {types}, and CloudTrail shows the corresponding API
calls by user U at the same timestamps. If state and CloudTrail disagree, trust CloudTrail
for "what AWS did" and treat the gap as drift or an out-of-band change.

## Notes

- Entirely read-only. Safe against prod.
- Cheap: a state file is typically well under 1 MB; a dozen versions is a few seconds.
- If the answer is "it was applied, then main's CI re-applied and put it back", the state
  table shows it directly as a resource count that goes down and then up again.
- Re-running the actual applies afterwards is still the stronger proof — this method tells
  you whether you *need* to.
- `Resources[0].ResourceName` in CloudTrail is null for some APIs (e.g.
  `DeleteCapacityProvider`); fall back to timestamp + username correlation there.
