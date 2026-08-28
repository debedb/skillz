---
name: alb-per-rule-traffic-attribution
description: |
  Determine which caller sends traffic to which ALB listener rule, and how much,
  before flipping or retiring that rule. Use when: (1) you need to prove a listener
  rule is safe to change and are looking for a CloudWatch metric per rule — there
  isn't one, (2) you grouped ALB access logs by `matched_rule_priority` and the
  numbers look wrong or a single endpoint appears under two priorities, (3) several
  services share one credential so the ALB cannot tell them apart, (4) you must
  identify an unknown HTTP client seen only as a User-Agent in access logs, (5)
  `SHOW PARTITIONS` on an ALB-logs Athena table returns nothing. Core trap:
  `matched_rule_priority` is a POSITION, not an identity — inserting a listener rule
  renumbers every rule below it, so the same priority means different rules on either
  side of that deploy, and a query spanning the change silently mislabels everything.
  Attribute by `request_url` + `user_agent` instead.
author: Claude Code
version: 1.0.0
date: 2026-08-26
---

# Attributing ALB traffic to individual listener rules and callers

## Problem

You are about to change one ALB listener rule — point it at a different target
group, retire it, tighten its conditions — and you need to know what traffic it
actually carries, and from whom.

Two things make this harder than it looks:

1. **CloudWatch cannot answer it.** `AWS/ApplicationELB` publishes only
   `LoadBalancer`, `TargetGroup` and `AvailabilityZone` dimensions. There is **no
   rule-level dimension**, and if every rule forwards to the same target group there
   is no per-rule series at all. This is not a gap you can configure around.
2. **The obvious log field lies across deploys.** ALB access logs carry
   `matched_rule_priority`, which looks like the answer and is a trap (below).

## Context / Trigger Conditions

- "Is this listener rule safe to flip?" and you cannot find a per-rule metric
- Access-log numbers grouped by `matched_rule_priority` that disagree with expectations
- One endpoint appearing under two different priorities in the same result set
- Several applications sharing one API credential, so the ALB rule that selects on
  that credential cannot distinguish them
- An unidentified client in logs, known only by `user_agent`
- `SHOW PARTITIONS <table>` returns zero rows for an ALB-logs table

## Solution

### 1. Confirm access logging is on, and find the bucket

```bash
aws elbv2 describe-load-balancer-attributes --no-cli-pager \
  --load-balancer-arn "$LB_ARN" \
  --query "Attributes[?starts_with(Key,'access_logs')]" --output text
```

You need `access_logs.s3.enabled = true` plus the bucket and prefix. Without this,
per-rule attribution is simply unavailable — there is no retroactive fix.

### 2. Map priorities to rules — and record the date you did it

```bash
aws elbv2 describe-rules --no-cli-pager --listener-arn "$LISTENER_ARN" --output json
```

Render priority alongside path/method/header-name. **Redact header values** — on
auth-by-header setups those are live credentials:

```bash
jq -r '
def paths: [.Conditions[]? | select(.Field=="path-pattern")
            | (.PathPatternConfig.Values? // .Values? // [])[]] | join(",");
def hname: [.Conditions[]? | select(.Field=="http-header")
            | .HttpHeaderConfig.HttpHeaderName? // "?"] | join(",");
def hcount: [.Conditions[]? | select(.Field=="http-header")
            | (.HttpHeaderConfig.Values? // [])[]] | length;
.Rules[] | [.Priority, paths, hname, (hcount|tostring), .Actions[0].Type] | @tsv
' rules.json | sort -t$'\t' -k1,1n | column -t -s$'\t'
```

Guard every accessor with `?` and `//` — the default rule has no conditions and
fixed-response actions have no `ForwardConfig`, and an unguarded path fails the
whole expression with `Cannot iterate over null`.

If rules come from a Terraform `for_each` over a map, they are created in **sorted
key order**, which is usually how priorities are assigned. Verify against the API
rather than assuming.

### 3. ⚠️ The trap: priority is a position, not an identity

Inserting a listener rule **renumbers every rule below it**. A row logged before the
insert and a row logged after, both at priority 6, are different rules.

A query spanning that deploy does not fail — it silently returns confidently wrong
labels. Observed in practice: grouping a 7-day window by `matched_rule_priority`
split one endpoint across priority 6 (193.8M requests) and priority 8 (268.4M),
because two rules had been inserted above it mid-window. The busiest endpoint in the
system was reported as two unrelated rules.

**Only use `matched_rule_priority` inside a window with no rule-layout change**, and
say which window that is when you report the numbers. Get rule-creation dates from
the terraform history (`git log -S'<rule-key>'` on the ingress/rule file).

### 4. Attribute by identity instead

`request_url` and `user_agent` are properties of the request, immune to renumbering:

```sql
SELECT CASE WHEN request_url LIKE '%/api/v1/thing/%'   THEN 'thing'
            WHEN request_url LIKE '%/api/v1/_action%'  THEN 'action'
            ELSE 'other' END AS endpoint,
       user_agent,
       count(*) AS requests,
       count(DISTINCT client_ip) AS ips
FROM <database>.<alb_logs_table>
WHERE date >= '2026/08/24' AND date <= '2026/08/26'
  AND elb_status_code = 200
GROUP BY 1,2 HAVING count(*) > 500 ORDER BY 1,3 DESC
```

Two Athena gotchas on these tables:

- **Partition projection.** ALB-log tables are usually defined with
  `projection.enabled=true` and `projection.date.format=yyyy/MM/dd`. `SHOW
  PARTITIONS` returns **nothing** — that is not an empty table. Filter on the
  partition column directly (`WHERE date >= '2026/08/24'`). Confirm with
  `aws glue get-table ... --query 'Table.Parameters'`.
- **`elb_status_code` may be typed `int`.** `elb_status_code = '200'` then fails with
  `TYPE_MISMATCH: Cannot apply operator: integer = varchar(3)`. Check the column
  types before quoting literals.

### 5. Identify an unknown caller from its User-Agent

Default user agents identify the HTTP library and often the exact version, which is
usually enough to find the repo:

| user agent | library | where to grep |
|---|---|---|
| `okhttp/3.14.9` | OkHttp | `build.gradle` / `pom.xml` for that **exact** version |
| `ReactorNetty/1.0.24` | Spring WebClient (WebFlux) | `spring-boot-starter-webflux` |
| `Java-http-client/21.0.8` | JDK `HttpClient` | often a test harness or CLI, not a service |
| `axios/1.x` | axios | `package.json` |
| **empty / `-`** | **Node's `http`/`https` module sets NO User-Agent by default** | a Node service |

That last row is the one people miss: an absent User-Agent is a positive signal, not
missing data. A blank `user_agent` on a high-volume endpoint is very likely a Node
service using the built-in client.

**Confirm in source before asserting it.** A version match alone is circumstantial —
another service on the same library version is indistinguishable. Look for the
endpoint path and the credential in the candidate repo:

```bash
gh api --hostname <host> "repos/<org>/<repo>/git/trees/<branch>?recursive=1" \
  --jq '.tree[].path' | grep -iE 'build\.gradle|pom\.xml'
gh api --hostname <host> "repos/<org>/<repo>/contents/<file>?ref=<branch>" \
  --jq '.content' | base64 -d | grep -nE 'WebClient|OkHttp|/api/v1/|headers.put'
```

Four independent confirmations is a reasonable bar: library match, exact version,
the endpoint path in source, and the credential name in source.

## Verification

- Re-run the identity-based query and the priority-based query over a window with
  **no** rule change. They should agree. If they disagree, the window spans a
  renumbering.
- Sum the per-user-agent counts against the per-priority total for that same window.
- Cross-check any "this rule is unused" claim against the client IPs: your own
  synthetic probes have a recognisable signature (one IP, tight bursts, a fixed
  interval). Confirm your own egress IP rather than assuming
  (`curl -s https://checkip.amazonaws.com`).

## Example

Goal: prove one caller's rule carries no live traffic before pointing it at a new
gateway.

Result over three days with a stable rule layout, by user agent:

```
okhttp/3.14.9           792,572 req   15 IPs   -> service A
ReactorNetty/1.0.24     278,666 req   30 IPs   -> service B
Java-http-client/21.0.8       4 req    1 IP    -> my own probe script
```

The rule under test saw only the 4 probe requests. But the same query also showed
that service A — nominally the caller that rule was *created for* — was sending
792,572 requests to a **different** rule, because it presented another caller's
credential value. Both facts were true simultaneously: the rule was empty, and its
intended caller was the endpoint's largest consumer.

That distinction only appears when you attribute by identity. Priority alone would
have said "rule is empty" and stopped there.

## Notes

- **The structural argument beats the sample.** If a rule selects on a credential
  value and you can show from configuration which callers hold which value, that is a
  fact about the system, not a sample. Logs corroborate it. A three-day window cannot
  see a weekly or monthly caller; a configuration argument can. Lead with the
  mechanism and cite the logs as confirmation.
- **A "safe because unused" argument has an expiry date.** It holds until a caller
  changes what it sends. Say so where you record it, and re-run before reusing the
  conclusion for a different rule.
- **Never print header condition values.** On token-in-header setups those are live
  credentials. Report header *name* and value *count* only.
- Volumes across rules on one ALB can differ by orders of magnitude. Evidence
  gathered for a low-volume rule is not evidence for a high-volume one — state the
  measured peak (`count(*)/3600` per hour) so a later reader cannot inherit the wrong
  number.
- The same shifting-priority fact bites Terraform from the other side: destroying
  and reprioritising rules in one apply can raise `PriorityInUse`, because the
  plan reuses a number the old rule still holds. Different problem, same reason
  not to treat a priority as an identity.

## References

- [ALB access log entry format](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-access-logs.html) — field list including `matched_rule_priority`
- [ALB CloudWatch metrics and dimensions](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-cloudwatch-metrics.html) — confirms the dimension set is LoadBalancer / TargetGroup / AvailabilityZone only
- [Athena partition projection](https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html) — why `SHOW PARTITIONS` is empty
- [Querying ALB logs in Athena](https://docs.aws.amazon.com/athena/latest/ug/application-load-balancer-logs.html)
- [Node.js HTTP client](https://nodejs.org/api/http.html) — no default `User-Agent` header

## Related

- `metrics-zero-provenance-audit` — the general form of this skill's premise:
  before believing a zero, establish that the metric could have been non-zero.
  Here the zero is structural — there is no per-rule metric to read at all.
- `secretsmanager-prove-no-consumer-before-destroy` — the same proof obligation
  for a different resource. Both answer "is anything still using this?" from
  access evidence rather than from configuration, and both have to rule out
  your own tooling's traffic before the answer means anything.
