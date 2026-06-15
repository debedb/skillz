---
name: github-private-repo-readme-image-rendering
description: |
  Explains why images/badges (e.g. coverage SVGs, shields) render as broken on a
  PRIVATE GitHub repo's README when referenced by an absolute
  raw.githubusercontent.com URL or a file on a different branch, but render fine
  when referenced by a relative path to a file in the same ref. Use when:
  (1) you are adding in-repo coverage/status badges to a private repo and
  deciding where to store the SVGs, (2) README badges show a broken-image icon
  for logged-in repo members even though the file exists, (3) you are tempted to
  have CI push generated images to a separate "badges" branch and link them via
  raw URL, (4) shields.io / Codecov / gh-pages are off the table because the repo
  must stay private. Root cause: GitHub's camo image proxy fetches absolute URLs
  unauthenticated, so private raw URLs 404; relative paths are served within
  repo-auth context but only resolve within the same branch/commit being viewed.
author: Claude Code
version: 1.0.0
date: 2026-05-28
---

# Private-repo README image rendering (camo + relative paths)

## Problem
On a **private** GitHub repo you add badges/images to the README. They show as a
broken-image icon (or just don't appear) even for authenticated repo members —
or they appear only on one branch and not on `main`.

## Context / Trigger Conditions
- Repo visibility is **private** (the public-repo rules differ — shields/raw URLs just work there).
- README references an image via `https://raw.githubusercontent.com/owner/repo/<branch>/path.svg` or `https://github.com/owner/repo/raw/<branch>/path.svg`.
- Or the image file lives on a different branch (e.g. a `badges` branch) than the README being viewed.
- Symptom: broken image for logged-in members; the file demonstrably exists in the repo.

## Solution
Understand the two rendering modes GitHub uses in Markdown:

1. **Relative path in the same ref** (e.g. `![](.github/badges/coverage.svg)` in
   `main`'s README): GitHub serves it through its image proxy **with repo-auth
   context**, so it renders for authenticated members of the private repo. BUT a
   relative path only resolves against the **same branch/commit being viewed** —
   it cannot point at a file on another branch.

2. **Absolute `raw.githubusercontent.com` (or `/raw/`) URL**: GitHub's camo image
   proxy fetches this **server-side, unauthenticated**. For a private repo that
   returns 404 → broken image. Camo strips the viewer's cookies, so "I'm logged
   in" does not help.

Therefore, for inline rendering on a given README, **the image file must live in
the same branch/commit as that README**, referenced by a relative path.

Practical consequences when designing private-repo badges:
- To show badges inline on `main`'s README, the SVGs **must be committed to
  `main`** and referenced relatively. There is no raw-URL or other-branch trick
  that renders inline on a private repo.
- "CI pushes badges to an unprotected `badges` branch and the README links them
  by raw URL" **does not work** on a private repo — it collapses to no inline
  rendering. (It works on public repos.)
- If you cannot/won't push generated images to the protected branch, the
  realistic fallbacks are: a link-out to the latest artifact, or surfacing the
  numbers in `$GITHUB_STEP_SUMMARY` instead of inline badges.

## Verification
- Move/commit the SVG into the same branch as the README, reference it
  relatively, and reload while logged in → it renders.
- Switch the same README to an absolute raw URL for the private repo → broken
  image returns. That A/B confirms camo, not a path typo, is the cause.

## Example
A coverage-badge feature generated three SVGs and needed them inline on `main`'s
README of a private repo. Pushing them to a separate branch + raw URL was
considered to avoid branch protection, but camo can't auth the private raw URL,
so that path renders broken. The only way to get inline-on-`main` badges was to
commit the SVGs to `main` (relative path) — which in turn required a workflow to
push to the protected branch, leading into a separate ruleset-bypass problem
(a workflow integration needs an org-level bypass to push to a protected branch).

## Notes
- This is about **inline image rendering**, not about whether the file is
  reachable. A private raw URL is reachable with a token (e.g. `curl -H
  "Authorization: token ..."`), it just won't render through camo in Markdown.
- gh-pages is also a trap on private repos without the right plan tier: it can
  force a PUBLIC site that leaks repo contents. Don't reach for it to host
  private badges.
- Public repos do not have this problem — raw URLs and shields.io render fine.

## References
- About anonymized image URLs (Camo): https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-anonymized-urls
