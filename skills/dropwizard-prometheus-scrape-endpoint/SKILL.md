---
name: dropwizard-prometheus-scrape-endpoint
description: |
  Add a Prometheus scrape endpoint to a JVM service that uses Dropwizard
  Metrics (or any non-Micrometer registry) without migrating its
  instrumentation. Use when: (1) a service reports to CloudWatch/StatsD/JMX
  and you need it in Prometheus, (2) you added a Prometheus bridge and
  `/metrics` returns 200 but with zero application series, (3) a scrape target
  is UP but no application metrics reach the remote store, (4) you must decide
  between "migrate to Micrometer" and "bridge what exists", (5) your PromQL
  cannot find a metric whose Dropwizard name you know. The trap that costs the
  most time: `prometheus-metrics-instrumentation-dropwizard5` and
  `simpleclient_dropwizard` bind to DIFFERENT registry packages
  (`io.dropwizard.metrics5` vs `com.codahale.metrics`), and the wrong one
  COMPILES, REGISTERS, AND EXPORTS NOTHING - no error anywhere. Covers picking
  the bridge by registry package, exporting every registry (not just the
  default), why the handler must not throw, metric-name sanitisation, and
  verifying end-to-end rather than at the endpoint.
author: Claude Code
version: 1.0.0
date: 2026-08-26
source_file: skills/dropwizard-prometheus-scrape-endpoint/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file: `skills/dropwizard-prometheus-scrape-endpoint/SKILL.md`).

# Bridging Dropwizard Metrics to a Prometheus scrape endpoint

## Problem

A JVM service is instrumented with Dropwizard Metrics and ships to CloudWatch,
StatsD, or JMX. You need it in Prometheus. Rewriting every call site to
Micrometer is weeks of work and a behavioural risk. Bridging is an afternoon -
*if* you pick the right bridge and verify the right thing.

## Context / Trigger Conditions

- `curl localhost:PORT/metrics` returns 200 and JVM/process series, but none of
  your application's own metrics.
- The scrape target is UP, the endpoint is fine, and PromQL still finds nothing.
- Two services in the same org need the same treatment and you assume the same
  dependency works for both. It probably does not - see below.

## Solution

### 1. Pick the bridge by the registry's PACKAGE, not the project's name

This is the whole ballgame. Dropwizard Metrics forked its package name at v5:

| Registry import in your code | Bridge artifact |
|---|---|
| `com.codahale.metrics.MetricRegistry` (Dropwizard Metrics 3.x / 4.x) | `io.prometheus:simpleclient_dropwizard` (+ `simpleclient_common`) |
| `io.dropwizard.metrics5.MetricRegistry` (Metrics 5.x) | `io.prometheus:prometheus-metrics-instrumentation-dropwizard5` (+ `prometheus-metrics-exposition-formats`) |

Both artifacts expose a class called `DropwizardExports`. Both compile against
either project. **The mismatched pairing constructs, registers, and exports an
empty set** - no exception, no warning, no log line. You get a healthy 200 with
JVM metrics only, which reads as "the bridge works, my app has no metrics".

Check the import, not the docs:

```bash
grep -rho 'import \(com\.codahale\|io\.dropwizard\)\.metrics5\?\.[A-Za-z]*' src/main/java | sort -u
```

Two services in one org can legitimately need different artifacts. Do not
copy the dependency from the sibling repo without running that grep.

### 2. Export EVERY registry, not just the default one

Apps commonly keep more than one `MetricRegistry` - a main one and a
separate one for health or basic metrics. `DropwizardExports` wraps exactly
one. Register one per registry:

```java
@Provides
@Singleton
public CollectorRegistry collectorRegistry(
        MetricRegistry metricRegistry,
        @Named("basicMetricsRegistry") MetricRegistry basicMetricsRegistry) {
    var registry = new CollectorRegistry();
    registry.register(new DropwizardExports(metricRegistry));
    registry.register(new DropwizardExports(basicMetricsRegistry));
    return registry;
}
```

Enumerate the registries first (`grep -rn 'new MetricRegistry\|MetricRegistry.class'`).
A missed registry is another silent partial export.

### 3. The handler must not throw

The writer does I/O. If the endpoint propagates an `IOException`, a transient
write failure turns the target into a hard-down scrape - and you have built a
monitoring endpoint that takes your monitoring down. Catch it and answer:

```java
try {
    var out = new ByteArrayOutputStream();
    new PrometheusTextFormatWriter(false).write(out, registry.scrape());
    response.sendByteArray(CONTENT_TYPE, out.toByteArray());
} catch (IOException e) {
    log.warn("prometheus scrape failed", e);
    response.status(500);
}
```

Resist `@SneakyThrows` here specifically. A silently dead scrape target is
worse than a logged 500.

### 4. Expect the metric NAME to change

The bridge sanitises Dropwizard names into Prometheus names. Never guess the
result - read it off a live target.

- Dots become underscores: `memcached.gets` -> `memcached_gets`
- Counters gain a suffix: `..._total`
- Hyphens and other illegal characters are replaced: `jvm.thread-states.count`
  -> `jvm_thread_states_count`
- **Whatever the app put in the name is still in the name.** If the code builds
  the metric name from runtime config, the environment and region are baked
  into the Prometheus name too, and dev and prod have different names for the
  same metric. So can a class name applied twice - a worker registering under
  its own name inside a registry already scoped to it produces
  `Worker_Worker_batches_total`.

When the name is environment-dependent, match it as a label rather than
hardcoding it per environment:

```promql
sum by (__name__) (rate({__name__=~".+_batches_failed_total", <selectors>}[5m]))
```

### 5. Verify end-to-end, not at the endpoint

Three checks, in order. The first two passing tells you almost nothing.

```bash
# a) the endpoint answers, and with how many series
kubectl exec -n NS POD -- curl -s localhost:PORT/metrics | grep -c '^[a-z]'

# b) an application series is actually present - not just JVM ones
kubectl exec -n NS POD -- curl -s localhost:PORT/metrics | grep -c '^<your_prefix>'

# c) it reached the remote store - this is the one that matters
#    query the store for the series and confirm a non-zero count
```

Check (b) is the one that catches the wrong-bridge bug: (a) passes with JVM
metrics alone.

### 6. If a service mesh is in the path

Under Istio, `prometheus.io/*` pod annotations are consumed by the sidecar
**injector**, which rewrites them to point at the sidecar's merge port and
path. Your annotated port and path will not appear verbatim on the running
pod - that is correct, not drift. Read the annotations off the live pod
before concluding the scrape config is wrong.

## Verification

Application series count is non-zero at the endpoint AND non-zero in the
remote store, in every environment you deployed to. Record the numbers - a
later regression is only visible against a baseline.

## Example

Two sibling services, same org, same task:

- Service A imported `io.dropwizard.metrics5` -> `dropwizard5` bridge.
  Endpoint: 200, 26,938 bytes, 6.2 ms, 104 series. Remote store went from
  **0** application series to 954.
- Service B imported `com.codahale.metrics` (Dropwizard 4) ->
  `simpleclient_dropwizard` 0.16. Endpoint: 200, 54,493 bytes, 83 ms, 223
  series. 242 series in the store.

Copying A's dependency into B would have produced a green build, a green
deploy, a 200 from the endpoint, and no application metrics at all.

## Notes

- Bridging is the right default when instrumentation is broad and stable.
  Migrate to Micrometer when you also want its meter semantics, not merely a
  different exposition format - and make sibling services make the *same*
  choice, or their dashboards diverge.
- Dropwizard histograms/timers export as quantiles computed per process. They
  are NOT aggregatable across replicas - you cannot average or sum them into a
  fleet quantile. Panels built on them are per-instance by nature; say so on
  the panel.
- A scale-to-zero workload exports nothing when idle. That is correct, and it
  will read as a broken dashboard to everyone who was not told.
- Related: `dashboard-query-preflight` for verifying the panels you then build
  on these metrics.

## References

- Prometheus Java client, Dropwizard bridge:
  https://prometheus.github.io/client_java/instrumentation/dropwizard/
- `simpleclient_dropwizard` (0.16.x, `com.codahale.metrics`):
  https://github.com/prometheus/client_java/tree/0.16.0/simpleclient_dropwizard
- Istio Prometheus annotation merge:
  https://istio.io/latest/docs/ops/integrations/prometheus/

## Related

- `dashboard-query-preflight` — the consumer side. Once the bridge exports
  series, this is how you establish the dashboard reading them is actually
  reading them, rather than rendering an empty rectangle you cannot interpret.
- `metrics-zero-provenance-audit` — why a metrics client returning zero is not
  the same as a system doing nothing, which is the failure this skill's wrong
  bridge produces: it registers, exports, and reports nothing wrong.
