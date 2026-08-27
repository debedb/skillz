---
name: dashboard-query-preflight
description: |
  Execute every query in a dashboard against its live datasource BEFORE
  shipping it, then triage the empty results instead of guessing. Use when:
  (1) you generated or ported a Grafana / observability dashboard and are
  about to call it done because it renders, (2) panels show "No data" and you
  cannot tell a wrong query from an idle workload, (3) you migrated panels
  between datasources (CloudWatch -> Prometheus, per-host -> per-pod) and the
  metric names or dimensions may not have survived, (4) a reviewer asks "did
  you check it actually works?", (5) terraform said `Apply complete!` and you
  are about to treat that as evidence the dashboard changed. The core trap: a
  panel whose query is wrong and a panel whose workload is idle render
  IDENTICALLY - both are an empty rectangle - so a dashboard that looks fine
  is not evidence of anything. Covers extracting targets from dashboard JSON,
  executing them against the datasource API, the three classes of legitimate
  emptiness (scale-to-zero, low-cadence metrics, env-specific series), the
  `__name__` regex escape hatch when metric names embed environment or
  region, silently truncated search APIs, and reporting coverage as N/N.
author: Claude Code
version: 1.0.0
date: 2026-08-26
source_file: skills/dashboard-query-preflight/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file: `skills/dashboard-query-preflight/SKILL.md`).

# Dashboard query preflight: execute every target, then triage the empties

## Problem

You build or port a dashboard. It renders. Some panels have lines, some are
empty rectangles saying "No data". You ship it.

Half of those empty panels are correct - nothing is running, or the metric
publishes once a day. The other half are typos, wrong dimensions, or metric
names that did not survive the migration. **They look exactly the same.**

The failure is asymmetric and delayed: nobody notices a permanently-broken
panel until the incident where they needed it.

## Context / Trigger Conditions

- You generated a dashboard from code (terraform, jsonnet, a script) rather
  than clicking it together while watching the data come back.
- You ported panels from one datasource to another. Metric names, label
  names, and dimension sets rarely survive intact.
- Your evidence that it works is "the apply succeeded" or "it renders".
- You are writing a handoff and about to claim coverage you did not measure.

## Solution

### 1. Extract every target from the dashboard JSON

Do not read them off the screen - you will miss the ones inside collapsed
rows. Pull them out of the source of truth:

```bash
# every Prometheus/Loki-style expression
jq -r '.. | objects | select(has("expr")) | .expr' dashboard.json

# every CloudWatch-style target (namespace + metric + dimensions)
jq -r '.. | objects | select(has("namespace") and has("metricName"))
       | "\(.namespace) \(.metricName) \(.dimensions // {} | tostring)"' dashboard.json
```

Count them. That count is your denominator - the number you will report.

### 2. Execute each one against the live datasource

Two different questions, and you need both answers:

- **Is the query valid?** A malformed PromQL expression returns an error, not
  an empty result. Errors are unambiguous bugs - fix every one.
- **Does it return data?** This is the ambiguous one. Triage below.

```bash
# Prometheus-compatible: through the Grafana datasource proxy
curl -sG -K "$CURL_CFG" \
  "$GRAFANA/api/datasources/proxy/uid/$DS_UID/api/v1/query" \
  --data-urlencode "query=$EXPR" \
  | jq '{status, err: .error, series: (.data.result | length)}'
```

Loop it. Print one line per target. You want a table you can scan, not a
transcript you have to read.

### 3. Triage the empties - three classes are legitimate

Before calling an empty panel a bug, rule these out. Each one has a distinct
proof:

| Class | Looks like | Prove it with |
|---|---|---|
| **Scaled to zero** | *All* app series gone at once, infra series fine | Check the replica count / autoscaler state. Zero pods = nothing scraped. |
| **Low cadence** | Flat or single-point in a short window | Widen the range. Storage and billing metrics are often daily, not per-minute. |
| **Env-specific** | Empty in one environment, fine in the other | Confirm the workload actually runs there. Dev often has no traffic on a path prod hammers. |

An empty result you cannot place in one of these three is a bug. Chase it.

**Do not "fix" a legitimate empty by loosening the query.** Widening a
selector until something shows up converts a correct panel into a wrong one
that happens to be non-empty.

### 4. When metric names embed environment or region

Some client libraries build the metric name from runtime config, so the same
logical metric is called something different in dev and prod - and a
hardcoded name works in exactly one environment.

Match on the name as a label instead of hardcoding it:

```promql
sum by (__name__) (rate({__name__=~".+_batches_failed_total", <selectors>}[5m]))
```

Legend `{{__name__}}`. This is not a hack to avoid looking up the real name -
look it up first, off a live target. It is the correct fix once you have
*confirmed* the name is environment-dependent.

### 5. Two API traps that fake a green result

- **Silently truncated list endpoints.** A search or list call with a default
  or explicit `limit` returns a *complete-looking* array. If you enumerate
  dashboards, panels, or series that way and the real count exceeds the
  limit, you will confidently verify a subset. Either page it, or query the
  specific items by name and check you got every one you asked for.
- **`Apply complete!` is not `the dashboard changed`.** A provisioning tool
  reports on its own API call, not on the rendered result. Read the object
  back from the target system and diff it.

### 6. Report coverage as N/N, with the empties named

"Verified" is not a result. This is:

```
PromQL      36 / 36 valid, 0 errors, 36 returning data
CloudWatch  10 / 15 returning data
            5 empty: worker at 0 replicas (expected, KEDA scale-to-zero)
```

The named exceptions are the valuable part - they are exactly what stops the
next person raising a false alarm.

## Verification

You are done when, for every target in the JSON, you can say either "returns
data" or "empty because X" where X is one of the three classes and you
checked it. Any target you cannot classify is unfinished work.

## Example

Porting three services' dashboards from CloudWatch to Prometheus:

1. `jq` over the three dashboard JSONs: 162 targets total.
2. Executed all of them through the datasource proxy.
3. Result: 161 valid / 1 error. The error was a metric name that had gained a
   `_total` suffix during export - a real bug, caught before shipping.
4. Fifteen returned no data. Twelve were one service's app rows, all empty
   together - its autoscaler had it at zero replicas. Three were storage
   panels; widening to five days returned five points, confirming a daily
   publication cadence and correct dimensions.
5. Shipped with the coverage table above, and the two legitimate-emptiness
   causes written into the handoff so nobody re-investigates them.

Total cost: one scripted loop. It found one real bug and pre-empted two false
alarms.

## Notes

- The check is cheap and repeatable - make it a script in the repo, not a
  one-off. It is worth re-running after any datasource or naming change.
- This is about panels that never worked. It does not detect a panel that
  worked yesterday and broke today - that is alerting's job.
- Empty-by-design panels deserve a note *on the dashboard*, in a text panel,
  not only in a handoff. The handoff gets lost; the dashboard is where the
  confused person already is.
- Related: auditing what a `0` *means* in a multi-source schema is a
  different problem - see `metrics-zero-provenance-audit`.

## Related

- `metrics-zero-provenance-audit` — the same question one layer down: this
  skill decides whether an empty panel is a broken query or an idle workload;
  that one decides whether a zero the client *did* return can be believed.
- `dropwizard-prometheus-scrape-endpoint` — one concrete cause of the empty
  panel that is not the query: a scrape target that is UP, returns 200, and
  exports no application series at all.
- `terraform-noninteractive-prod-apply` — the other false completion signal in
  this workflow. `Apply complete!` says terraform wrote the resource, not that
  the dashboard shows data; both skills refuse a green line as evidence.
