# Skill inclusion candidates

Decision record for which local `~/.claude/skills/` entries justify
inclusion in this public catalog. Spun out of
[#46](https://github.com/voitta-ai/skillz/issues/46) (umbrella, closed).
This document defines the bar and the shortlist; it adds no skills.
Execution is split across two follow-up issues:

- [#57](https://github.com/voitta-ai/skillz/issues/57) — the
  dangling-wikilink dependency skills (Tier 0 below).
- [#58](https://github.com/voitta-ai/skillz/issues/58) — the rest of
  the general-purpose shortlist (Tiers 1-3 below).

The survey was taken against a 245-skill local library. Counts that
depend on judgement (the excluded bulk, the deferred set) are
approximate and marked as such; the candidate tiers are enumerated in
full because they are the actionable part.

## Inclusion bar

A skill **qualifies** for this catalog when all of the following hold:

1. **Host/tool-agnostic.** It is about a tool anyone can run — git,
   `gh`, GitHub, Claude Code, Codex, bash, a public language/runtime —
   not about one employer's systems.
2. **Reusable outside one org.** A stranger with the same tool hits the
   same problem. No dependence on private infrastructure to be useful.
3. **No internal references.** It names no ZoomInfo / Clickagy / Voitta
   internal account, repo, service, cluster, dashboard, or process.

A skill is **disqualified** when any of the following hold:

- It references internal accounts, repos, services, or data
  (`zoominfo-*`, `clickagy-*`, `kpv2-*`, internal AWS account IDs,
  named internal clusters/dashboards, internal Jira projects).
- Its value is a runbook for a specific internal system, even if the
  underlying tool is public.
- It is operational/process glue for one team (deploy announcements,
  daily logs, on-call).

A skill is **deferred** (generic but out of scope for v1) when it is
tool-agnostic and has no internal references, but is a narrow
single-language / single-cloud-primitive gotcha whose audience is much
smaller than the catalog's PR-workflow / agent-host core. These are
honest candidates for a later, broader pass — kept out now to avoid
scope creep, not because they fail the bar.

## Survey summary

| Bucket | Count (approx) | Disposition |
|---|---|---|
| Already in catalog | 4 | done |
| Tier 0 — dangling-wikilink deps | 3 | add now (#57) |
| Tier 1 — git / gh / GitHub workflow | 25 | strongly recommend (#58) |
| Tier 2 — Claude Code / Codex host mechanics | 13 (+4 borderline) | recommend (#58) |
| Tier 3 — misc general dev | 6 | optional (#58) |
| Deferred — generic cloud / language gotchas | ~45 | keep out of v1 |
| Excluded — internal / proprietary | ~145 | never |

Already in catalog (present both locally and in `skills/`):
`work-on-pr`, `review-pr-loop`, `continuous-learning`, `cmux-search`.

## Tier 0 — dangling-wikilink dependencies (add now, #57)

The shipped `work-on-pr` / `review-pr-loop` skills `[[wikilink]]` to
these, but they are absent from the repo, so the links dangle for
anyone who installs the catalog. Verified with
`grep -rohE '\[\[[a-z0-9-]+\]\]' skills/`:

| Skill | Why |
|---|---|
| `gh-git-heredoc-body-file` | body-file heredoc pattern, linked from both PR-loop skills |
| `claude-code-static-allow-bypasses-hook` | linked from `work-on-pr` permissions section |
| `python-ast-static-analyzer-scoping` | linked from `work-on-pr` as a worked review-cycle example |

Concepts that appear in PROSE but are **not** `[[wikilink]]`
dependencies — the #33 list-endpoint cache quirk, `Closes #N` closing
keywords, the `gh api -F` vs `-f` body-file trap — map to local skills
(`github-api-list-endpoint-staleness-fresh-pr`,
`github-closing-keywords-default-branch-only`,
`gh-api-f-vs-F-body-file`). Those are general-shortlist candidates
(Tier 1), not Tier 0. (`work-on-pr` line ~934 also mentions a
*proposed* `gh-api-list-cache-staleness` extract that has not been
authored — a forward reference, not a dependency.)

## Tier 1 — git / gh / GitHub workflow (strongly recommend, #58)

Coheres directly with the existing PR-loop theme; a contributor using
`work-on-pr` / `review-pr-loop` is the exact audience.

git:

- `gh-git-heredoc-body-file` *(also Tier 0)*
- `git-add-u-rename-pitfall`
- `git-branch-cleanup-script-races`
- `git-graft-worktree-onto-remote`
- `git-split-subfeature-out-of-long-lived-branch`
- `git-squash-merge-branch-hygiene`
- `multi-phase-feature-pr-worktrees`
- `gist-to-repo-migration`

gh / GitHub:

- `gh-api-f-vs-F-body-file`
- `gh-api-jq-no-arg`
- `gh-fork-issues-disabled`
- `gh-pr-graphql-401-rest-fallback`
- `gh-pr-merge-delete-branch-closes-dependent-pr`
- `gh-workflow-run-matching`
- `gha-dispatch-schedule-needs-default-branch`
- `github-actions-setup-protoc-rate-limit`
- `github-api-list-endpoint-staleness-fresh-pr`
- `github-closing-keywords-default-branch-only`
- `github-enterprise-merge-unblock`
- `github-enterprise-pr-review-api`
- `github-private-repo-readme-image-rendering`
- `github-repo-squash-only-hardening`
- `github-ruleset-integration-bypass-needs-org`
- `github-skip-ci-token-suppresses-pr-and-merge`
- `github-undo-premature-merge-via-revert-and-reopen`
- `github-user-attachments-curl-auth`

## Tier 2 — Claude Code / Codex host mechanics (recommend, #58)

This is a Claude Code / Codex skills catalog; host-mechanics skills are
on-theme for its own users.

- `claude-code-claudemd-symlink-write-refused`
- `claude-code-codex-plugin-parity`
- `claude-code-custom-slash-command`
- `claude-code-lsp-for-piebald-unsupported-langs`
- `claude-code-mcp-config`
- `claude-code-piebald-lsp-binary-on-path`
- `claude-code-plugin-from-existing-repo`
- `claude-code-plugin-python-bootstrap`
- `claude-code-plugin-update-flow`
- `claude-code-static-allow-bypasses-hook` *(also Tier 0)*
- `claude-json-mcp-migration-slice`
- `claudeception` (Claude-side continuous learning; pairs with the
  already-shipped Codex-side `continuous-learning`)
- `codex-review-focus`
- `codex-review-to-pr-comments`

Borderline (include only after a content check; niche env or
third-party-provider specifics):

- `claude-code-el-emacs-macos-setup` (emacs + macOS niche)
- `claude-code-skills-gist-installer` (likely obsolete after the
  gist -> repo migration; confirm before adding)
- `codex-cli-oauth-requesty-403` (Requesty provider specific)
- `codex-cli-requesty-wire-api` (Requesty provider specific)

## Tier 3 — misc general dev (optional, #58)

- `macos-bash-3.2-compat`
- `project-documentation`
- `sdkman-use-vs-java-home`
- `emacs-batch-package-verify-pitfalls`
- `extract-token-from-har`
- `python-symtable-no-col-offset-pairing` (pairs with the Tier 0
  `python-ast-static-analyzer-scoping`)

## Deferred — generic cloud / language gotchas (keep out of v1)

Tool-agnostic with no internal references, but narrow single-language /
single-cloud-primitive gotchas. Honest candidates for a later broad
pass; out of scope now. Approximate set (~45):

- Terraform (generic): `terraform-foreach-to-count-state-destroy`,
  `terraform-killed-apply-orphans-already-exists`,
  `terraform-removed-block-phantom-state-cleanup`,
  `terraform-output-warning-stdout-leak`,
  `terraform-s3-bucket-acl-ownership-enforced-default`,
  `terraform-kubernetes-manifest-crd-plan-time`,
  `terraform-k8s-ingress-wait-for-load-balancer`,
  `terraform-provider-asymmetric-read-write-field-strip`
- k8s / container (generic): `karpenter-drift-vs-expireafter`,
  `k8s-native-sidecars-as-init-containers`,
  `kubelet-imagepullbackoff-force-delete-to-skip-timer`,
  `docker-buildx-arm64-amd64-eks-cached-tag`
- GCP (generic): `gcp-pubsub-dlq-missing-iam`
- load / test: `k6-http-req-failed-counts-404`,
  `gatling-load-test-capacity-finding`
- JVM / build: `okhttp-connection-pool-keepalive-tuning`,
  `mockito-spy-dead-stub-trap`, `protobuf-null-string-npe`,
  `mmdb-java-integer-type-compatibility`,
  `micrometer-p99-stuck-bucket-artifact`,
  `gradle-daemon-jdk-switch-nosource`,
  `gradle-jacoco-integrationtest-graph-leak`,
  `gradle-major-bump-plugin-empirical-test`,
  `madrapps-jacoco-report-delta-interpretation`
- Micronaut / Spring / Lombok (framework gotchas):
  `micronaut-virtual-threads-migration`,
  `micronaut-config-binding-regression-test`,
  `micronaut-nested-configurationproperties`,
  `micronaut-each-property-nested-map`,
  `micronaut-serde-jackson-no-jackson-bean`,
  `micronaut-lombok-processor-order`, `lombok-named-micronaut-di`,
  `spring-configurationproperties-duplicate-bean`
- data / runtime: `sqlite-disk-io-error-docker-bind-mount`,
  `sqlalchemy-pragma-event-blocks-host-journal-mode`,
  `qdrant-field-unset-filter`, `qdrant-scroll-vs-query`,
  `temporal-sleep-loop-vs-stuck`, `temporal-workflow-state-verification`,
  `temporal-cloud-codec-bypass`
- knowledge-graph product: `graphify`,
  `graphify-tf-detect-gemini-degenerate`
- unclear / needs content read before classifying:
  `content-hash-format-version-salt`, `pattern-veto-set-exclude-self`,
  `cross-log-approval-correlation-bounds`,
  `refactor-pr-design-seed-verify`, `dual-protocol-pr-env-testing`

## Excluded — internal / proprietary (never)

The remaining ~145 skills are runbooks for internal systems or name
internal accounts/repos/services/dashboards. They fail bar rule 3 and
must not be published. By prefix family:

- ZoomInfo: `zoominfo-*`, `zi-*`, `zichat-interaction`,
  `intent-audience-count-discrepancy`, `dsp-mos-data-debugging`,
  `persona-service-*`, `bidder-*`, `zimos-jira-fix-version`
- Clickagy: `clickagy-*`, `kpv2-*`,
  `crowdstrike-falcon-eks-clickagy-onboarding`
- Internal AWS / infra (account-, cluster-, or pipeline-specific):
  most `aws-*`, `cloudwatch-*`, `eks-*`, `alb-*`, `athena-*`,
  `kinesis-*`, `kcl-*`, `kpl-*`, `nat-metrics-*`, `vpc-flow-logs-*`,
  `flow-logs-*`, `app-signals-*`, `cost-explorer-*`, `ecs-*`,
  `istio-*`, `mwaa-*`, `airflow-*`, `grafana-*`, `amg-token-rotation`,
  `pagerduty-*`, internal-state `terraform-*`
  (`terraform-shared-infra-identity-lookup`,
  `terraform-cross-state-tag-ownership`,
  `terraform-sibling-repo-convention-survey`,
  `terraform-aws-provider-profile-vs-env-vars`, ...),
  `identify-aws-service-from-flow-log-ip`,
  `manual-apply-overwritten-by-main-ci`,
  `manual-dev-apply-stale-service-version-downgrades-image`,
  `ci-dual-region-ecr-push-gap`, `ci-spotless-autopush-detached-head`,
  `s3-write-backend-ab-parallel-glue-table`,
  `log-sink-insert-echo-amplification`
- Internal Jira / Atlassian workflows:
  `jira-mcp-issue-and-link-gotchas`, `jira-changelog-mcp-gotchas`,
  `mcp-atlassian-search-result-schema`
- Internal ops / process: `daily-activity-log`,
  `clickagy-prod-deploy-announce`, `zi-operating-system`,
  `zi-nft-gatling-add-service`, `zi-gcs-retention-compliance`

Boundary note: a few `terraform-*` and `micronaut-*` entries are
framework-generic rather than internal and are listed under Deferred,
not here. The split between Deferred and Excluded for borderline infra
skills should be confirmed by reading each `SKILL.md` when #58 is
executed — names alone occasionally understate internal coupling.

## Recommendation

1. Execute #57 (Tier 0) first — it fixes broken links in already-shipped
   skills and is unambiguous.
2. Then #58: add Tier 1 (strong fit), Tier 2 (on-theme), and Tier 3
   (optional) — confirming each borderline/Tier-2 entry against its
   `SKILL.md` before adding.
3. Leave the Deferred set for a later, explicitly-scoped broad pass.
4. Never publish the Excluded set.
