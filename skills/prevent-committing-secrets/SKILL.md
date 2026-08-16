---
name: prevent-committing-secrets
description: |
  Block a credential at commit time with a pre-commit secret scanner, and make
  new repos get one without anyone remembering to ask. Use when: (1) running
  `git init` or cloning a repo you will commit to; (2) about to commit in a repo
  that has no scanner installed; (3) asked to "make sure we never commit a key";
  (4) a commit was just blocked and someone reaches for `--no-verify`. Covers
  gitleaks via the pre-commit framework and as a raw hook, `init.templateDir` so
  new and cloned repos are covered automatically, the four paths that skip the
  hook (`--no-verify`, merge commits, replayed commits, `core.hooksPath`), why a
  staged-diff scan says nothing about history, GitHub push protection as the half
  that cannot be bypassed locally, and what to do when the hook fires.
author: Claude Code
version: 1.0.0
date: 2026-08-15
---

# Prevent committing secrets

## Problem

A repo starts with no secret scanning and stays that way. `.git/hooks/` ships
only `*.sample` files, hooks are never cloned and never versioned, so every repo
and every fresh clone is unguarded until someone acts per-repo.

Commit time is the last cheap moment. After a push, deleting the line is not
containment — the blob is in history, in every clone, and possibly already
indexed; the only real fix is rotation. Keys have sat in private repos for a year
this way, not because a review missed them, but because nothing was checking.

## Check before you commit

```bash
hooks="$(git rev-parse --git-path hooks)"       # honors core.hooksPath
[ -x "$hooks/pre-commit" ] || echo "no pre-commit hook in $hooks"
```

If it is missing, offer to install one (below). Either way, scan what is about to
be committed — this needs no hook and no config:

```bash
gitleaks git --pre-commit --redact --staged --verbose
```

`--redact` matters: without it the finding prints the secret, which puts it in
the terminal, the CI log, and the agent transcript. See
`secrets-in-agent-sessions`.

## Install: repo-local

**With the pre-commit framework** (reproducible, versioned, reviewable):

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks-system
```

```bash
pre-commit install
pre-commit install --hook-type pre-merge-commit     # see trap 2
```

Pick the hook id by what you have: `gitleaks` is `language: golang` and builds
from source (needs a Go toolchain); `gitleaks-system` uses a `gitleaks` already
on `PATH` (`brew install gitleaks`); `gitleaks-docker` needs neither. All three
run the same command.

**Raw hook**, for a repo not using the framework:

```bash
hooks="$(git rev-parse --git-path hooks)"
cat > "$hooks/pre-commit" <<'SH'
#!/bin/sh
exec gitleaks git --pre-commit --redact --staged --verbose
SH
chmod +x "$hooks/pre-commit"
```

The older spelling `gitleaks protect --staged` still runs but the subcommand is
hidden and deprecated; `gitleaks git --staged` replaced it. Check
`gitleaks version` before copying a snippet found online.

That hook **fails closed**: with gitleaks not installed, `exec` exits 127 and
git aborts the commit. Correct, but the message a colleague sees is
`gitleaks: not found`, and the tempting fix is to delete the hook. Install
gitleaks instead.

## Install: every future repo, automatically

Hooks are per-repo, so the leverage is in the template git copies into each new
`.git/`. With the framework, one command does it:

```bash
pre-commit init-templatedir ~/.git-template
git config --global init.templateDir ~/.git-template
```

`init-templatedir` installs with skip-on-missing-config, so repos cloned without
a `.pre-commit-config.yaml` are not broken by the template hook; it also warns if
`init.templateDir` does not point at the directory you just populated. Without
the framework, copy the raw hook in yourself:

```bash
mkdir -p ~/.git-template/hooks
cp "$(git rev-parse --git-path hooks)/pre-commit" ~/.git-template/hooks/pre-commit
chmod +x ~/.git-template/hooks/pre-commit
git config --global init.templateDir ~/.git-template
```

The raw version has no such tolerance: every repo created afterwards blocks every
commit on any machine where gitleaks is missing. That is the right default for a
secret gate, but decide it deliberately.

`git init` **and** `git clone` copy the template's hooks into the new repo, so
this is the answer to "install a scanner whenever a repo is created". Existing
repos are not retro-fitted automatically, but re-running init in one is safe and
does the job — verified: it copies template files that are absent and leaves an
existing `pre-commit` untouched.

```bash
git init .          # in an existing repo: adds the hook, overwrites nothing
```

## What the hook does not cover

1. **`--no-verify`** — bypass by design, for `git commit` and `git merge` alike.
   A local hook is advisory. This is the reason for push protection below.
2. **Merge commits.** `git merge` fires `pre-merge-commit`, not `pre-commit`
   (githooks(5)). A default `pre-commit install` covers only the `pre-commit`
   type; a secret arriving on a merge commit sails through.
3. **Commits git creates by replay** — rebase, cherry-pick, `git commit-tree`,
   and anything writing objects directly. Only `git commit` runs `pre-commit`.
4. **`core.hooksPath` is set.** Then `.git/hooks/` is ignored entirely and a hook
   written there never runs; the framework refuses outright —
   `Cowardly refusing to install hooks with core.hooksPath set` (fix:
   `git config --unset-all core.hooksPath`, or put the hook in the configured
   directory). `git rev-parse --git-path hooks` (used above) resolves to the real
   directory, so use it rather than hardcoding `.git/hooks`.

And the one that gives false confidence: **the hook only sees the staged diff.**
It says nothing about what is already in the repo. Installing it is not evidence
the repo is clean, so scan the history once, at install time:

```bash
gitleaks git --redact .          # full history
gitleaks dir  --redact .         # working tree, including untracked
```

A clean scan is also not proof. gitleaks' default config is ~222 provider-shaped
rules plus one `generic-api-key` rule that needs a keyword (`key`, `token`,
`secret`, `password`, …) within ~50 characters of the value **and** entropy ≥ 3.5.
A credential in a field named `"k"`, a bare base64 blob, or an internal token
format with no recognizable prefix passes both the hook and GitHub's push
protection. Treat the scanners as catching the known shapes, not as an oracle.

For the deeper version of that audit — history rewrites, placeholders vs. real
values, the `git grep -E` `\b` false negative — see
`pre-open-source-credential-audit`.

## The half that cannot be bypassed locally: push protection

```bash
gh api repos/$O/$R --jq .security_and_analysis
```

Do not assume it is on because the repo is public; check. Enable per repo (push
protection requires secret scanning, so set both):

```bash
gh api -X PATCH repos/$O/$R --input - <<'JSON'
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},
 "secret_scanning_push_protection":{"status":"enabled"}}}
JSON
```

Org-wide, GitHub now does this with a code security configuration applied to the
org's repos rather than per-repo toggles:

```bash
gh api orgs/$ORG/code-security/configurations \
  --jq '.[] | [.id, .name, .secret_scanning_push_protection] | @tsv'
```

Push protection blocks the push server-side; a bypass takes an explicit reason
and is recorded. Local hook = fast feedback for the person committing; server
side = the actual gate. Ship both.

## When it fires

1. **Placeholder or fixture?** Allowlist the path or fingerprint in
   `.gitleaks.toml` — do not disable the hook.
2. **Real value: rotate first.** The scanner found it in your staged diff, which
   means it is also in the working tree, the editor's undo history, your shell
   history and probably an agent transcript. Removing this one copy is not
   containment (`agent-credential-leak-surfaces`).
3. Replace the literal with an env var or a secret-store read, re-stage, commit.
4. **Never re-run the commit with `--no-verify`.** If you are an agent: a blocked
   commit is a stop, not an obstacle. Report it and rotate; do not bypass.
5. If an **earlier** commit already carries it (hook installed late), note that
   local-only is not safe either — `git reset` leaves the blob reachable through
   the reflog and as a dangling object until gc. Rotate, then rewrite with
   `git filter-repo` if it was ever pushed.

## Verification

Prove the hook actually blocks, in a throwaway repo:

```bash
d="$(mktemp -d)" && cd "$d" && git init -q .        # picks up init.templateDir
printf 'aws_key = %s%s\n' 'AKIA' 'IOSFODNN7EXAMPLE' > leak.txt
git add leak.txt
git -c user.email=t@example.invalid -c user.name=t commit -m t 2>&1 | tee out
git log --oneline 2>/dev/null | wc -l               # expect 0
grep -qiE 'finding|leaks found' out && echo "BLOCKED BY THE HOOK"
grep -qi 'not found'            out && echo "HOOK COULD NOT RUN - install gitleaks"
```

Pin the identity and check *why* it failed, because three different failures all
produce "no commit": an unconfigured `user.email` aborts on its own (exit 128), a
missing gitleaks binary makes the hook exit 127, and only the third is the hook
actually finding something. Each looks like protection from the outside.

The fake key is assembled from two halves at runtime on purpose. A document or
test fixture *about* secret scanning will trip secret scanners — including this
repo's own publish gate — so build fake values at runtime or allowlist the file.

## Related

- `pre-open-source-credential-audit` — the audit before making a repo public:
  full history, not just the tree. This skill is the gate on every commit; that
  one is the sweep before publishing.
- `secrets-in-agent-sessions` — the other leak vector: the transcript, tool
  output and permission allowlist, none of which are in git.
- `agent-credential-leak-surfaces` — where copies accumulate once a value has
  been exposed, and how to clean them.
