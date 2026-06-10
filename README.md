# skillz — multi-skill catalog for Claude Code and Codex

A small, growing catalog of Claude Code / Codex skills, exposed as
individual plugins and a full-bundle plugin via the host's native
`/plugin install` flow. Skills are plain `SKILL.md` files; each
plugin entry adds a thin manifest plus a `skills/` directory of
symlinks back to the canonical `skills/<name>/`. A legacy
`install.sh` script remains available as a fallback for sandboxed
environments and older Codex versions.

## Table of contents

- [Catalog](#catalog)
- [Layout](#layout)
- [Install — Claude Code plugin (recommended)](#install--claude-code-plugin-recommended)
- [Install — Codex plugin (recommended)](#install--codex-plugin-recommended)
- [Install — script (legacy / fallback)](#install--script-legacy--fallback)
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
- [PR review workflow stack](#pr-review-workflow-stack)

## Catalog

| Name | Type | Hosts | Purpose |
|---|---|---|---|
| [work-on-pr](./skills/work-on-pr/SKILL.md) | skill | Claude, Codex | Author-side PR iteration loop |
| [review-pr-loop](./skills/review-pr-loop/SKILL.md) | skill | Claude, Codex | Reviewer-side PR iteration loop |
| [continuous-learning](./skills/continuous-learning/SKILL.md) | skill | Codex | End-of-task retrospective: extract reusable, verified learnings as Codex skills |
| [`skillz` plugin](./plugins/skillz/) | plugin | Claude, Codex | Full repo bundle: every skill |
| [`pr-loop` plugin](./plugins/pr-loop/) | plugin | Claude, Codex | Paired author + reviewer PR-loop skills |
| [`work-on-pr` plugin](./plugins/work-on-pr/) | plugin | Claude, Codex | Single-skill plugin: work-on-pr |
| [`review-pr-loop` plugin](./plugins/review-pr-loop/) | plugin | Claude, Codex | Single-skill plugin: review-pr-loop |
| [`continuous-learning` plugin](./plugins/continuous-learning/) | plugin | Codex | Single-skill plugin (no hooks) |
| [`codex-continuous-learning` plugin](./plugins/codex-continuous-learning/) | plugin | Codex | continuous-learning skill plus UserPromptSubmit + Stop hooks |
| [pr-loop](./collections/pr-loop.json) | collection (legacy) | Claude, Codex | `install.sh` selector. Prefer the `pr-loop` plugin entry. |

Machine-readable index: [`catalog.json`](./catalog.json). The
installer and validation script both read from it, so new entries
land in the docs and tooling at the same time.

## Layout

```
catalog.json                       # machine-readable catalog index
collections/
  pr-loop.json                     # legacy install.sh selector (kept for backcompat)
skills/                            # canonical skill content
  work-on-pr/SKILL.md
  review-pr-loop/SKILL.md
  continuous-learning/SKILL.md
.claude-plugin/
  marketplace.json                 # Claude Code marketplace (lists all plugin entries)
.codex-plugin/
  marketplace.json                 # Codex marketplace (lists all plugin entries)
plugins/                           # per-plugin manifests + skill symlinks
  skillz/                          # full bundle
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/
      work-on-pr -> ../../../skills/work-on-pr
      review-pr-loop -> ../../../skills/review-pr-loop
      continuous-learning -> ../../../skills/continuous-learning
  pr-loop/                         # work-on-pr + review-pr-loop only
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/
      work-on-pr -> ../../../skills/work-on-pr
      review-pr-loop -> ../../../skills/review-pr-loop
  work-on-pr/                      # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/work-on-pr -> ../../../skills/work-on-pr
  review-pr-loop/                  # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/review-pr-loop -> ../../../skills/review-pr-loop
  continuous-learning/             # Codex-only single-skill plugin (no hooks)
    .codex-plugin/plugin.json
    skills/continuous-learning -> ../../../skills/continuous-learning
  codex-continuous-learning/       # Codex skill + hooks bundle
    .codex-plugin/plugin.json
    skills/continuous-learning -> ../../../skills/continuous-learning
    hooks/
      hooks.json
      continuous_learning_prompt.py
      continuous_learning_stop.py
install.sh                         # catalog-driven installer (legacy / fallback)
scripts/
  validate-catalog.sh              # CI/local catalog validation
README.md
```

Each `plugins/<name>/skills/<skill>` is a symlink back to the
canonical `skills/<skill>/`, so every plugin reads from a single
source of truth. The root `.claude-plugin/marketplace.json` and
`.codex-plugin/marketplace.json` enumerate every plugin entry so
hosts can offer them individually in `/plugin install`.

This repo replaced gist `5f606018eb36a75dc292016268f08e7c`. The full
gist revision history was imported as the first 13 commits on
`master` and the gist now redirects here.

## Install — Claude Code plugin (recommended)

The marketplace exposes every plugin entry individually, so you can
install exactly the subset you want. From inside Claude Code:

```text
/plugin marketplace add voitta-ai/skillz

# Full bundle (every skill):
/plugin install skillz@skillz

# Author + reviewer PR-loop pair:
/plugin install pr-loop@skillz

# Single-skill plugins:
/plugin install work-on-pr@skillz
/plugin install review-pr-loop@skillz
```

Each plugin's `skills/` directory is a set of symlinks back to
`skills/<name>/`, so installing one plugin does not duplicate skill
content on disk.

If you previously installed via `install.sh --target claude`,
remove the old copies to avoid duplicates:

```bash
rm -rf ~/.claude/skills/work-on-pr ~/.claude/skills/review-pr-loop
```

## Install — Codex plugin (recommended)

Requires Codex CLI **0.117.0** or newer. Check with `codex --version`.

From inside Codex (`/plugins`), add this repo as a marketplace source
and install whichever plugin entry you want — same set as Claude
Code, plus two Codex-only entries:

- `skillz` — full bundle
- `pr-loop` — work-on-pr + review-pr-loop
- `work-on-pr` — single skill
- `review-pr-loop` — single skill
- `continuous-learning` — single skill, no hooks
- `codex-continuous-learning` — skill + UserPromptSubmit/Stop hooks

Or, from a clone, point Codex at the repo root as a local
marketplace folder.

Remove old direct-copy installs after switching:

```bash
rm -rf ~/.codex/skills/work-on-pr ~/.codex/skills/review-pr-loop
```

## Install — script (legacy / fallback)

`install.sh` predates the per-plugin marketplace entries above. Use
it when the plugin path is unavailable (older Codex, locked Claude
Code config, sandboxed environment) or when you want to drop skills
directly into `~/.claude/skills/` / `~/.codex/skills/` without going
through `/plugin`.

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

## Collections (legacy)

Collections are an `install.sh`-only concept; Claude Code and Codex
do not have a native notion of "collection." New work should use
the equivalent **plugin** entries (e.g. install `pr-loop@skillz` via
`/plugin install`). Collections remain documented here for users
still on the script install path.

### pr-loop collection

Paired skills that drive the iterative back-and-forth of a GitHub
pull request review cycle. Install as one unit via:

```bash
./install.sh --collection pr-loop
```

The same pairing is also available as the `pr-loop` plugin entry —
`/plugin install pr-loop@skillz` is the preferred path on Claude
Code and on Codex CLI ≥ 0.117.

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

## PR review workflow stack

The skills here are the **workflow** layer. They compose with
subagents, Agent Teams, and the Agent SDK rather than competing with
them. [`docs/pr-review-workflow.md`](./docs/pr-review-workflow.md)
writes that down: which layer does which job, the rule that subagents
cannot spawn subagents (so `review-pr-loop` must run in the main
session when it delegates a specialist sweep), how to use PR Review
Toolkit agents as advisory-only subagents, when an Agent Team is worth
the overhead, the SDK boundary, and the same-identity reviewer caveat.
