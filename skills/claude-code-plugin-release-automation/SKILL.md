---
name: claude-code-plugin-release-automation
description: |
  Make a Claude Code / Codex plugin repo tag itself and publish release
  notes from its manifest version, and make the version bump non-optional.
  Use when: (1) the repo has merges piling up with no tags, no GitHub
  releases, or tags that exist but have no release attached, (2) a
  CONTRIBUTING/CLAUDE.md rule says "bump the version on every shipping
  merge" and nothing enforces it, (3) you are hand-running `git tag -a
  vX.Y.Z <squash-sha> && git push origin vX.Y.Z` after every merge,
  (4) you are about to add a CHANGELOG.md to a repo whose PR titles
  already say what changed, (5) users report `claude plugin update` says
  "up to date" while master has moved, and you want CI to catch the
  missing bump instead of users catching it months later, (6) you need the
  tag to land on the squash commit in a squash-merge repo. Covers the
  two-job workflow (PR-side bump gate + push-side tag-and-release),
  `paths-ignore` as the docs-only exemption, why the gate must NOT be a
  required status check, idempotence for concurrent merges, and the
  multi-plugin case where per-plugin versions are separate cache keys the
  gate cannot see. Pairs with claude-code-plugin-update-flow, which
  explains why the version is load-bearing in the first place.
author: Claude Code
version: 1.1.0
date: 2026-08-17
---

# Claude Code plugin repos: automatic tags and release notes

## Problem

A plugin repo has a version field in `.claude-plugin/plugin.json` that is
already load-bearing — it is the cache key for
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, so an
unchanged version means no install re-extracts and every user keeps running
the old build (see `claude-code-plugin-update-flow`).

Two things go wrong around that field, and both are silent:

1. **The bump is honour-system.** A repo can document "every shipping merge
   bumps the version" and still merge fifty PRs without one, because nothing
   checks. The failure surfaces months later as "your fix never reached me".
2. **Tagging and release notes are manual, so they don't happen.** Repos end
   up with tags and no releases, or no tags at all, and the only record of
   what shipped is `git log`.

The fix for both is the same observation: **the version is already in the
repo and already changes in the PR.** Nothing else needs to be invented — no
CHANGELOG.md, no release-drafter, no semantic-release, no separate VERSION
file. CI can read the field and do the rest.

## Context / Trigger conditions

- `gh release list` is empty on a repo that has been shipping for months.
- `git tag` shows tags with no matching releases.
- Your contributing docs describe a manual tag-after-merge sequence.
- You are tempted to add a CHANGELOG.md that duplicates PR titles.
- You want a merge to be blocked when the author forgot the bump.

## Solution

One workflow file, two jobs, opposite triggers.

```yaml
name: release

on:
  push:
    branches: [master]          # or main
  pull_request:
    branches: [master]
    # Docs/CI-only exemption: users never execute these paths, so a PR
    # touching nothing else is not shipping and owes no bump. Mirror
    # whatever exemption your contributing docs already state.
    paths-ignore:
      - '.github/**'
      - 'tests/**'

permissions:
  contents: read

env:
  VERSION_FILE: .claude-plugin/plugin.json

jobs:
  version-bumped:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Version must advance
        env:
          BASE: ${{ github.base_ref }}
        run: |
          git fetch --no-tags --depth=1 origin "$BASE"
          old=$(git show "FETCH_HEAD:$VERSION_FILE" | jq -r .version)
          new=$(jq -r .version "$VERSION_FILE")
          if [ "$old" = "$new" ]; then
            echo "::error::$VERSION_FILE#version is still $old - bump it."
            exit 1
          fi
          if [ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | head -1)" != "$old" ]; then
            echo "::error::$new does not advance past $old."
            exit 1
          fi
          echo "$old -> $new"

  tag-and-release:
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Tag and release if the version is new
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          version=$(jq -r .version "$VERSION_FILE")
          if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
            echo "v$version is already tagged; nothing to release."
            exit 0
          fi
          gh release create "v$version" \
            --title "v$version" \
            --generate-notes \
            --target "$GITHUB_SHA"
```

### The five decisions inside that file

**`gh release create --target "$GITHUB_SHA"` creates the tag itself.** This
is the whole reason the job exists rather than a local `git tag`. In a
squash-merge repo, a tag made on the feature branch points at a commit that
never lands on the default branch; `--target` puts it on the squash commit
by construction. No `git push --tags`, and `contents: write` is the only
permission needed.

**`--generate-notes` is the changelog.** GitHub builds the notes from PR
titles merged since the previous tag, with authors and links. That is why
there is no CHANGELOG.md to keep in sync — and why **a lazy PR title is now
a lazy release note.** Say so in your contributing docs; it changes how
people write titles. If flat lists get long later, add a `.github/release.yml`
to group by label — still native, still no dependency.

**The gate reads the base via `FETCH_HEAD`, not `origin/<branch>`.** An
explicit `git fetch --no-tags --depth=1 origin "$BASE"` followed by
`git show "FETCH_HEAD:$VERSION_FILE"` works no matter what depth or refspec
the checkout action used. `git show "origin/$BASE:..."` is the version that
breaks on a shallow PR checkout.

**`sort -V` catches a backwards bump, not just a missing one.** A version
that goes *down* re-uses a cache directory that already has old content —
the same silent staleness, harder to spot. One line prevents it.

**Idempotence is the concurrency story.** The push job exits 0 when the tag
exists. Re-runs, replays, and several merges landing close together all
converge instead of colliding, and no state is needed anywhere.

### Where `VERSION_FILE` points

- **Single-plugin repo:** `.claude-plugin/plugin.json`. Done.
- **Multi-plugin repo** (a catalog shipping one plugin per skill, plus a
  bundle): point it at the **bundle** plugin's manifest. That gives one
  release stream — one tag, one release per shipping merge — whose notes
  name whatever changed. Do not try to keep every plugin's version in
  lockstep; in a real catalog they diverge on purpose.

  **Know the gap this leaves.** Each single-skill plugin's own version is
  *that plugin's* cache key. A PR that bumps only the bundle passes the gate
  and still leaves that plugin's users on a stale cache forever. The gate
  cannot see this. Document it where contributors will read it, and if it
  bites often enough, add a changed-path-to-plugin-version check — but that
  is a second, bigger check, not a tweak to this one.

### If the repo ships to Codex as well

A dual-host repo carries a second manifest, `.codex-plugin/plugin.json`, and
Codex pins on *its* version string exactly the way Claude Code pins on the
other one. Bump only one and the other runtime's installs freeze on a cached
copy — the same silent failure, now on a host you are not testing.

Gate both in the same job:

```yaml
env:
  VERSION_FILE: .claude-plugin/plugin.json
  CODEX_VERSION_FILE: .codex-plugin/plugin.json
```

```bash
codex=$(jq -r .version "$CODEX_VERSION_FILE")
if [ "$codex" != "$new" ]; then
  echo "::error::$CODEX_VERSION_FILE is $codex, expected $new - bump both manifests."
  exit 1
fi
```

This is worth automating rather than documenting: "keep both manifests in
lockstep" is easy to write down, easy to follow for a while, and invisible
when it lapses. See `claude-code-codex-plugin-parity` for the rest of the
two-runtime contract.

## Verification

On the PR, expect exactly this split:

```
version-bumped    pass
tag-and-release   skipping
```

`skipping` on the push-only job is correct, not a misconfiguration.

On an exempt PR (only `paths-ignore` paths touched), expect the release
workflow **not to appear at all** — `paths-ignore` skips the workflow, it
does not run it and pass it.

After the merge:

```bash
gh release list -R <owner>/<repo> -L 3
gh api repos/<owner>/<repo>/releases/latest --jq .body | head
```

And on a merge that did not change the version, the push job should log the
no-op rather than failing:

```
v1.0.1 is already tagged; nothing to release.
```

## Notes

- **Do not make `version-bumped` a required status check.** `paths-ignore`
  means the job never reports on an exempt PR, and a required check that
  never reports leaves the PR unmergeable forever. The gate blocks by
  failing, which is enough. If you truly need it required, you need a
  separate always-running job that reports the same check name — more
  machinery than the problem deserves.
- **`paths-ignore` beats a skip label** for the docs-only exemption: it is
  native, needs no bash, and cannot be forgotten. It fires only when *every*
  changed path matches, so a PR touching docs *and* shipped code still runs
  the gate. Keep the ignore list and your contributing docs in sync — they
  are two copies of one policy.
- **First release on a repo with no prior tag contains the entire history.**
  `--generate-notes` has no earlier tag to diff against. Expected, one-time,
  and harmless; later releases are deltas.
- **Adding this workflow in a PR means the gate runs on that PR.** For
  `pull_request` events GitHub uses the workflow file from the PR branch. If
  the PR touches anything outside the ignore list, it must bump its own
  version. That is a free live test of the mechanism.
- **Existing tags stay releaseless** unless you backfill:
  `gh release create v1.0.0 --generate-notes --verify-tag`, once per tag.
- **`gh pr create` / `gh pr merge` can fail with `HTTP 503 ... api.github.com/graphql`**
  while the REST API is fine. Fall back to
  `gh api repos/{owner}/{repo}/pulls -X POST -f title=... -F body=@body.md -f head=... -f base=...`
  and `gh api repos/{owner}/{repo}/pulls/{n}/merge -X PUT -f merge_method=squash`.
  See `gh-pr-graphql-401-rest-fallback` in
  [voitta-ai/skillz-memory](https://github.com/voitta-ai/skillz-memory) for the same fallback under a 401. It
  moved there in skillz#91 and is no longer a skill in this catalog.
- This skill assumes the version field matters. If you have not read
  `claude-code-plugin-update-flow`, read it first — it explains why an
  unbumped version is a silent, permanent failure rather than untidy
  bookkeeping.

## References

- [Automatically generated release notes](https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes)
- [Events that trigger workflows — `paths-ignore`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)
- [`gh release create`](https://cli.github.com/manual/gh_release_create)
- [About protected branches — required status checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)

## Related

- `claude-code-plugin-update-flow` — **read this first.** It is why an unbumped
  version is a silent permanent failure rather than untidy bookkeeping, and
  therefore why the gate this skill builds is worth building.
- `claude-code-codex-plugin-parity` — the paired-manifest rule the release gate
  has to enforce: Codex pins on its own version, so a bump that moves only the
  Claude manifest freezes one host with no error.
- `claude-code-plugin-from-existing-repo` — the repo shape this automation
  assumes.
- `claude-code-plugin-publish-anthropic-marketplace` — the separate,
  human-reviewed step for directory listing. Automating your own tags does not
  automate that.
