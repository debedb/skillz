---
name: gh-fork-issues-disabled
description: |
  Fix `gh issue create` failing with "the 'OWNER/REPO' repository has
  disabled issues" on a GitHub fork. Use when: (1) `gh issue create
  --repo OWNER/REPO ...` fails with that exact error, (2) you forked a
  repo and intend to file local issues on the fork (not upstream),
  (3) confused why issues seem disabled when you didn't disable them.
  Root cause: GitHub disables the Issues tab on forks by default and
  the setting is hidden in the repo Features section.
author: Claude Code
version: 1.0.0
date: 2026-05-10
---

# `gh issue create` on a fork: "repository has disabled issues"

## Problem

Filing an issue against a fork fails:

```
$ gh issue create --repo my-org/forked-repo --title "..." --body "..."
the 'my-org/forked-repo' repository has disabled issues
```

This is surprising because the user never disabled issues. They did NOT
opt out — GitHub's default for forks is "Issues: off". The setting lives
under Settings → General → Features → Issues and is unchecked by default
on every fork.

## Context / Trigger Conditions

- Working in a fork (`gh repo view --json parent` returns a non-null parent)
- `gh issue create --repo FORK ...` returns the disabled-issues error
- Visiting the fork's GitHub URL shows no "Issues" tab in the navbar
- You intend to file issues on the fork itself (e.g. tracking work to be
  contributed upstream separately, or recording fork-specific TODOs)

## Solution

Enable issues on the fork, then retry:

```
gh repo edit OWNER/REPO --enable-issues
gh issue create --repo OWNER/REPO --title "..." --body-file path/to/body.md
```

`--enable-issues` is silent on success (no stdout). Verify with:

```
gh repo view OWNER/REPO --json hasIssuesEnabled
```

## Verification

After `gh repo edit ... --enable-issues`:
- `gh repo view OWNER/REPO --json hasIssuesEnabled` returns
  `{"hasIssuesEnabled":true}`
- The fork's GitHub page shows the "Issues" tab
- `gh issue create` succeeds and returns the new issue URL

## Example

```
$ gh issue create --repo voitta-ai/goal-kit --title "sdk-harness: ship or delete" --body-file /tmp/issue.md
the 'voitta-ai/goal-kit' repository has disabled issues

$ gh repo edit voitta-ai/goal-kit --enable-issues
$ gh issue create --repo voitta-ai/goal-kit --title "sdk-harness: ship or delete" --body-file /tmp/issue.md
https://github.com/voitta-ai/goal-kit/issues/1
```

## Notes

- This applies to ANY fork on github.com regardless of the parent's
  issues setting. The parent having issues enabled does not enable
  issues on forks.
- If you only want to file issues UPSTREAM (against the parent), no
  need to enable on the fork — just point `--repo` at the parent and
  rely on its existing issues config.
- Same gating applies to wiki, projects, discussions on forks — each
  defaults off, each has its own `gh repo edit --enable-X` flag.
- For multi-paragraph bodies with apostrophes or backticks, prefer
  `--body-file` over inline `--body "$(cat <<'EOF' ... EOF)"` — the
  heredoc form can choke on unbalanced quoting inside the body.

## References

- `gh repo edit --help` (flags: `--enable-issues`, `--enable-wiki`, `--enable-projects`)
- GitHub docs: [Disabling issues in a repository](https://docs.github.com/en/issues/tracking-your-work-with-issues/configuring-issues/disabling-issues)
