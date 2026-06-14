---
name: vercel-token-deploy-branch-domains
description: |
  Wire up per-branch Vercel deploys to fixed custom domains using ONLY a Vercel
  token (GitHub Actions), without the Vercel GitHub App / org-owner approval. Use
  when: (1) a project has NO Git integration (link is null) and every deploy is a
  manual `vercel --prod`, (2) you want `main` -> prod domain and `staging` branch ->
  a stable staging.<domain> with separate env, (3) `vercel alias set <domain>` fails
  "You don't have access to the domain ... under <team>" because the apex domain is
  owned by a DIFFERENT Vercel team than the project, (4) a custom domain bound to a
  PREVIEW deployment returns HTTP 401 with a `_vercel_sso_nonce` cookie (Vercel
  Deployment Protection), even though ssoProtection is `all_except_custom_domains`.
  Covers the project-domain `gitBranch` API pin, why preview custom domains stay
  SSO-walled, and disabling protection.
author: Claude Code
version: 1.0.0
date: 2026-06-14
source: https://github.com/voitta-ai/skillz
source_file: skills/vercel-token-deploy-branch-domains/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> `skills/vercel-token-deploy-branch-domains/SKILL.md`.

# Vercel: token-only per-branch deploys to fixed custom domains

## Problem
You want `main` -> `app.com` and a `staging` branch -> `staging.app.com` (with its
own Preview env vars), but: the project has no GitHub App integration, installing it
needs org-owner approval you don't have, AND naive `vercel alias set` fails or the
staging domain ends up behind a login wall.

## Context / Trigger conditions
- `GET /v9/projects/{id}` shows `"link": null` and `vercel ls` shows only manual
  CLI deploys (same username, ~50s) -> no Git→Vercel auto-deploy exists.
- `vercel alias set staging.app.com <deployment>` -> `Error: You don't have access
  to the domain staging.app.com under <team>`. Root cause: the apex domain is owned
  by a *different* Vercel team than the project (cross-team domain attachment). The
  CLI token can manage the project but not that domain's owning team.
- After binding the staging custom domain to a Preview deployment, `curl` returns
  `HTTP 401` + `set-cookie: _vercel_sso_nonce=...` = Vercel Deployment Protection.
  This happens EVEN with `ssoProtection.deploymentType = "all_except_custom_domains"`
  — that setting only exempts the **production** custom domain; a Preview-target
  deployment stays protected on its custom domain too.

## Solution
1. **Deploy with the token, not the GitHub App.** Two GitHub Actions workflows,
   secrets `VERCEL_TOKEN` / `VERCEL_ORG_ID` / `VERCEL_PROJECT_ID`:
   - on push to `main`: `vercel pull --environment=production` -> `vercel build --prod`
     -> `vercel deploy --prebuilt --prod`  (production env, aliases prod domain).
   - on push to `staging`: `vercel pull --environment=preview` -> `vercel build`
     -> `vercel deploy --prebuilt`  (Preview env -> Preview-target deployment).
2. **Pin the staging custom domain to its branch via the API** (NOT `alias set`,
   which the cross-team ownership blocks). This routes the domain to the latest
   deployment of that branch AND stops `--prod` deploys from stealing it:
   ```
   curl -X PATCH -H "Authorization: Bearer $VERCEL_TOKEN" \
     "https://api.vercel.com/v9/projects/$PRJ/domains/staging.app.com?teamId=$TEAM" \
     -d '{"gitBranch":"staging"}'
   ```
   Leave the prod domain's `gitBranch` null (it stays the production domain).
3. **Public staging requires disabling SSO protection** (a Preview custom domain is
   walled otherwise). Security tradeoff: this also exposes every PR preview URL.
   ```
   curl -X PATCH -H "Authorization: Bearer $VERCEL_TOKEN" \
     "https://api.vercel.com/v9/projects/$PRJ?teamId=$TEAM" -d '{"ssoProtection":null}'
   ```

## Verification
- `vercel inspect <staging-deployment-url>` lists `staging.app.com` under Aliases.
- `curl -sS -o /dev/null -w '%{http_code}' https://staging.app.com/` -> `200`
  (no `_vercel_sso_nonce` cookie).
- A push to `staging` updates `staging.app.com`; a push to `main` does NOT change it.

## Notes
- One Vercel token can span multiple teams. `vercel --scope <x>` wants the team
  **slug/id**, not an arbitrary name; without `--scope` the CLI uses the token's
  default team, which may differ from the project's team — check `vercel inspect`
  output's "under <team>" line.
- Per-target env vars are injected at RUNTIME by environment tier. A Preview-target
  deployment ALWAYS gets Preview env vars (even aliased to a custom domain). So you
  cannot have prod-env on `app.com` and preview-env on `staging.app.com` from the
  same single deployment — they must be different env tiers / branches (or separate
  projects).
- If a feature needs creds (e.g. S3) on staging, copy those vars into the **Preview**
  target too; otherwise the Preview deployment lacks them.

## References
- Vercel Deployment Protection: https://vercel.com/docs/security/deployment-protection
- Vercel project domains API (`gitBranch`): https://vercel.com/docs/rest-api/reference/endpoints/projects/update-a-project-domain
