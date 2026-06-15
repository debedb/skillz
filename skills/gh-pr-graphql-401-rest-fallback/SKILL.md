---
name: gh-pr-graphql-401-rest-fallback
description: |
  Work around `gh pr comment` / `gh pr merge` / `gh pr review` / `gh pr edit`
  failing with `HTTP 401: Requires authentication` (or
  `non-200 OK status code: 401 Unauthorized body: {"message":"Requires authentication"...}`)
  even though `gh auth status` shows a valid token and other `gh` commands
  work. Use when: (1) a gh PR porcelain subcommand 401s mid-workflow,
  (2) the SAME token succeeds on `gh api` REST calls seconds apart,
  (3) a work-on-pr / review-pr watch loop stalls because it cannot post a
  reply or merge. Root cause: those porcelain subcommands go through the
  GitHub GraphQL API, which can 401 while the v3 REST API accepts the same
  token. Fix: re-issue the action against the REST endpoint via `gh api`.
author: Claude Code
version: 1.0.0
date: 2026-06-10
---

# gh PR porcelain GraphQL 401 -> REST fallback

## Problem

`gh pr comment`, `gh pr merge`, `gh pr review`, and `gh pr edit` are
implemented against GitHub's **GraphQL** API (`api.github.com/graphql`).
That endpoint can return `401 Requires authentication` while the **REST**
(v3) API accepts the exact same token in the same shell, seconds apart.
`gh auth status` reports the token as valid, so the failure looks
inexplicable and a PR-watch loop can stall on it (cannot post a reply,
cannot merge).

## Context / Trigger Conditions

- `gh pr comment <N> --body-file f.md` fails with:
  `HTTP 401: Requires authentication (https://api.github.com/graphql)`
- `gh pr merge <N> --squash` fails with:
  `non-200 OK status code: 401 Unauthorized body: "{ "message": "Requires authentication", ... "status": "401" }"`
- `gh auth status` shows `Logged in ... (keyring)`, `Active account: true`,
  a token with at least `repo` scope.
- Plain `gh api repos/OWNER/REPO/...` GET calls (the read polls in a watch
  loop) keep working fine — only the GraphQL-backed porcelain 401s.
- Often intermittent: it reproduced twice in one session here (a PR
  comment, then the merge), with REST succeeding both times.

## Solution

Re-issue the write against the REST endpoint with `gh api`. REST mirrors
every porcelain action used by the work-on-pr / review-pr loops:

**Post a PR/issue comment** (replaces `gh pr comment <N> --body-file f`):
```
gh api repos/OWNER/REPO/issues/<N>/comments -X POST -F body=@/tmp/reply.md
```
`-F body=@file` reads the body from a file (avoids shell-quoting traps,
same benefit as `--body-file`). Use `-f body='...'` for a literal string.

**Merge a PR** (replaces `gh pr merge <N> --squash`):
```
HEAD=$(gh api repos/OWNER/REPO/pulls/<N> --jq .head.sha)
gh api -X PUT repos/OWNER/REPO/pulls/<N>/merge \
  -f merge_method=squash -f sha="$HEAD"
```
`merge_method` is one of `merge` | `squash` | `rebase`. Passing `sha=`
is a safety guard: the merge fails if the head moved since you read it
(equivalent to gh's `--match-head-commit`). Success returns
`{"sha":"...","merged":true,"message":"Pull Request successfully merged"}`.

**REST merge does NOT delete the branch** (the `--delete-branch` flag is a
gh-porcelain convenience). Delete it explicitly afterward:
```
gh api -X DELETE repos/OWNER/REPO/git/refs/heads/<branch>
```

**Submit a review** (replaces `gh pr review`):
```
gh api repos/OWNER/REPO/pulls/<N>/reviews -X POST \
  -f event=APPROVE -f body='...'        # or REQUEST_CHANGES / COMMENT
```

**Edit PR body** (replaces `gh pr edit <N> --body-file f`):
```
gh api -X PATCH repos/OWNER/REPO/pulls/<N> -F body=@/tmp/body.md
```

Before falling back, a single `gh auth refresh -h github.com` sometimes
clears a genuinely stale token — but in this case the token was valid for
REST throughout, so don't block the workflow waiting on a re-auth;
just use `gh api`.

## Verification

- The REST call returns a 2xx JSON body (the created comment object, the
  `"merged":true` merge result, etc.) instead of a 401.
- Re-poll to confirm the side effect landed: `gh api .../issues/<N>/comments`
  shows your comment; `gh pr view <N> --json state` shows `MERGED`.

## Example

From a work-on-pr loop on OWNER/REPO#N:

```
$ gh pr comment N --body-file /tmp/reply.md
HTTP 401: Requires authentication (https://api.github.com/graphql)

$ gh api repos/OWNER/REPO/issues/N/comments -X POST -F body=@/tmp/reply.md
{"id":<comment-id>, ... "html_url":".../pull/N#issuecomment-<comment-id>"}   # posted

$ gh pr merge N --squash --delete-branch
non-200 OK status code: 401 Unauthorized body: "{ "message": "Requires authentication" ... }"

$ FULL=$(gh api repos/OWNER/REPO/pulls/N --jq .head.sha)
$ gh api -X PUT repos/OWNER/REPO/pulls/N/merge -f merge_method=squash -f sha="$FULL"
{"sha":"<merge-sha>","merged":true,"message":"Pull Request successfully merged"}

$ gh api -X DELETE repos/OWNER/REPO/git/refs/heads/feature/<branch>
# remote branch gone; then clean up worktree + local branch
```

## Notes

- **Why this happens (uncertain / multiple causes):** the GraphQL endpoint
  enforces auth/scopes on a path separate from REST; certain token types,
  host routing, or transient `api.github.com/graphql` issues can 401 GraphQL
  while REST stays up. The reproduction here was intermittent, so treat the
  REST fallback as the reliable unblock rather than chasing a root cause
  mid-loop.
- **Pairs with** the `work-on-pr` and `review-pr-loop` skills, which call
  `gh pr comment` / `gh pr merge` directly. When running those loops, prefer
  the `gh api` REST forms above if you see a single graphql 401, so a quiet
  PR doesn't stall on a flaky porcelain call.
- **`-F` vs `-f` in `gh api`:** `-F` does field-type magic (`@file` reads a
  file, bare numbers/bools are typed); `-f` always sends a literal string.
  For a Markdown body from a file use `-F body=@file`; for an inline string
  use `-f body='text'`. See the related `gh-api-f-vs-F-body-file` skill.
- Do NOT auto-`gh auth refresh` in an unattended loop expecting it to fix
  this — it can open an interactive device-code flow and the token was
  already valid for REST anyway.

## References

- [gh api manual](https://cli.github.com/manual/gh_api)
- [GitHub REST: merge a pull request (PUT /pulls/{N}/merge)](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request)
- [GitHub REST: create an issue comment (POST /issues/{N}/comments)](https://docs.github.com/en/rest/issues/comments)
- [GitHub REST: create a PR review (POST /pulls/{N}/reviews)](https://docs.github.com/en/rest/pulls/reviews)
- Related skills: `work-on-pr`, `review-pr-loop`, `gh-api-f-vs-F-body-file`,
  `gh-git-heredoc-body-file`, `gh-pr-merge-delete-branch-closes-dependent-pr`.
