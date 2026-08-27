---
name: grafana-cloudwatch-cross-region-dashboards
description: |
  Port or extend Grafana dashboards that query CloudWatch across AWS regions, and fix
  their legends. Use when: (1) a Grafana panel legend renders a literal `{{PodName}}` /
  `{{Dimension}}` instead of the value, (2) you need a second region's series on a
  Grafana dashboard whose CloudWatch datasource has a single defaultRegion, (3) a
  ported CloudWatch widget's SEARCH expression silently returns nothing in Grafana,
  (4) an app publishes region-NAMED custom namespaces (`<svc>-us-west-1-<env>`) and
  cross-region queries against them draw nothing, (5) you want to validate Grafana
  CloudWatch SEARCH / metric-math expressions before shipping dashboards-as-code.
author: Claude Code
version: 1.1.0
date: 2026-08-27
---

# Grafana + CloudWatch cross-region dashboards

## Problem

Porting CloudWatch console dashboards to Grafana (or adding a second region to an
existing Grafana dashboard) fails in quiet, render-time-only ways: legends show literal
`{{Dim}}`, west/second-region panels draw nothing, and SEARCH expressions that "look
right" match zero series — with no error anywhere.

## Context / Trigger Conditions

- Legend shows `{{PodName}} <series-name>` — the braces verbatim, value appended after.
- Dashboard-as-code (Terraform `grafana_dashboard`, JSON provisioning) with CloudWatch
  targets.
- Adding another region's coverage; datasource has `defaultRegion` set.
- Custom namespaces whose NAME embeds the region (`myservice-us-west-1-prod`).

## Solution

1. **Legends: `{{Dim}}` is dead syntax in the CloudWatch datasource.** Grafana's
   CloudWatch datasource never substitutes `{{Dimension}}` (that was the legacy `alias`
   field). Use dynamic labels: `label = "${PROP('Dim.PodName')}"`. Other useful forms:
   `${PROP('MetricName')}`, `${PROP('Region')}`. In Terraform HCL escape the dollar:
   `"$${PROP('Dim.PodName')}"`. (CloudWatch console dashboards themselves use the same
   `${PROP(...)}` syntax — copy it verbatim when porting.)

2. **Cross-region needs NO new datasource and NO IAM change.** Each query target has a
   `region` field that overrides the datasource's `defaultRegion`. CloudWatch IAM
   actions (`cloudwatch:GetMetricData`, `ListMetrics`) are not region-scoped, so the
   role that reads one region reads them all. Mixed-source panels (e.g. east from
   Prometheus, west from CloudWatch) need panel `datasource = {"type": "datasource",
   "uid": "-- Mixed --"}` with per-target datasources — and unique refIds across ALL
   targets in the panel.

3. **Region-named custom namespaces exist only in their own region.** An app that
   publishes to `<svc>-us-west-1-<env>` publishes it in us-west-1 only. A widget in
   region A querying region B's named namespace matches zero series, forever, with no
   error — CloudWatch console dashboards accumulate exactly these dead clauses. Verify
   with `aws cloudwatch list-metrics --region <r> --namespace <ns>` in BOTH regions
   before assuming coverage.

4. **Validate every SEARCH / metric-math expression from the CLI before shipping.**
   Grafana only evaluates them at render time. Run each expression verbatim:

   ```bash
   aws cloudwatch get-metric-data --region us-west-1 \
     --metric-data-queries '[{"Id":"e1","Expression":"<EXPR>","Period":60}]' \
     --start-time <6h-ago> --end-time <now>
   ```

   Two distinct checks: exit-code / `Messages[]` = syntax validity; count of
   `MetricDataResults[].Values` = the query actually matches live data. Test the
   deduplicated set of expression *shapes* (substitute values to a placeholder,
   uniquify), not every instance.

5. **SEARCH has no regex and matches dimension SCHEMAS exactly.**
   - The `{Namespace,dim1,dim2}` brace list must match the series' dimension set
     exactly — a series stored with `{state}` will not match `{ns,fleet,pod,state}`
     and vice versa. Metrics often exist under SEVERAL dimension sets; `list-metrics`
     shows which.
   - Value alternation: `pod=("default" OR "canary")`, and the same works on names:
     `(MetricName="A.A.batches" OR MetricName="B.B.batches")` — build the OR-list in
     code for Dropwizard-style `<Worker>.<Worker>.metric` families.
   - Free terms do token matching (`backlog` matches `...-main.backlog`); `NOT
     uri="/health"` excludes exact values only — enumerate, no regex.
   - Nest math directly to avoid hidden intermediate ids:
     `SUM(REMOVE_EMPTY(SEARCH('...','Maximum',60)))`, `CEIL(SUM(...))`,
     `RATE(SUM(...))/1000` for cumulative-ms gauges.

6. **Know the publisher's semantics before labeling axes.**
   - Micrometer CloudWatchMeterRegistry: counters arrive as counts-per-interval (~rpm,
     NOT rps), timers in **milliseconds** (Prometheus copies are seconds), and a `pod`
     tag may be the deployment PROFILE (e.g. `default`/`canary`), not the pod name —
     "per pod" panels are really per fleet.
   - Dropwizard CloudWatch reporters may publish only ACTIVE metrics (zero counters
     and idle timers vanish) and gauges can stop while counters continue — compare
     last-datapoint timestamps per metric family before declaring a query broken.

## Porting whole console dashboards mechanically

For estates of large console dashboards (100+ widgets), write a converter over the
`get-dashboard` body instead of hand-porting; the widget model is fully mappable:

- **Metric-row continuation:** in a `metrics` array, `"."` repeats the SAME POSITION of
  the previous row; a row starting `"..."` repeats the ENTIRE previous row (only the
  trailing options dict differs — the p50/p90/p99 pattern). Resolve both before reading
  `[namespace, metric, dimName, dimVal, ..., {options}]`.
- **Hidden math chains survive:** emit hidden intermediates as `hide: true` targets and
  KEEP their CloudWatch `id`s — Grafana resolves `SUM(e1)`-style references by target id,
  not refId. Generate refIds separately and unbounded (A..Z, A1..).
- **Auto-flow layout:** widgets without x/y flow left-to-right, wrap at 24 columns, each
  row as tall as its tallest widget. Full-width 1–2-unit-high markdown headings are
  section separators — convert them to Grafana `row` panels.
- **Dual y-axes:** a metric row's `"yAxis": "right"` maps to a `byFrameRefID` override
  with `custom.axisPlacement: "right"` (plus the widget's right-axis min/max). Grafana
  is NOT limited to one scale.
- **Widget types:** `text`→text panel, `view: singleValue`→stat, `alarm` status widgets
  have no Grafana equivalent — emit a text note listing the alarm names.
- **Templatefile escaping order:** dump JSON with a sentinel for the datasource uid,
  escape every `${` to `$${` (protects `${PROP(...)}` labels), THEN replace the sentinel
  with the real `${datasource_uid}` placeholder.
- Commit the converter next to the generated files and mark them generated — regenerate,
  never hand-edit.

## Verification

- `terraform plan` renders the JSON (0 destroy expected for in-place dashboard edits);
  parse `config_json` from `terraform show -json` and assert unique refIds per panel
  and non-overlapping `gridPos`.
- Every unique SEARCH shape returns cleanly from `get-metric-data` (step 4), and the
  production-namespace variants return datapoints > 0 where the workload is live.
- After apply, `GET /api/dashboards/uid/<uid>` and grep the model for `{{` in target
  labels — should be zero.

## Example

Legend fix in Terraform:

```hcl
cw = [{ ns = "ContainerInsights", m = "pod_cpu_utilization", stat = "Maximum",
        label = "$${PROP('Dim.PodName')}",
        region = "us-west-1",
        dims = { ClusterName = "<cluster>", Namespace = "<ns>", PodName = "*" } }]
```

West app series when there is no second-region Prometheus: query the CloudWatch copy
of the app metrics in the west region via a SEARCH target, and say on the panel that
the units differ (rpm / ms) from the Prometheus row.

## Notes

- A CloudWatch datasource's `defaultRegion` is only a default; nothing else pins it.
- `-- Mixed --` panels: keep refIds globally unique in the panel (offset each target
  family by the count of the previous ones when generating).
- Period 60 is usually right for custom-namespace counters (published per minute);
  console dashboards' `10` just over-fetches.

## References

- Grafana CloudWatch datasource docs (dynamic labels / `${PROP(...)}`):
  https://grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/
- CloudWatch metric-math + SEARCH syntax:
  https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/search-expression-syntax.html
