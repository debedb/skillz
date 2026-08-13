---
name: weighted-split-weight-vs-pod-capacity
description: |
  Diagnose a p99 latency regression after moving traffic onto a weighted
  target-group split (canary / blue-green) where the split routes EXACTLY as
  configured but the weight does not match each fleet's pod capacity. Use when:
  (1) blended ALB `TargetResponseTime` p99 jumps 3-10x after a front-door or
  routing change while the app is unchanged, (2) splitting p99 by `TargetGroup`
  shows one side ~5-10x worse than the other, (3) the slow side's app-level
  latency (micrometer `http.server.requests.avg`) is low — single-digit ms —
  while the ALB sees ~100ms, i.e. the time is queueing not work, (4)
  `RequestCountPerTarget` is HIGHER on the fleet with FEWER pods, (5) a canary
  HPA has `minReplicas == maxReplicas` so it cannot absorb its share, (6) a
  canary weight was derived from a Deployment's seed `desired`/`replicas` rather
  than the HPA `max`. Also covers the trap that a weighted split has different
  per-pod economics than one shared target group, and that an ALB-controller
  reconcile lag means `terraform apply` success != weights live.
author: Claude Code
version: 1.0.0
date: 2026-08-13
---

# Weighted split: the weight must track pod capacity, not replica seed

## Problem

You move traffic onto a weighted `forward` across two target groups (canary vs
default, blue vs green). Routing is provably correct — each side gets exactly its
configured share. Yet p99 regresses several-fold.

The cause is that **a weight is a share of *requests*, but latency is decided by
requests *per pod***. If the two fleets have different pod counts, or different
ability to scale, an innocuous-looking weight silently overloads one side.

This is the failure mode *after* you have proven the split routes correctly — see
`verify-alb-weighted-target-group-split` for proving that part.

## Context / trigger conditions

- Blended `AWS/ApplicationELB` `TargetResponseTime` p99 up 3-10x after a routing
  or front-door change; request volume comparable.
- Per-target-group p99 (dimensions `TargetGroup` + `LoadBalancer`) shows one side
  dramatically worse.
- The slow side's **application** latency is fine. An ALB p99 of ~100ms against an
  app-reported avg of ~2ms means the request is waiting to be served, not being
  served slowly.
- `RequestCountPerTarget` is *higher* on the fleet with *fewer* pods.
- The slow fleet's HPA is pinned (`min == max`) or already at its CPU target.
- Both fleets run an identical image — so it is not a bad build.

### The specific config bug that causes it

Deriving the weight from a Deployment's seed replica count:

```hcl
# WRONG -- `desired` only seeds the Deployment; the HPA owns replicas seconds later
canary_pct = canary.desired * 100 / (canary.desired + default.desired)
```

With `canary.desired = 1`, `default.desired = 3` this yields **25%**. But if the
default HPA runs the fleet at 5, each default pod takes 15% while the single canary
pod takes 25% — **1.67x the per-pod load** — and if the canary HPA is `min=max=1`
it can never scale out of it.

## Solution

### Diagnose

1. **Do not compare p99 across wall-clock time — compare at equal load.** p99 on a
   busy service tracks request rate. A dashboard window starting in the overnight
   trough makes the normal morning ramp look like a step change. Pull p99 *and*
   `RequestCount` in the same query and compare like-for-like volumes, ideally
   against the previous front door on a prior day.

2. **Split p99 by target group.** Dimensions `TargetGroup` + `LoadBalancer`. This
   is what isolates "one fleet is slow" from "everything is slow".

3. **Compare ALB `TargetResponseTime` against app-level latency.** If the app
   reports single-digit ms and the ALB reports ~100ms, the gap is queueing in front
   of a saturated pod. That distinction is what rules out a code/image cause.

4. **Compare `RequestCountPerTarget` between the two target groups.** This is the
   money metric: it is per *target*, so it exposes per-pod imbalance directly.
   Compute the expected ratio:

   ```
   canary per-pod   = canary_weight / canary_pods
   default per-pod  = default_weight / default_pods
   ratio            = canary per-pod / default per-pod     # want <= 1.0
   ```

5. **Check the slow fleet's HPA headroom** (`min`, `max`, current, CPU vs target).
   `min == max` means it cannot respond to the load at all.

6. **Rule out image/config drift** — confirm both Deployments run the same image
   and the same resource requests, and diff their env. If only a profile name
   differs, the cause is load.

### Fix

Size the weight off the denominator that holds **when load is high**, which is the
autoscaler's ceiling, not its seed:

```hcl
# RIGHT -- `max` describes the fleet at the moment over-weighting hurts
canary_pct = canary.desired * 100 / (canary.desired + default.max)
```

This errs toward *under*-loading the canary, which costs a marginally less
representative control and nothing else. Over-loading it costs production latency.

If the canary must carry a representative share, the alternative is to let it scale
(raise its HPA `max`) — but then it stops being a single-pod control.

## Verification

1. **Watch the load ratio first, then the latency.** `RequestCountPerTarget` ratio
   moving to the predicted value is the signal the change took effect. Latency
   follows it.

2. **`terraform apply` returning success does NOT mean the weights are live.** When
   the weights live in Ingress annotations, terraform writes the annotation and the
   AWS Load Balancer Controller reconciles it onto the listener rule asynchronously
   — observed lag of several minutes. Measuring immediately after apply reads
   pre-change data and invites the wrong conclusion ("the fix didn't work").
   Confirm the live weights directly before believing any latency reading:

   ```
   aws elbv2 describe-rules --listener-arn <arn> \
     --query 'Rules[].Actions[0].ForwardConfig.TargetGroups'
   ```

3. Expect the slow side's p99 to fall to roughly the healthy side's, and the blended
   p99 to approach it.

## Example

Observed on a production EKS service behind an ALB ingress with a canary profile:

| | canary | default |
|---|---|---|
| pods | 1 (HPA `min=max=1`) | 5 (HPA 3-10) |
| weight | 25% | 75% |
| per-pod share | 25% | 15% |
| ALB p99 | **96 ms** | 17 ms |
| app-level avg | 2.5 ms | 1.0 ms |

Blended p99 sat at ~85ms versus 20-40ms on the previous front door at the same
request volume. Both fleets ran an identical image; only the profile env differed.

Changing the denominator from `default.desired` (3) to `default.max` (10) took the
weight 25% -> 9%. Per-pod ratio went 1.67x -> 0.49x, and canary p99 went **96ms ->
8.4ms** the moment the controller reconciled. Blended p99 landed at ~10ms — better
than the pre-change baseline, because the old shared target group had spread load
evenly across all pods.

## Notes

- **One shared target group and a weighted split are not equivalent.** With both
  fleets registered in a single TG, a `least_outstanding_requests` ALB spreads load
  evenly and the canary's share *is* its pod fraction — self-correcting as either
  fleet scales. Splitting into two weighted TGs decouples share from capacity, and
  nothing in the config makes the resulting imbalance visible. Migrating from the
  former to the latter can introduce this regression with no weight change at all.
- A canary pinned at one replica is a deliberate design (single-variable control).
  That is fine — but its weight must then be sized against the *largest* the other
  fleet gets, or it will saturate at peak.
- `TargetResponseTime` measures ALB->target request send until response headers. It
  includes time queued at the target, which is why it can be ~40x the app's own
  reported processing time.
- If p99 is elevated on *both* target groups, this skill does not apply — look at a
  shared dependency instead.

## References

- [ALB target group weighted routing](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancer-target-groups.html)
- [ALB CloudWatch metrics — `TargetResponseTime`, `RequestCountPerTarget`](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-cloudwatch-metrics.html)
- [AWS Load Balancer Controller — Ingress annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/)
- Related skill: `verify-alb-weighted-target-group-split` (proving the split routes
  proportionally — run that first; this skill is for when it does and latency is
  still wrong).
