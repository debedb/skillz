# skillz — multi-skill catalog for Claude Code and Codex

A small, growing catalog of Claude Code / Codex skills, installable
individually, as named collections, or as a host-native plugin
bundle. Skills are plain `SKILL.md` files; bundles add plugin
manifests on top.

## Table of contents

- [Catalog](#catalog)
- [Layout](#layout)
- [Install — Claude Code plugin (recommended)](#install--claude-code-plugin-recommended)
- [Install — Codex plugin (recommended)](#install--codex-plugin-recommended)
- [Install — script (single skill / collection / all)](#install--script-single-skill--collection--all)
- [Migrating from `debedb/skillz`](#migrating-from-debedbskillz)
- [Catalog manifest](#catalog-manifest)
- [Updating](#updating)
- [Verify](#verify)
- [Collections](#collections)
  - [pr-loop](#pr-loop-collection)
- [Plugins](#plugins)
  - [codex-continuous-learning](#codex-continuous-learning-codex-only)
- [Validation](#validation)
- [Related code-review approaches](#related-code-review-approaches)

## Catalog

| Name | Type | Hosts | Purpose |
|---|---|---|---|
| [work-on-pr](./skills/work-on-pr/SKILL.md) | skill | Claude, Codex | Author-side PR iteration loop |
| [review-pr-loop](./skills/review-pr-loop/SKILL.md) | skill | Claude, Codex | Reviewer-side PR iteration loop |
| [continuous-learning](./skills/continuous-learning/SKILL.md) | skill | Codex | End-of-task retrospective: extract reusable, verified learnings as Codex skills |
| [pr-loop](./collections/pr-loop.json) | collection | Claude, Codex | Paired author + reviewer PR-loop skills |
| `skillz` plugin | plugin | Claude, Codex | Full repo packaged as Claude Code + Codex plugin |
| [`codex-continuous-learning` plugin](./plugins/codex-continuous-learning/) | plugin | Codex | continuous-learning skill plus UserPromptSubmit + Stop hooks |

Machine-readable index: [`catalog.json`](./catalog.json). The
installer and validation script both read from it, so new entries
land in the docs and tooling at the same time.

## Layout

```
catalog.json                       # machine-readable catalog index
collections/
  pr-loop.json                     # paired PR-loop collection
skills/
  work-on-pr/SKILL.md
  review-pr-loop/SKILL.md
  continuous-learning/SKILL.md     # canonical continuous-learning skill
.claude-plugin/
  marketplace.json                 # Claude Code marketplace manifest
  plugin.json                      # Claude Code plugin manifest
.codex-plugin/
  plugin.json                      # Codex whole-repo plugin manifest
plugins/
  codex-continuous-learning/       # standalone Codex bundle (skill + hooks)
    .codex-plugin/plugin.json
    skills/continuous-learning -> ../../../skills/continuous-learning
    hooks/
      hooks.json
      continuous_learning_prompt.py
      continuous_learning_stop.py
install.sh                         # catalog-driven installer
scripts/
  validate-catalog.sh              # CI/local catalog validation
README.md
```

This repo replaced gist `5f606018eb36a75dc292016268f08e7c`. The full
gist revision history was imported as the first 13 commits on
`master` and the gist now redirects here.

## Install — Claude Code plugin (recommended)

The plugin bundle installs every skill in the repo at once. From
inside Claude Code:

```text
/plugin marketplace add voitta-ai/skillz
/plugin install skillz@skillz
```

Skills load from the plugin's own `skills/` directory; no copy into
`~/.claude/skills/` is created. If you previously installed via
`install.sh --target claude`, remove the old copies to avoid
duplicates:

```bash
rm -rf ~/.claude/skills/work-on-pr ~/.claude/skills/review-pr-loop
```

## Install — Codex plugin (recommended)

Requires Codex CLI **0.117.0** or newer. Check with `codex --version`.

From inside Codex (`/plugins`), add this repo as a marketplace source
and install the `skillz` plugin. Or, from a clone, point Codex at the
repo root as a local marketplace folder.

Remove old direct-copy installs after switching:

```bash
rm -rf ~/.codex/skills/work-on-pr ~/.codex/skills/review-pr-loop
```

## Install — script (single skill / collection / all)

Use the script when you want a single skill or a single collection
without the plugin bundle, or when the plugin path is unavailable
(older Codex, locked Claude Code config, sandboxed environment).

```bash
# Default: install the pr-loop collection (work-on-pr + review-pr-loop)
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh)

# Single skill
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh) -- --skill work-on-pr

# Named collection
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh) -- --collection pr-loop

# Everything in the catalog
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh) -- --all

# Force a target host
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh) -- --target codex
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh) -- --target claude
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh) -- --target both

# Dry-run shows what would happen without writing anything
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh) -- --all --dry-run
```

`--skill` and `--collection` are repeatable. `--target` accepts
`auto` (default), `codex`, `claude`, or `both`. Override the
destination directly with `SKILLS_DEST_ROOT`. `CODEX_HOME` and
`CLAUDE_SKILLS_DIR` are honored.

From a clone:

```bash
git clone https://github.com/voitta-ai/skillz.git /tmp/skillz
/tmp/skillz/install.sh --target both --collection pr-loop
```

Backward compatibility: invoking `install.sh` with no selection
flags installs the `pr-loop` collection, matching the prior default.

## Migrating from `debedb/skillz`

This repo previously lived at
[`debedb/skillz`](https://github.com/debedb/skillz). It has moved
to [`voitta-ai/skillz`](https://github.com/voitta-ai/skillz).
GitHub redirects the old URL indefinitely (until the
`debedb/skillz` name is reused), so existing installs continue to
work without changes. The notes below cover the few cases where a
manual switch is worth doing.

**Script install (`install.sh`).** Re-run the curl one-liner
against the new raw URL — it overwrites in place, same skill paths,
no orphan files:

```bash
bash <(curl -sL https://raw.githubusercontent.com/voitta-ai/skillz/master/install.sh)
```

The old `debedb` URL still resolves via the GitHub redirect, so
nothing breaks if you keep using it; the new URL is just the
canonical one going forward.

**Claude Code plugin.** The redirect also covers `/plugin
marketplace add` / `/plugin update`, so existing installs keep
updating from the renamed repo automatically. To switch the
marketplace entry to the new owner explicitly:

```text
/plugin uninstall skillz@skillz
/plugin marketplace remove skillz
/plugin marketplace add voitta-ai/skillz
/plugin install skillz@skillz
```

**Codex plugin.** Same pattern — the marketplace source URL
redirects, so existing installs keep working. Re-add as
`voitta-ai/skillz` if you want the marketplace entry to reflect
the new owner.

This section will be removed once the rename has aged enough that
nobody is hitting the old URL anymore — see #22.

## Catalog manifest

[`catalog.json`](./catalog.json) is the single source of truth for
what the repo ships. It lists:

- Every skill (`name`, `path`, supported `hosts`, one-line summary).
- Every collection (`name`, member skill names, optional path to a
  per-collection JSON file).
- Plugin bundles (`name`, paths to host manifests).
- A default for the no-arg install (currently `pr-loop`).

`install.sh` parses this file at runtime. Adding a new skill is a
two-file change: drop in `skills/<name>/SKILL.md` and add an entry
under `skills` in `catalog.json`. No installer edits required.

## Updating

- **Claude Code plugin:** `/plugin update` (or `/plugin marketplace
  update skillz`) re-fetches `master` from this repo.
- **Codex plugin:** open `/plugins`, select `skillz`, run the update
  action.
- **Script:** re-run the curl one-liner, or `git pull && ./install.sh`
  from a clone.

## Verify

Plugin install (Claude Code):

```text
/plugin list
```

Plugin install (Codex):

```text
/plugins
```

Script install:

```bash
ls ~/.codex/skills/work-on-pr/SKILL.md   ~/.codex/skills/review-pr-loop/SKILL.md
ls ~/.claude/skills/work-on-pr/SKILL.md ~/.claude/skills/review-pr-loop/SKILL.md
```

Check only the host(s) you actually use.

## Collections

### pr-loop collection

Paired skills that drive the iterative back-and-forth of a GitHub
pull request review cycle. Install as one unit via:

```bash
./install.sh --collection pr-loop
```

The two skills:

- **work-on-pr** ([SKILL.md](./skills/work-on-pr/SKILL.md)):
  author-side loop. Watches for new review comments, issue comments,
  and inline threads; waits when feedback has not landed; addresses
  each in a worktree; runs tests; commits; pushes; replies with the
  commit SHA. Also accepts an issue reference and creates the PR if
  one does not yet exist (ensuring `Closes #<issue>` is in the body).
- **review-pr-loop** ([SKILL.md](./skills/review-pr-loop/SKILL.md)):
  reviewer-side loop. Each round re-reads the linked issue(s) and
  all prior reviews, issue comments, and inline threads before
  reviewing only the new diff or the author's latest response.
  Leaves structured feedback (REQUEST_CHANGES, COMMENT, APPROVE)
  and continues until approved, merged, or closed.

Each skill owns the watch loop. Every pass should surface which watch
mode is active:

- `watch-mode=durable`: a real `ScheduleWakeup`-style continuation
  was scheduled and survives turn end.
- `watch-mode=in-process-only`: no durable wake-up exists, so the
  current invocation must stay alive with `sleep` + re-poll.

Invoking before comments exist is expected, and an idle poll is not
completion. In-process polling only works while the current
invocation stays alive; a terminal/final handoff ends it.
`watch stopped:*` is only valid when the invocation is actually
ending, not on an ordinary idle pass.

Usage:

```text
/work-on-pr <N>        # author side (or pass an issue ref to start a PR)
/review-pr-loop <N>    # reviewer side
```

#### Reducing permission prompts (Claude Code)

The author-side loop pushes commits, posts comments, and replies to
review threads several rounds per PR. Without the right
`permissions.allow` patterns in `~/.claude/settings.json`, Claude
Code prompts for each write every round and the loop stalls.

The recommended allow block lives in
[`skills/work-on-pr/SKILL.md`](skills/work-on-pr/SKILL.md), under
"Auto-approved operations (self-PR workflow)". Two pitfalls worth
calling out up front:

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
  real `.py` file and invoke `python3 path/to/script.py` to make it
  analyzable, or accept the one-off prompt.

See `skills/work-on-pr/SKILL.md` → "Auto-approved operations" for
the full pattern list and the rationale behind every entry that is
intentionally NOT auto-approved (`git push origin master`,
`git push --force`, `gh repo delete`, etc.).

## Plugins

### codex-continuous-learning (Codex only)

A Codex-native counterpart of
[Claudeception](https://github.com/blader/Claudeception). Bundles the
[`continuous-learning`](./skills/continuous-learning/SKILL.md) skill
with two Codex hooks:

- **UserPromptSubmit** — injects a one-line reminder that any
  reusable, verified learning from this turn should be captured
  before exit.
- **Stop** — forces a brief end-of-task retrospective. The agent
  either invokes `continuous-learning` and acts on its output, or
  emits the literal line `No reusable learning.` and exits.

Design intent: capture only learnings that pass four retrospective
gates (real discovery cost, recurrence likelihood, verifiable
trigger, verified result). Most turns terminate with
`No reusable learning.` — that escape hatch is the point. See the
skill for the full policy and skill-shape requirements.

Layout:

```
plugins/codex-continuous-learning/
  .codex-plugin/plugin.json        # Codex plugin manifest
  skills/continuous-learning -> ../../../skills/continuous-learning
  hooks/
    hooks.json                     # UserPromptSubmit + Stop wiring
    continuous_learning_prompt.py  # UserPromptSubmit hook
    continuous_learning_stop.py    # Stop hook
```

The `skills/continuous-learning` directory inside the plugin is a
relative symlink to the canonical
[`skills/continuous-learning/`](./skills/continuous-learning/) at the
repo root, so the bundle stays a single source of truth.

Hook scripts are dependency-free Python (`python3` only, no
third-party imports, no filesystem writes, no network) and both fail
open via `on_error: ignore` in `hooks.json`. A hook crash never
breaks the user's session.

This bundle is **Codex-only** and not exposed via the Claude Code
plugin or the `pr-loop` collection. Claude Code users who want
similar end-of-task behavior should install Claudeception directly.

Install (when supported by the local Codex CLI):

```text
/plugins
# add this repo as a marketplace source, then install
# codex-continuous-learning
```

Or, from a clone, point Codex at `plugins/codex-continuous-learning/`
as a local plugin folder.

## Validation

```bash
./scripts/validate-catalog.sh
```

The script:

- Confirms every catalog-referenced skill path exists.
- Confirms every `SKILL.md` opens with YAML frontmatter containing
  `name:` and `description:`.
- Confirms every collection references only known skills.
- Confirms plugin-manifest paths declared in `catalog.json` exist.
- Runs `install.sh --dry-run` for the no-arg default,
  `--collection pr-loop`, `--skill work-on-pr`, and `--all`.

Run it before opening a PR that touches the catalog or installer.

## Related code-review approaches

The pr-loop collection operates at the **workflow** layer — when to
review, how often, what to compare against across rounds. Several
other projects address the **content** layer (what to say in a
single review) and are complementary, not competing. They can be
stacked: `review-pr-loop` driving the cycle while internally invoking
a formatter and/or an adversarial subagent per round.

| Feature | [caveman-review](https://github.com/JuliusBrussee/caveman) | [ce-adversarial-reviewer](https://github.com/EveryInc/compound-engineering-plugin) | [claudskills adversarial-review](https://claudskills.com/skills/adversarial-review/) | [voitta-ai/skillz review-pr-loop](./skills/review-pr-loop/SKILL.md) |
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
