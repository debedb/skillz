# PR iteration loop skills for Claude Code and Codex

## Table of contents

- [Overview](#overview)
- [Layout](#layout)
- [Install — Claude Code plugin (recommended)](#install--claude-code-plugin-recommended)
- [Install — Codex plugin (recommended)](#install--codex-plugin-recommended)
- [Install — legacy script](#install--legacy-script)
- [Updating](#updating)
- [Verify](#verify)
- [Usage](#usage)
- [Reducing permission prompts (Claude Code)](#reducing-permission-prompts-claude-code)
- [Related code-review approaches](#related-code-review-approaches)

## Overview

Two paired skills that drive the iterative back-and-forth of a GitHub
pull request review cycle:

- **work-on-pr**: author-side loop. Watch for new review comments,
  issue comments, and inline threads; wait when feedback has not
  landed yet; address each in a worktree; run tests; commit; push;
  post a reply with the commit SHA; then keep waiting.
- **review-pr-loop**: reviewer-side loop. Every round, re-read the
  linked issue(s) and all prior reviews, issue comments, and inline
  threads before reviewing only the new diff or the author's latest
  response.

The skill markdown is shared across both hosts. The recommended
install path on each host is its native plugin marketplace
(`/plugin` on Claude Code, `/plugins` on Codex). `install.sh` is
retained as a legacy fallback that copies skills into
`~/.codex/skills` and/or `~/.claude/skills` directly.

The plugin bundle and the legacy script install the same skills from
the same `skills/` directory at the top of `master`. The plugin
`version` field is pinned at `1.0.0` and not bumped per change — both
plugin hosts update by re-pulling `master`, so the version number is
cosmetic.

## Layout

```
.claude-plugin/
  marketplace.json   # Claude Code marketplace manifest
  plugin.json        # Claude Code plugin manifest
.codex-plugin/
  plugin.json        # Codex plugin manifest
skills/
  work-on-pr/SKILL.md
  review-pr-loop/SKILL.md
install.sh           # legacy direct-copy installer
README.md
```

This repo replaced gist `5f606018eb36a75dc292016268f08e7c`. The full
gist revision history was imported as the first 13 commits on
`master` and the gist now redirects here.

## Install — Claude Code plugin (recommended)

From inside Claude Code:

```text
/plugin marketplace add debedb/skillz
/plugin install skillz@skillz
```

Skills then load from the plugin's own `skills/` directory; no copy
into `~/.claude/skills/` is created or required. If you previously
installed via `install.sh --target claude`, delete the old copies to
avoid duplicates:

```bash
rm -rf ~/.claude/skills/work-on-pr ~/.claude/skills/review-pr-loop
```

## Install — Codex plugin (recommended)

Requires Codex CLI **0.117.0** or newer (plugin system shipped in
that release). Check with `codex --version`.

From inside Codex (`/plugins`), add the marketplace and install:

```text
/plugins
```

Then in the plugin browser, add `https://github.com/debedb/skillz`
as a marketplace source and install the `skillz` plugin. Or, from a
clone, install as a local marketplace folder pointing at the repo
root.

To remove old direct-copy installs after switching:

```bash
rm -rf ~/.codex/skills/work-on-pr ~/.codex/skills/review-pr-loop
```

## Install — legacy script

Use this only if you cannot use the plugin path (older Codex, locked
Claude Code config, sandboxed environment, etc.).

```bash
bash <(curl -sL https://raw.githubusercontent.com/debedb/skillz/master/install.sh)
```

By default, `install.sh` uses `--target auto`:

- installs to `~/.codex/skills` when Codex is configured or present
- installs to `~/.claude/skills` when Claude Code is configured or present
- installs to both default roots when neither home exists yet

Force a target explicitly:

```bash
bash <(curl -sL https://raw.githubusercontent.com/debedb/skillz/master/install.sh) -- --target codex
bash <(curl -sL https://raw.githubusercontent.com/debedb/skillz/master/install.sh) -- --target claude
bash <(curl -sL https://raw.githubusercontent.com/debedb/skillz/master/install.sh) -- --target both
```

Override the destination directly with `SKILLS_DEST_ROOT`.
`CODEX_HOME` and `CLAUDE_SKILLS_DIR` are both honored.

From a clone:

```bash
git clone https://github.com/debedb/skillz.git /tmp/skillz
cd /tmp/skillz
./install.sh --target both
```

## Updating

- **Claude Code plugin:** `/plugin update` (or `/plugin marketplace
  update skillz`) re-fetches `master` from this repo.
- **Codex plugin:** open `/plugins`, select `skillz`, run the update
  action; same effect.
- **Legacy script:** re-run the curl one-liner or `git pull && ./install.sh`.

## Verify

Plugin install (Claude Code):

```text
/plugin list
```

Plugin install (Codex):

```text
/plugins
```

Legacy install:

```bash
ls ~/.codex/skills/work-on-pr/SKILL.md ~/.codex/skills/review-pr-loop/SKILL.md
ls ~/.claude/skills/work-on-pr/SKILL.md ~/.claude/skills/review-pr-loop/SKILL.md
```

Check only the host(s) you actually use.

## Usage

Author side, after opening PR #N:

```text
/work-on-pr N
```

Reviewer side, on someone else's PR #N:

```text
/review-pr-loop N
```

Each skill owns the watch loop. If `ScheduleWakeup` is available, it
uses that between polls; otherwise it sleeps and re-polls in-process.
Invoking before comments exist is expected, and an idle poll is not
completion.

## Reducing permission prompts (Claude Code)

The author-side loop pushes commits, posts comments, and replies to
review threads several times per PR. Without the right
`permissions.allow` patterns in `~/.claude/settings.json`, Claude
Code will prompt for each of those writes every round and the loop
stalls waiting for you to click through.

The recommended allow block lives in
[`skills/work-on-pr/SKILL.md`](skills/work-on-pr/SKILL.md), under
"Auto-approved operations (self-PR workflow)". Copy it into your
`~/.claude/settings.json` before the first run.

Two pitfalls worth calling out up front:

- **Never chain `cd <worktree> && git ...`.** Claude Code matches
  each allow entry against the full command string. The compound
  starts with `cd`, so a pattern like
  `Bash(git push origin feature/*)` does not fire even though the
  second segment would match on its own. The host's Bash-tool docs
  say this explicitly: *"never prepend `cd <current-directory>` to
  a `git` command — the compound triggers a permission prompt."*
  Use `git -C <worktree-path> <subcommand>` instead, and add the
  matching `Bash(git -C * <subcommand>:*)` entries from the SKILL's
  allow block. The same rule applies to chains like
  `git -C X commit ... && git -C X push ...` — issue them as
  separate Bash tool calls, not a single `&&` string.
- **`python3 -c "<inline>"` does not auto-allow.** Read-only
  introspection like
  `cat ~/.claude/settings.json | python3 -c "<parse>"` still
  prompts because Claude Code (and the YOLT hook, where installed)
  treats an inline `-c` script as opaque. Pull the snippet into a
  real `.py` file and invoke `python3 path/to/script.py` to make
  it analyzable, or accept the one-off prompt.

See `skills/work-on-pr/SKILL.md` → "Auto-approved operations" for
the full pattern list and the rationale behind every entry that is
intentionally NOT auto-approved (`git push origin master`,
`git push --force`, `gh repo delete`, etc.).

## Related code-review approaches

The skills in this repo operate at the **workflow** layer — when to
review, how often, what to compare against across rounds. Several
other projects address the **content** layer (what to say in a single
review) and are complementary, not competing. They can be stacked:
`review-pr-loop` driving the cycle while internally invoking a
formatter and/or an adversarial subagent per round.

| Feature | [caveman-review](https://github.com/JuliusBrussee/caveman) | [ce-adversarial-reviewer](https://github.com/EveryInc/compound-engineering-plugin) | [claudskills adversarial-review](https://claudskills.com/skills/adversarial-review/) | [debedb/skillz review-pr-loop](./skills/review-pr-loop/SKILL.md) |
|---|---|---|---|---|
| Type | Skill | Agent (subagent) | Skill | Skill (paired with [work-on-pr](./skills/work-on-pr/SKILL.md)) |
| Job | Compress review prose | Chaos-engineer failure scenarios | PASS/FAIL adversarial verdict | Drive multi-round PR review *loop* |
| Adversarial methodology | No (format only) | Yes (4 techniques) | Yes (claimed) | No — orchestration, not methodology |
| Verdict | None | Advisory findings | Binary PASS/FAIL | REQUEST_CHANGES / COMMENT / APPROVE |
| Confidence calibration | No | Anchored 100/75/50/25 | Anchoring-bias prevention | N/A |
| Scope discipline | Reviews only | Defers to 8 siblings | Standalone | Owns whole review *cycle* |
| Single-shot vs iterative | Single | Single | Single | Iterative — re-reads issue, prior threads, only-new-diff each round |
| Output | PR-paste comments | Structured JSON | Unknown | GitHub PR review (via `gh`) + commit replies |
| State across rounds | None | None | None | Yes — tracks addressed vs new, waits when quiet |
| Conditional trigger | Manual | Auto (size / risk) | Manual | Manual (`/review-pr-loop N`) |
| Exit conditions | N/A (one-shot) | N/A | N/A | Approve, merge, close, user stop |
| Polling discipline | N/A | N/A | N/A | Paced against prompt-cache TTL, `ScheduleWakeup`-aware |
| Host targets | Claude Code | Claude Code | Claude Code (+ Pro app) | Claude Code + Codex |
| Orchestration | Standalone | Part of `/ce-code-review` fleet | Standalone | Paired with `work-on-pr` (author side) |

See also: [claudskills](https://claudskills.com/) registry,
[Anthropic Claude Code skills docs](https://docs.claude.com/en/docs/claude-code/skills.md),
[vercel-labs/skills](https://github.com/vercel-labs/skills) (upstream
profile catalog used by `npx skills add`).
