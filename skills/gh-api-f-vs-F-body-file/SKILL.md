---
name: gh-api-f-vs-F-body-file
description: |
  Fix silent failure where `gh api ... -f body=@/tmp/file.md` posts the
  literal text `@/tmp/file.md` as the request body instead of the file's
  contents. Use when: (1) a PR comment, review reply, issue comment, or
  release body posted via `gh api` shows up on GitHub with the literal
  `@/path/to/file` string instead of the intended Markdown, (2) `gh api`
  returns 201 / 200 with no error but the resulting resource has the
  wrong body, (3) scripting `gh api` writes against
  `/repos/.../comments`, `/repos/.../reviews`,
  `/repos/.../pulls/<N>/comments/<id>/replies`,
  `/repos/.../releases`, or any other endpoint that accepts a `body`
  field from a file. Root cause: `gh api`'s `-f` / `--raw-field` sends
  the value as a literal string; `-F` / `--field` is the one that
  templates `@file` into file contents. The two flags differ by a single
  letter of case and BOTH succeed silently, so the bug is not caught by
  exit code or HTTP status. Includes recovery via `gh api -X PATCH ...
  -F body=@/tmp/...` to fix an already-posted comment/review without
  deleting it.
author: Claude Code
version: 1.0.0
date: 2026-05-19
---

# gh api -f vs -F: body=@file silent failure

## Problem

`gh api` ships with two superficially-identical flags for adding form
fields to the request body:

- `-f`, `--raw-field <key=value>` — sends the value as a literal
  string. `@file` is NOT processed.
- `-F`, `--field <key=value>` — same as `-f` but processes `@file`
  (reads file contents into the value) and auto-converts
  `true` / `false` / `null` / numbers.

The two flags differ only by case. Using the wrong one with the
`@file` syntax produces a silent bug:

```
gh api repos/<owner>/<repo>/pulls/<N>/comments/<id>/replies \
  -f body=@/tmp/reply.md
```

POST returns `201 Created`, the comment is created, the API response
looks correct (it echoes back an `id`, an `html_url`, etc.) — BUT the
posted comment body is the literal eight-character string
`@/tmp/reply.md`, not the file's contents. No error is raised at any
layer.

This is especially nasty in scripted / agent workflows where the
posting agent never re-reads the rendered comment, so the bug ships
unnoticed.

## Context / Trigger Conditions

Invoke / consult this skill when any of these are true:

- A PR comment, review reply, issue comment, gist, or release body
  posted via `gh api` shows up on GitHub with the literal
  `@/path/to/file` text where the Markdown body was supposed to be.
- You are about to write a new `gh api` call that reads body content
  from a file (any of `body=@`, `description=@`, `note=@`,
  `text=@`, ...).
- An agent loop (e.g. `work-on-pr`, `review-pr-loop`, a custom CI
  poster) is auto-replying to PRs and one of the replies looks like
  it has a path string instead of prose.
- You've just spotted a thread on a PR where the bot replied
  `@/tmp/<something>.md` and need to fix the live comment without
  deleting it (which would lose thread anchoring).

The bug applies to **any** `gh api` endpoint that takes a body-like
field — not just PR replies. Common shapes that hit it:

```
gh api repos/:owner/:repo/issues/:N/comments    -f body=@...
gh api repos/:owner/:repo/pulls/:N/reviews      -f body=@...
gh api repos/:owner/:repo/pulls/:N/comments/:id/replies  -f body=@...
gh api repos/:owner/:repo/releases              -f body=@...
gh api gists                                    -f description=@...
```

All silently broken with `-f`; all correct with `-F`.

## Solution

### Posting new content

Use `-F` (uppercase F) any time the value starts with `@`:

```
gh api repos/<owner>/<repo>/pulls/<N>/comments/<id>/replies \
  -F body=@/tmp/reply.md
```

Or pass the body inline (no file) — then `-f` is fine because there's
no `@` to template:

```
gh api repos/<owner>/<repo>/pulls/<N>/comments/<id>/replies \
  -f body="$body_var"
```

### Recovering an already-broken comment

If a comment has already been posted with the literal `@/path/...`
text, you can patch it in place rather than deleting and reposting.
PATCHing preserves the comment ID, the thread anchoring, the
in-reply-to chain, and the timestamps:

```
gh api -X PATCH \
  repos/<owner>/<repo>/pulls/comments/<comment_id> \
  -F body=@/tmp/reply.md
```

Endpoint shapes for editing:

| Resource                       | Edit endpoint                                                   |
|--------------------------------|-----------------------------------------------------------------|
| PR top-level issue-comment     | `PATCH /repos/:o/:r/issues/comments/:id`                       |
| PR inline review-thread comment | `PATCH /repos/:o/:r/pulls/comments/:id`                        |
| Issue comment                  | `PATCH /repos/:o/:r/issues/comments/:id`                       |
| Review body                    | `PUT   /repos/:o/:r/pulls/:N/reviews/:id`                      |
| Release                        | `PATCH /repos/:o/:r/releases/:id`                              |

The `-F body=@/tmp/...` form works for all of them.

### `gh pr comment` and `gh pr review` are NOT affected

The high-level CLI wrappers `gh pr comment`, `gh pr review`,
`gh issue comment`, `gh release create`, etc., expose their own
`--body-file <path>` flag that reads the file correctly. That flag
is unrelated to `-f` / `-F` and does not have this footgun:

```
gh pr comment <N>  --body-file /tmp/reply.md   # safe
gh pr review  <N>  --request-changes --body-file /tmp/body.md   # safe
```

The footgun is specific to the **low-level `gh api`** subcommand,
which is used when the high-level wrapper doesn't cover the endpoint
(e.g. inline review-thread replies, which `gh pr` doesn't directly
expose).

## Verification

After posting, re-read the comment via the API to confirm the body
matches the source file:

```
gh api repos/<owner>/<repo>/pulls/comments/<comment_id> \
  --jq '.body | .[0:200]'
```

A correct post echoes back the first ~200 characters of the file. A
broken post echoes back `@/tmp/<basename>` (typically 10–40
characters depending on the path).

A one-liner that posts AND verifies in a single tool call (useful in
an agent script):

```
gh api repos/<o>/<r>/pulls/<N>/comments/<id>/replies \
  -F body=@/tmp/reply.md \
  --jq '{id, body_head: (.body | tostring | .[0:80])}'
```

If `body_head` starts with `@/tmp/`, you used `-f` — fix and re-run
with `-F`.

## Example

Real-world hit (a `work-on-pr` inline-reply loop, `OWNER/REPO` PR #N):

The `work-on-pr` skill's step 6f recipe documented:

```
gh api repos/:owner/:repo/pulls/<N>/comments/<comment_id>/replies \
  -f body=@/tmp/reply.md
```

Agent followed the doc. POST returned 201 with
`id=<comment-id>`. Skill loop continued, scheduled next wakeup, ended
turn.

Next iteration polled the thread and noticed "one new inline comment"
— turned out to be the bot's own malformed reply containing the
literal text `@/tmp/pr-N-reply-inline-<id>.md` rather than
the intended Markdown body.

Recovery sequence:

```
# 1. Patch the live comment with correct body (no delete, no repost).
gh api -X PATCH \
  repos/OWNER/REPO/pulls/comments/<comment-id> \
  -F body=@/tmp/pr-N-reply-inline-<id>.md \
  --jq '{id, body: (.body | tostring | .[0:80])}'
# => {"id":<comment-id>,"body":"[claude] Addressed in <sha>.\n\nYou're right..."}

# 2. Fix the skill recipe so future runs don't re-trip.
#    work-on-pr/SKILL.md step 6f: change `-f body=@...` to `-F body=@...`,
#    add explicit warning about silent-success failure mode.

# 3. Commit and push the doc fix.

# 4. Post a top-level follow-up comment explaining the self-correction
#    (so the human reviewer sees what happened in-thread).
gh pr comment N --repo OWNER/REPO \
  --body-file /tmp/pr-N-comment-r3.md
```

No comment IDs lost, no thread re-anchoring needed, no
delete-and-repost.

## Notes

- **Why the flags exist as a pair.** `-f` is for cases where you
  genuinely want a literal `@foo` or `true` string passed through
  without templating / type coercion. `-F` is the "do what I mean"
  flag. The docs are clear; the trap is that the two are visually
  very close and the failure is silent.
- **`-f` is not always wrong.** If your `body` value does not start
  with `@`, `-f` and `-F` produce identical results. The trap is
  specifically `@file` shapes.
- **`-X PATCH` body fields.** Same `-f` vs `-F` rule applies to
  PATCH / PUT bodies, not just POST. The recovery example above is
  itself a `PATCH` with `-F`.
- **JSON bodies.** For raw-JSON bodies (`--input <file>`), `gh api`
  has a separate `--input` flag that always reads a file. Use that
  shape if you have a pre-built JSON object:
  ```
  gh api -X POST repos/:o/:r/pulls/:N/reviews \
    --input /tmp/review.json
  ```
  The `-f` / `-F` rule only applies to individual form-field flags.
- **Detection via shell wrapper.** If you maintain a wrapper around
  `gh api`, you can guard against the bug by warning when any
  argument matches `-f *=@*`:
  ```bash
  for arg in "$@"; do
    case "$arg" in
      -f*=@*) echo "WARN: -f with @file — use -F instead" >&2 ;;
    esac
  done
  ```

## References

- [`gh api` manual](https://cli.github.com/manual/gh_api) — see the
  `-f, --raw-field` vs `-F, --field` distinction.
- The `work-on-pr` inline-reply loop was the original session where
  this bug surfaced; the fix changed the canonical skill recipe to
  use `-F` (not `-f`) for `gh api` body-file POSTs.
- Related skills: [[work-on-pr]] / [[review-pr-loop]] — both rely
  on `gh api ... -F body=@...` for inline review-thread writes.
