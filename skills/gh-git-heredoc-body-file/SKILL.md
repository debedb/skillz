---
name: gh-git-heredoc-body-file
description: |
  Fix gh CLI and git commands that mangle multi-line bodies containing
  backticks, code blocks, or `$(...)` substitutions. Use when:
  (1) `gh issue create --body "$(cat <<'EOF'...)"` produces an issue/PR
  where code blocks are empty and backtick-quoted terms are stripped,
  (2) bash reports "command not found" errors naming words from inside
  your heredoc body (e.g. "metrics-server: command not found"),
  (3) `git commit -m "$(cat <<'EOF'...)"` fails with "unexpected EOF
  while looking for matching `'`", (4) a markdown PR body comes through
  with blank code fences despite using a quoted `'EOF'`. Root cause:
  even with `<<'EOF'` (which disables expansion inside the heredoc
  itself), backticks are still interpreted by bash because the whole
  `$(...)` command substitution runs in an unquoted-except-for-the-outer-"..."
  context where backtick semantics apply to the stringified output.
  Fix: write the body to a temp file and use `--body-file` (gh) or
  `-F` (git commit) instead.
author: Claude Code
version: 1.0.0
date: 2026-04-19
---

# gh CLI / git: heredoc backtick mangling → use --body-file

## Problem

Multi-line bodies passed via command substitution to `gh` or `git` silently lose backtick-enclosed content, even when the heredoc delimiter is single-quoted (`<<'EOF'`) to disable expansion.

Broken pattern (looks correct, isn't):

```bash
gh issue create --body "$(cat <<'EOF'
Install the `metrics-server` helm chart into `kube-system`.

Use `aws_eks_access_entry` resources with `for_each`.
EOF
)"
```

The issue body on GitHub comes through as:

```
Install the  helm chart into .

Use  resources with .
```

Backtick-quoted words are gone, and if those words happened to collide with real commands, bash also spews errors to stderr during the `gh` invocation:

```
/bin/bash: line 81: metrics-server: command not found
/bin/bash: line 81: kube-system: command not found
/bin/bash: line 81: aws_eks_access_entry: command not found
/bin/bash: line 81: for_each: command not found
```

`gh` still succeeds — it just sends the mangled body. You only notice when you open the issue and see the damage.

## Context / Trigger Conditions

All of these are the same underlying bug:

- **gh commands with heredoc body**: `gh issue create --body "$(...)"`, `gh pr create --body "$(...)"`, `gh issue comment --body "$(...)"`, `gh pr comment`, `gh issue edit`, `gh pr edit`.
- **git commit with heredoc message**: `git commit -m "$(cat <<'EOF'...EOF)"` often fails with `unexpected EOF while looking for matching \``.
- **Stderr clue**: lines like `/bin/bash: line N: SOMEWORD: command not found` where SOMEWORD is something from inside your body (a backtick-quoted identifier, a code-fence language tag, a command name). That's bash trying to execute the backtick content at nesting level 2.
- **Silent mangling clue**: the resulting markdown looks fine except every backtick-quoted term is missing, and code fences are empty.

Do not confuse with:
- `<<EOF` (unquoted) — this one expands `$VAR` and `$(...)` and backticks inside the body itself. Different failure mode (variables get substituted).
- Markdown rendering issues unrelated to shell — always verify the raw body via `gh issue view N --json body --jq .body` before blaming the shell.

## Why it happens

The sequence of substitutions in a construct like:

```bash
gh issue create --body "$(cat <<'EOF'
some `backticked` content
EOF
)"
```

1. **Heredoc quoting** (`<<'EOF'`) protects the body from `$VAR` and `$(...)` expansion **inside the heredoc itself** when read by `cat`. That works — `cat` sees the literal text.
2. **Command substitution** (`$(...)`) captures `cat`'s stdout and substitutes it into the outer double-quoted string.
3. **Inside the outer `"..."`**: double quotes disable globbing and word splitting but do **not** disable backtick command substitution. So the backticks from the heredoc content, now living inside a double-quoted string, get interpreted as a second round of command substitution.

Net effect: everything between backticks becomes the output of running that content as a command (usually empty, since `metrics-server` isn't a command), and you get `/bin/bash: metrics-server: command not found` on stderr as bash fails to execute each backtick-extracted word.

The fact that backticks survive quote-stripping inside `"..."` is a POSIX-specified bash behavior, not a bug. The `$(...)` form of command substitution does NOT have this property — only backticks do. But your heredoc body is written in markdown, which uses backticks heavily for inline code, so the collision is common.

## Solution

Write the body to a temporary file, pass the path via `--body-file` (gh) or `-F` (git commit). Both flags disable any shell interpretation of the file contents.

### gh commands

```bash
cat > /tmp/pr-body.md <<'EOF'
## Summary

Install the `metrics-server` helm chart. Configure `for_each`.

```hcl
resource "aws_eks_access_entry" "creator" {
  cluster_name = aws_eks_cluster.main.name
}
```

Closes #32.
EOF

gh pr create --title "..." --body-file /tmp/pr-body.md
```

Works for every `gh` subcommand that takes `--body`:

- `gh issue create --body-file <path>`
- `gh issue edit <N> --body-file <path>`
- `gh issue comment <N> --body-file <path>`
- `gh pr create --body-file <path>`
- `gh pr edit <N> --body-file <path>`
- `gh pr comment <N> --body-file <path>`
- `gh pr review --body-file <path>`

### git commit

```bash
cat > /tmp/commit-msg.txt <<'EOF'
Refactor: extract `cert.tf` into a module

- Eliminate `aws_acm_certificate` duplication per region
- Module exposes `certificate_arn` output
EOF

git commit -F /tmp/commit-msg.txt
```

### git tag -a, git merge, git rebase --exec

Same pattern — write to a file, use `-F <path>` where supported. For commands that only accept `-m`, fall back to a single-line message or editing the message interactively (`git commit` with no `-m` or `-F` opens `$EDITOR`).

## Verification

After running, read back the actual stored body:

```bash
# Issue/PR body
gh issue view <N> --json body --jq .body
gh pr view <N> --json body --jq .body

# Commit message
git log -1 --format='%B'
```

If backticks survived and code blocks have content, you're done. If you see empty inline spans where backticks should be, the body got mangled — re-write via `--body-file` / `-F`.

## Example

Real session: issue #39 created via `gh issue create --body "$(cat <<'EOF'... EOF)"`. The issue URL came back (so `gh` reported success), but `gh issue view 39 --json body --jq .body` showed:

```
### 1.  (prerequisite)
Install the  helm chart into  via a new  in .
```

Every backticked term gone. Stderr during creation had ~40 lines of `/bin/bash: metrics-server: command not found`, `/bin/bash: kube-system: command not found`, etc. — the clue that something had been interpreted as a shell command.

Fix: wrote the body to `/tmp/issue-39-body.md` with `cat > /tmp/issue-39-body.md <<'EOF' ... EOF`, then:

```bash
gh issue edit 39 --body-file /tmp/issue-39-body.md
```

Re-read the body — backticks and code blocks intact.

## Notes

- **`cat > /tmp/foo` vs `Write` tool**: when authoring these bodies in Claude Code, using the `Write` tool to create the file directly is cleaner than `cat > ... <<'EOF'` in Bash, because the shell quoting of the *writing* step is one less thing to get wrong. Either approach lands the file on disk for `--body-file` to read.
- **Why `<<'EOF'` alone isn't enough**: the quoted heredoc protects the body from expansion at heredoc-read time. But then command substitution (`$(cat <<'EOF' ... EOF)`) captures the output and inserts it into the outer double-quoted string, where backtick interpretation applies. The protections don't compose the way they look.
- **`$(...)` vs backticks inside the body**: if your body contains `` `code` `` it breaks. If it contains `$(some command)` it also breaks via the same path. The only safe markdown-body-containing syntax you can pass through `"$(...)"` is one without either character. Almost no real markdown qualifies.
- **Why not escape every backtick**: technically `\\\`` inside the heredoc survives, but that's brittle, makes the source unreadable, and breaks rendering if any escape gets dropped. File-based passing is just better.
- **`cat file | gh issue create --body -`**: some gh commands accept `-` to read stdin, which is another way to avoid the shell-quoting trap. `--body-file` is more explicit and works everywhere gh accepts a body.

## References

- [Bash manual: Command substitution](https://www.gnu.org/software/bash/manual/html_node/Command-Substitution.html) — documents backtick behavior inside `"..."`
- [gh manual: `--body-file`](https://cli.github.com/manual/gh_issue_create) — supported on all `create`/`edit`/`comment` subcommands
- [git-commit(1)](https://git-scm.com/docs/git-commit#Documentation/git-commit.txt--Fltfilegt) — `-F <file>` for commit messages
