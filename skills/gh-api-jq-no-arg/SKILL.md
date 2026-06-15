---
name: gh-api-jq-no-arg
description: |
  Fix `gh api ... --jq` failing with "accepts 1 arg(s), received 4" (or
  similar positional-arg errors) when you try to pass a shell value into the
  jq filter with jq's `--arg name value`. Use when: (1) you wrote
  `gh api <path> --jq '...' --arg foo "$bar"` and gh errors out, (2) you want
  to parameterize a `gh api --jq` filter with a variable (an anchor
  timestamp, a login, an id) and the obvious jq flag is rejected, (3) a
  watch/poll loop builds gh-api jq filters from runtime values. Root cause:
  `gh api`'s built-in `-q/--jq` is NOT the jq binary and accepts only a single
  filter string; `--arg`/`--argjson`/`--slurpfile` are jq-proper flags gh
  does not forward. Fix: inline the value into the filter, or pipe gh output
  to the real `jq` with `--arg`.
author: Claude Code
version: 1.0.0
date: 2026-06-11
---

# gh api --jq does not accept jq's --arg

## Problem

`gh api`'s `-q` / `--jq` flag runs a jq filter over the response, but it is a
thin built-in, not the `jq` binary. It accepts exactly one argument — the
filter string. Passing jq's own variable-binding flags (`--arg`,
`--argjson`, `--slurpfile`, `--rawfile`) does not work: `gh api` parses the
extra tokens as positional arguments to `gh api` itself (more API paths), and
aborts.

The error is misleading — it complains about argument count, not about the
unsupported flag:

```
accepts 1 arg(s), received 4
```

(The "4" = the endpoint path + `--arg` + `name` + `value`, all seen as
positionals once `--jq`'s single string is consumed.)

## Context / Trigger Conditions

- A command shaped like:
  ```
  A="2026-06-11T16:24:14Z"
  gh api repos/:owner/:repo/pulls/50/reviews \
    --jq '[.[]|select(.submitted_at>$a)]' --arg a "$A"
  ```
  fails with `accepts 1 arg(s), received N`.
- You want to feed a runtime value (timestamp anchor, login, id, sha) into a
  `gh api --jq` filter and reached for `--arg` out of jq habit.
- Common in watch/poll loops (e.g. `work-on-pr` / `review-pr-loop`) that
  compute an anchor timestamp and then filter review/comment surfaces by it.

## Solution

Pick one of two forms.

1. **Inline the value into the filter string** (simplest for one or two
   values). Quote so the shell expands it, or build the string with the
   literal embedded:
   ```
   gh api repos/:owner/:repo/pulls/50/reviews \
     --jq '[.[]|select(.submitted_at>"2026-06-11T16:24:14Z")]'
   ```
   With a shell variable, close the single quotes around it:
   ```
   A="2026-06-11T16:24:14Z"
   gh api repos/:owner/:repo/pulls/50/reviews \
     --jq '[.[]|select(.submitted_at>"'"$A"'")]'
   ```

2. **Pipe to the real `jq`** when you genuinely want `--arg` (cleaner for
   several values, avoids brittle quote-stitching, and `--arg` always treats
   the value as a string so it sidesteps injection):
   ```
   A="2026-06-11T16:24:14Z"
   gh api repos/:owner/:repo/pulls/50/reviews \
     | jq --arg a "$A" '[.[]|select(.submitted_at>$a)]'
   ```
   Use `--argjson` instead of `--arg` if the value must stay numeric/boolean.

Prefer form 2 when the value is attacker-influenced or contains quotes —
inlining untrusted text into a filter string is a jq-injection footgun that
`--arg` avoids.

## Verification

The command returns the filtered JSON instead of
`accepts 1 arg(s), received N`. For the pipe form, confirm `jq` is on PATH
(`command -v jq`); `gh api --jq` works without a separate jq install, the
pipe form does not.

## Example

A poll loop computing an anchor and listing only newer reviews:

```
ANCHOR=$(gh api repos/:owner/:repo/commits/$SHA --jq .commit.committer.date)

# WRONG — gh api --jq has no --arg:
gh api repos/:owner/:repo/pulls/$N/reviews \
  --jq '[.[]|select(.submitted_at>$a)]' --arg a "$ANCHOR"
#   -> accepts 1 arg(s), received 4

# RIGHT — pipe to jq:
gh api repos/:owner/:repo/pulls/$N/reviews \
  | jq --arg a "$ANCHOR" '[.[]|select(.submitted_at>$a)]'
```

## Notes

- Same limitation applies to `gh issue`, `gh pr`, `gh search` etc. whenever
  they expose a `-q/--jq` flag — it is always gh's built-in jq, never the
  binary, so jq's binding flags are unavailable.
- `gh`'s built-in jq does support most of the jq *language* (functions,
  `env`, `now`, etc.) — only the command-line *flags* are absent. You can
  reach environment variables via `env.NAME` inside the filter as an
  alternative to `--arg`:
  ```
  A="2026-06-11T16:24:14Z" gh api .../reviews \
    --jq '[.[]|select(.submitted_at>env.A)]'
  ```
  This keeps everything in `gh api --jq` (no pipe, no jq install) while still
  parameterizing by a shell value — often the cleanest fix.
- Related: [[gh-api-f-vs-F-body-file]] (the `-f` vs `-F` body-file gotcha in
  the same gh-api family).

## References

- [gh api manual](https://cli.github.com/manual/gh_api) — see the `--jq`
  flag description (single filter expression).
- [jq manual: invoking jq](https://jqlang.github.io/jq/manual/#invoking-jq) —
  `--arg`, `--argjson`, `env`.
