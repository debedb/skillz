---
name: keda-scale-to-zero-fanout-worker
description: |
  Enable KEDA scale-to-zero (minReplicaCount:0) on a TWO-STAGE fan-out SQS
  worker without silently breaking ingestion. Use when: (1) a worker consumes
  an UPSTREAM queue and produces DOWNSTREAM messages onto a second queue that
  it then also drains (main -> range, jobs -> chunks, etc.), (2) the KEDA
  ScaledObject triggers ONLY on the downstream/derived queue (the "meaningful
  backlog") and you want to flip minReplicaCount from >=1 to 0, (3) after
  flipping to 0 the first upstream message just sits and the pod never wakes
  because the downstream queue is still empty so no trigger is active,
  (4) you added an upstream trigger but now the worker over-scales on upstream
  depth / thrashes because upstream drains fast, (5) cold start after an idle
  period is longer than expected and the upstream queue has DelaySeconds set.
  Root cause: at min>=1 an always-on pod drained the upstream, hiding the fact
  that KEDA had no activation signal on it; at min=0 there is no pod to drain
  it and the downstream trigger can't fire from empty. Fix: add ACTIVATION-ONLY
  upstream triggers (large queueLength sentinel so ceil(depth/sentinel)=1 and
  upstream never drives the 1..N ratio, while default activationQueueLength=0
  wakes 0->1 on any message); keep downstream as the scaling signal; account
  for DelaySeconds vs scaleOnDelayed in the cold-start budget; and verify the
  blast radius (operator IRSA queue perms + no idle-triggered alarms) before
  shipping. Sibling of keda-scaleout-accumulate-then-activate (that one is how
  to TEST scale-out; this one is how to DESIGN scale-to-zero for fan-out).
author: Claude Code
version: 1.0.0
date: 2026-07-20
---

# KEDA scale-to-zero for a two-stage fan-out SQS worker

## Problem

A worker has two stages on one process:

1. It consumes an **upstream** queue (one message per unit of work — e.g. a
   file, a job).
2. For each upstream message it **fans out** downstream messages onto a second
   queue (e.g. byte ranges, chunks, sub-tasks) that the *same* worker then
   also drains.

The KEDA `ScaledObject` was written to scale on the **downstream** queue only
— that's the "meaningful backlog," and scaling on the upstream is noisy
because the upstream drains fast (one upstream message is cheap: read
metadata, split, enqueue downstream). This is correct and works fine **as long
as `minReplicaCount >= 1`**: the always-on pod is what drains the upstream and
turns it into downstream depth, so KEDA always has a downstream signal to
scale on.

The trap: flip `minReplicaCount: 0` to save the always-on idle pod, and
ingestion silently breaks. At zero replicas an upstream message arrives while
the downstream queue is **still empty** (nothing has fanned it out yet). No
downstream depth => no active trigger => KEDA never activates => the message
sits until it ages out. Nothing errors; the queue just stops draining.

## Context / Trigger Conditions

- You're changing a queue-driven worker's `ScaledObject` from
  `minReplicaCount: 1` (or any >=1) to `0`.
- The worker is a **fan-out**: it consumes queue A and produces onto queue B
  that it also consumes; the triggers list references only queue B.
- Symptom after flipping to 0: enqueue one upstream message, worker stays at
  0 pods, message visible-count stays 1 and never drains.
- OR you added an upstream trigger with the same `queueLength` target as the
  downstream and now the worker jumps to max on a burst of upstream messages
  (the noise the original design avoided).
- The upstream queue has `DelaySeconds > 0` and the cold start feels ~that
  long plus a poll interval.

## Solution

### 1. Add activation-only triggers on the upstream queue(s)

KEDA's `aws-sqs-queue` scaler has **two independent knobs**:

- `queueLength` — the HPA per-replica target; `desiredReplicas =
  ceil(metric / queueLength)`. Drives 1..N scaling.
- `activationQueueLength` — the 0->1 wake threshold; the scaler is *active*
  when `metric > activationQueueLength`. **Default 0**, so any message
  activates. This is decoupled from `queueLength`.

Exploit the decoupling: give the upstream trigger a **large `queueLength`
sentinel** so it can only ever ask for 1 replica
(`ceil(anyRealisticDepth / sentinel) == 1`), while the default
`activationQueueLength=0` still wakes the worker `0->1` on any single upstream
message. The downstream triggers keep the normal `queueLength` target and
remain the real 1..N scaling signal.

Result:
- upstream message arrives -> upstream trigger active -> KEDA wakes **1** pod
- that pod fans out downstream -> downstream depth -> downstream trigger
  scales 1..N
- everything drains, all triggers idle -> after `cooldownPeriod`, back to 0

```hcl
# terraform / kubernetes_manifest ScaledObject.spec.triggers
triggers = concat(
  # downstream (range/chunk) queues: the scaling signal
  [for k, q in local.queues : {
    type = "aws-sqs-queue"
    metadata = {
      queueURL      = q.downstream.url
      queueLength   = tostring(var.queue_length_target)   # e.g. 100
      awsRegion     = var.region
      identityOwner = "operator"
    }
  }],
  # upstream (main/job) queues: ACTIVATION-ONLY
  [for k, q in local.queues : {
    type = "aws-sqs-queue"
    metadata = {
      queueURL      = q.upstream.url
      queueLength   = "100000"   # sentinel: ceil(depth/100000)=1, never drives 1..N
      awsRegion     = var.region
      identityOwner = "operator"
      # activationQueueLength defaults to 0 -> any message wakes 0->1
    }
  }],
)
```

Multiple triggers: KEDA activates the ScaledObject if **any** trigger is
active, and sets desired replicas to the **max** across triggers. So upstream
supplies the wake, downstream supplies the magnitude. Metric names stay unique
because they're derived per queue URL.

### 2. Budget the cold start against DelaySeconds

If the upstream queue has `DelaySeconds` (e.g. 90s producer delay), a freshly
enqueued message spends that window in `ApproximateNumberOfMessagesDelayed`.
The `aws-sqs-queue` scaler **ignores delayed messages by default**
(`scaleOnDelayed: false`), so activation only fires once the message becomes
visible: cold start ~= `DelaySeconds` + up to one `pollingInterval` + pod
schedule + JVM/app start. For a batch worker that's usually fine — accept it.

If you need to shrink it, set `scaleOnDelayed: "true"` on the **upstream**
triggers: KEDA then counts delayed messages, activates at enqueue time, and
the pod warms **during** the delay window (hiding app startup behind
DelaySeconds). Safe here because upstream messages are transient — there's no
population of perpetually-delayed messages to keep the worker falsely awake.
Leave it off on the downstream triggers.

### 3. Verify the blast radius BEFORE shipping

Two things that scale-to-zero exposes:

- **Operator IRSA queue permissions.** With `identityOwner: operator` the KEDA
  controller's IRSA reads queue attributes. It was already reading the
  downstream queues; confirm it can also read the **upstream** queues
  (`sqs:GetQueueAttributes`). A broad `resources = ["*"]` (or a prefix
  covering both) means no IAM change; a tight per-ARN allow-list means you
  must add the upstream ARNs or the new triggers fail with AccessDenied and
  the worker never wakes.
- **Alarms that fire when idle.** Scaling to 0 makes pod metrics disappear and
  leaves queues briefly non-empty during cold start. Any "0 running pods,"
  queue-**age**, or backlog-**latency** alarm can false-fire. You're safe if
  pod/queue alarms use `treat_missing_data = "ignore"` and there is **no**
  oldest-message-age / latency alarm on the live queues (DLQ-growth and
  delayed-count alarms are unaffected — a cold-start wait never reaches the
  DLQ, and DelaySeconds is applied regardless of consumer count).

### 4. Apply-time gotcha: Server-Side-Apply field-manager conflict

If min/max on the ScaledObject was ever `kubectl patch`ed out-of-band — common
on a dev/test cluster, since the usual scale-out test does exactly
`kubectl patch minReplicaCount=0` — a stale `kubectl-patch` field manager
co-owns those fields. A terraform `kubernetes_manifest` apply that then changes
them (e.g. min `1 -> 0`) fails with:

    Error: There was a field manager conflict when trying to apply the manifest

Diagnose with `kubectl get scaledobject <name> --show-managed-fields -o json`
and look for a non-`Terraform` entry in `.metadata.managedFields[*]` owning
`f:spec.f:minReplicaCount` / `f:maxReplicaCount`.

Fix is per-resource, on the terraform side — it is NOT something the KEDA
install / operator owns, so it cannot live in your cluster/eks module:

    resource "kubernetes_manifest" "scaled_object" {
      field_manager { force_conflicts = true }   # terraform reconciles over manual patches
      manifest = { ... }
    }

`force_conflicts` makes terraform's apply steal ownership of the conflicting
fields back. Tradeoff: an emergency `kubectl patch` to the ScaledObject is then
reverted on the next apply — the correct policy for a terraform-managed
resource. The conflict only exists on clusters someone actually patched (often
just dev), so check `managedFields` per cluster: prod may already have
`Terraform` as sole owner and not strictly need the flag.

## Verification

Scale the worker to 0 (let it idle past `cooldownPeriod`), enqueue a **single**
upstream message, and confirm:

1. `kubectl get hpa keda-hpa-<so-name>` flips the ScaledObject active and the
   Deployment goes 0 -> 1 (within ~`DelaySeconds` + `pollingInterval`).
2. The pod fans out downstream and drains through to the sink.
3. After everything drains, the worker returns to 0 after `cooldownPeriod`.

`terraform validate` the ScaledObject change; the `concat`ed trigger lists must
have identical metadata keys per element or Terraform tuple-type unification
complains.

## Example

Real instance: a worker consuming `*-main` (one message per S3 file) that
splits each file into `*-range` byte-range messages. The ScaledObject
triggered only on the 7 `*-range` queues. Flipping `minReplicaCount` 1->0
would have stranded every `*-main` message. Fix shipped: 7 activation-only
`*-main` triggers (`queueLength = "100000"`), `*-range` unchanged as the
scaling signal, `minReplicaCount` default 1->0. Operator IRSA already had
`sqs:GetQueueAttributes` on `*`; all pod + SQS alarms were
`treat_missing_data = ignore` with no age alarm, so nothing false-fired.
`scaleOnDelayed` left off (upstream had `DelaySeconds=90`; ~2-3 min cold start
accepted for the nightly batch).

## Notes

- Why not just give the upstream trigger the same `queueLength` as downstream?
  Because on a burst of upstream messages that reintroduces exactly the
  scale-up noise the downstream-only design avoided — upstream can peg the
  worker to max before any real (downstream) work exists. The sentinel keeps
  upstream to pure activation.
- `idleReplicaCount` is a *different* KEDA field (idle floor while otherwise
  active). For plain scale-to-zero you only need `minReplicaCount: 0`.
- KEDA owns the 0<->1 transition itself (not the stock HPA, whose floor is 1).
- Graceful shutdown isn't a new risk: KEDA only scales to 0 after
  `cooldownPeriod` of no activity, i.e. queues empty, so there's no in-flight
  work to interrupt at scale-down. (And at-least-once redelivery + idempotent
  writes cover any edge.)
- Sibling skill `keda-scaleout-accumulate-then-activate` is the companion for
  *proving* scale-out deterministically (avoids the flood-a-live-consumer
  race). This skill is the *design* side: making scale-to-zero not strand the
  first-stage queue.

## References

- KEDA AWS SQS Queue scaler (`queueLength`, `activationQueueLength`,
  `scaleOnDelayed`, `scaleOnInFlight`, `identityOwner`):
  https://keda.sh/docs/latest/scalers/aws-sqs-queue/
- KEDA ScaledObject spec (`minReplicaCount`, `idleReplicaCount`,
  `cooldownPeriod`, `pollingInterval`, multiple triggers = OR-activate /
  max-desired): https://keda.sh/docs/latest/reference/scaledobject-spec/
