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
| [cmux-search](./skills/cmux-search/SKILL.md) | skill | Claude, Codex | Search all open cmux workspaces/tabs/panes - live scrollback + agent transcripts |
| [cmux-agent-tabs](./skills/cmux-agent-tabs/SKILL.md) | skill | Claude, Codex | Make AI agents show as watchable cmux tabs; Claude needs the `claude-teams` wrapper, Codex via `codex-teams`/hooks |
| [gh-git-heredoc-body-file](./skills/gh-git-heredoc-body-file/SKILL.md) | skill | Claude, Codex | Body-file pattern: stop gh/git mangling multi-line bodies (backticks, code fences, `$(...)`) |
| [claude-code-static-allow-bypasses-hook](./skills/claude-code-static-allow-bypasses-hook/SKILL.md) | skill | Claude, Codex | Why a Claude Code PreToolUse hook never fires for some commands (static allow short-circuits it) |
| [python-ast-static-analyzer-scoping](./skills/python-ast-static-analyzer-scoping/SKILL.md) | skill | Claude, Codex | Build a Python `ast` analyzer: import-alias resolution + load-time vs deferred scoping |
| [wordpress-com-publish](./skills/wordpress-com-publish/SKILL.md) | skill | Claude, Codex | Acquire a WordPress.com OAuth2 token (authorization-code flow) and publish/update posts |
| [git-add-u-rename-pitfall](./skills/git-add-u-rename-pitfall/SKILL.md) | skill | Claude, Codex | `git add -u` can miss a rename (old path staged as deleted); stage the new path |
| [git-branch-cleanup-script-races](./skills/git-branch-cleanup-script-races/SKILL.md) | skill | Claude, Codex | Branch-cleanup scripts race concurrent ref updates; snapshot refs first |
| [git-graft-worktree-onto-remote](./skills/git-graft-worktree-onto-remote/SKILL.md) | skill | Claude, Codex | Graft a local worktree's commits onto a remote branch without re-cloning |
| [multi-phase-feature-pr-worktrees](./skills/multi-phase-feature-pr-worktrees/SKILL.md) | skill | Claude, Codex | Run a multi-phase feature as stacked worktree PRs, each reviewed independently |
| [gist-to-repo-migration](./skills/gist-to-repo-migration/SKILL.md) | skill | Claude, Codex | Migrate a gist's full revision history into a real git repo |
| [vercel-token-deploy-branch-domains](./skills/vercel-token-deploy-branch-domains/SKILL.md) | skill | Claude, Codex | Token-only per-branch Vercel deploys to fixed custom domains; gitBranch domain pin; preview SSO 401 |
| [s3-presigned-upload-fails-nonexistent-bucket](./skills/s3-presigned-upload-fails-nonexistent-bucket/SKILL.md) | skill | Claude, Codex | Presigned S3 upload fails on wrong/missing bucket; HeadBucket 404-vs-403; CloudFront origin reveals real bucket |
| [neon-vercel-db-identify-and-migrate](./skills/neon-vercel-db-identify-and-migrate/SKILL.md) | skill | Claude, Codex | Identify which Neon project backs a Vercel app and migrate/split it; safe non-destructive cutover |
| [gh-api-f-vs-F-body-file](./skills/gh-api-f-vs-F-body-file/SKILL.md) | skill | Claude, Codex | `gh api -F` reads `@file`; `-f` sends it as a literal string |
| [gh-api-jq-no-arg](./skills/gh-api-jq-no-arg/SKILL.md) | skill | Claude, Codex | `gh api --jq` needs its filter as the arg; a misplaced/empty `--jq` drops it |
| [gh-fork-issues-disabled](./skills/gh-fork-issues-disabled/SKILL.md) | skill | Claude, Codex | `gh issue create` fails on a fork (Issues tab disabled by default) |
| [gh-pr-graphql-401-rest-fallback](./skills/gh-pr-graphql-401-rest-fallback/SKILL.md) | skill | Claude, Codex | gh PR GraphQL 401 -> fall back to the REST PR endpoints |
| [gh-pr-merge-delete-branch-closes-dependent-pr](./skills/gh-pr-merge-delete-branch-closes-dependent-pr/SKILL.md) | skill | Claude, Codex | Deleting the branch on `gh pr merge` can auto-close a dependent stacked PR |
| [gh-workflow-run-matching](./skills/gh-workflow-run-matching/SKILL.md) | skill | Claude, Codex | Match a `gh` workflow run to its trigger when runs share a name |
| [github-api-list-endpoint-staleness-fresh-pr](./skills/github-api-list-endpoint-staleness-fresh-pr/SKILL.md) | skill | Claude, Codex | GitHub list endpoints serve stale `[]` on a fresh PR; use the timeline endpoint |
| [github-closing-keywords-default-branch-only](./skills/github-closing-keywords-default-branch-only/SKILL.md) | skill | Claude, Codex | `Closes #N` only auto-closes when the PR merges into the default branch |
| [github-private-repo-readme-image-rendering](./skills/github-private-repo-readme-image-rendering/SKILL.md) | skill | Claude, Codex | Private-repo README images need authenticated/relative paths to render |
| [claudeception](./skills/claudeception/SKILL.md) | skill | Claude | Continuous-learning meta-skill: procedures become catalog skills via PR; specifics go to memory (local or shared vault) |
| [claude-code-claudemd-symlink-write-refused](./skills/claude-code-claudemd-symlink-write-refused/SKILL.md) | skill | Claude, Codex | Fix Edit/Write "Refusing to write through symlink" on `~/.claude/CLAUDE.md` by resolving to the real target |
| [claude-code-codex-plugin-parity](./skills/claude-code-codex-plugin-parity/SKILL.md) | skill | Claude, Codex | Port a Claude Code plugin to the Codex CLI (or back); where the two systems match vs diverge |
| [claude-code-piebald-lsp-binary-on-path](./skills/claude-code-piebald-lsp-binary-on-path/SKILL.md) | skill | Claude, Codex | Piebald LSP plugins surface the LSP tool but the language-server binary isn't on PATH |
| [claude-code-plugin-from-existing-repo](./skills/claude-code-plugin-from-existing-repo/SKILL.md) | skill | Claude, Codex | Convert a repo that ships CC commands/hooks (manual copy-in) into an installable plugin |
| [claude-code-plugin-python-bootstrap](./skills/claude-code-plugin-python-bootstrap/SKILL.md) | skill | Claude, Codex | Bootstrap Python deps from a CC plugin hook so `/plugin install` is one-click (PEP 668-safe) |
| [claude-code-plugin-update-flow](./skills/claude-code-plugin-update-flow/SKILL.md) | skill | Claude, Codex | Update a CC plugin via `/plugin marketplace update` + `/reload-plugins`, not the picker `/plugin update` |
| [claude-json-mcp-migration-slice](./skills/claude-json-mcp-migration-slice/SKILL.md) | skill | Claude, Codex | The exact `~/.claude.json` slice that carries MCP config for migration vs session bookkeeping |
| [macos-bash-3.2-compat](./skills/macos-bash-3.2-compat/SKILL.md) | skill | Claude, Codex | Fix bash scripts that fail on macOS's stock bash 3.2 (`declare -A`, `mapfile`, other bash-4-only constructs) |
| [emacs-batch-package-verify-pitfalls](./skills/emacs-batch-package-verify-pitfalls/SKILL.md) | skill | Claude, Codex | Avoid false negatives when verifying an Emacs package with `emacs --batch` (no ELPA auto-activation; `use-package` defers `:config`) |
| [python-symtable-no-col-offset-pairing](./skills/python-symtable-no-col-offset-pairing/SKILL.md) | skill | Claude, Codex | Pair Python `symtable` scopes with AST nodes when symtable has no `col_offset`, via (lineno, name) grouping |
| [`skillz` plugin](./plugins/skillz/) | plugin | Claude, Codex | Full repo bundle: every skill |
| [`pr-loop` plugin](./plugins/pr-loop/) | plugin | Claude, Codex | Paired author + reviewer PR-loop skills |
| [`work-on-pr` plugin](./plugins/work-on-pr/) | plugin | Claude, Codex | Single-skill plugin: work-on-pr |
| [`review-pr-loop` plugin](./plugins/review-pr-loop/) | plugin | Claude, Codex | Single-skill plugin: review-pr-loop |
| [`cmux-search` plugin](./plugins/cmux-search/) | plugin | Claude, Codex | Single-skill plugin: search all open cmux panes |
| [`cmux-agent-tabs` plugin](./plugins/cmux-agent-tabs/) | plugin | Claude, Codex | Single-skill plugin: cmux-agent-tabs |
| [`gh-git-heredoc-body-file` plugin](./plugins/gh-git-heredoc-body-file/) | plugin | Claude, Codex | Single-skill plugin: gh-git-heredoc-body-file |
| [`claude-code-static-allow-bypasses-hook` plugin](./plugins/claude-code-static-allow-bypasses-hook/) | plugin | Claude, Codex | Single-skill plugin: claude-code-static-allow-bypasses-hook |
| [`python-ast-static-analyzer-scoping` plugin](./plugins/python-ast-static-analyzer-scoping/) | plugin | Claude, Codex | Single-skill plugin: python-ast-static-analyzer-scoping |
| [`wordpress-com-publish` plugin](./plugins/wordpress-com-publish/) | plugin | Claude, Codex | Single-skill plugin: WordPress.com token + publish |
| [`git-add-u-rename-pitfall` plugin](./plugins/git-add-u-rename-pitfall/) | plugin | Claude, Codex | Single-skill plugin: git-add-u-rename-pitfall |
| [`git-branch-cleanup-script-races` plugin](./plugins/git-branch-cleanup-script-races/) | plugin | Claude, Codex | Single-skill plugin: git-branch-cleanup-script-races |
| [`git-graft-worktree-onto-remote` plugin](./plugins/git-graft-worktree-onto-remote/) | plugin | Claude, Codex | Single-skill plugin: git-graft-worktree-onto-remote |
| [`multi-phase-feature-pr-worktrees` plugin](./plugins/multi-phase-feature-pr-worktrees/) | plugin | Claude, Codex | Single-skill plugin: multi-phase-feature-pr-worktrees |
| [`gist-to-repo-migration` plugin](./plugins/gist-to-repo-migration/) | plugin | Claude, Codex | Single-skill plugin: gist-to-repo-migration |
| [`vercel-token-deploy-branch-domains` plugin](./plugins/vercel-token-deploy-branch-domains/) | plugin | Claude, Codex | Single-skill plugin: vercel-token-deploy-branch-domains |
| [`s3-presigned-upload-fails-nonexistent-bucket` plugin](./plugins/s3-presigned-upload-fails-nonexistent-bucket/) | plugin | Claude, Codex | Single-skill plugin: s3-presigned-upload-fails-nonexistent-bucket |
| [`neon-vercel-db-identify-and-migrate` plugin](./plugins/neon-vercel-db-identify-and-migrate/) | plugin | Claude, Codex | Single-skill plugin: neon-vercel-db-identify-and-migrate |
| [`gh-api-f-vs-F-body-file` plugin](./plugins/gh-api-f-vs-F-body-file/) | plugin | Claude, Codex | Single-skill plugin: gh-api-f-vs-F-body-file |
| [`gh-api-jq-no-arg` plugin](./plugins/gh-api-jq-no-arg/) | plugin | Claude, Codex | Single-skill plugin: gh-api-jq-no-arg |
| [`gh-fork-issues-disabled` plugin](./plugins/gh-fork-issues-disabled/) | plugin | Claude, Codex | Single-skill plugin: gh-fork-issues-disabled |
| [`gh-pr-graphql-401-rest-fallback` plugin](./plugins/gh-pr-graphql-401-rest-fallback/) | plugin | Claude, Codex | Single-skill plugin: gh-pr-graphql-401-rest-fallback |
| [`gh-pr-merge-delete-branch-closes-dependent-pr` plugin](./plugins/gh-pr-merge-delete-branch-closes-dependent-pr/) | plugin | Claude, Codex | Single-skill plugin: gh-pr-merge-delete-branch-closes-dependent-pr |
| [`gh-workflow-run-matching` plugin](./plugins/gh-workflow-run-matching/) | plugin | Claude, Codex | Single-skill plugin: gh-workflow-run-matching |
| [`github-api-list-endpoint-staleness-fresh-pr` plugin](./plugins/github-api-list-endpoint-staleness-fresh-pr/) | plugin | Claude, Codex | Single-skill plugin: github-api-list-endpoint-staleness-fresh-pr |
| [`github-closing-keywords-default-branch-only` plugin](./plugins/github-closing-keywords-default-branch-only/) | plugin | Claude, Codex | Single-skill plugin: github-closing-keywords-default-branch-only |
| [`github-private-repo-readme-image-rendering` plugin](./plugins/github-private-repo-readme-image-rendering/) | plugin | Claude, Codex | Single-skill plugin: github-private-repo-readme-image-rendering |
| [`claude-code-claudemd-symlink-write-refused` plugin](./plugins/claude-code-claudemd-symlink-write-refused/) | plugin | Claude, Codex | Single-skill plugin: claude-code-claudemd-symlink-write-refused |
| [`claude-code-codex-plugin-parity` plugin](./plugins/claude-code-codex-plugin-parity/) | plugin | Claude, Codex | Single-skill plugin: claude-code-codex-plugin-parity |
| [`claude-code-piebald-lsp-binary-on-path` plugin](./plugins/claude-code-piebald-lsp-binary-on-path/) | plugin | Claude, Codex | Single-skill plugin: claude-code-piebald-lsp-binary-on-path |
| [`claude-code-plugin-from-existing-repo` plugin](./plugins/claude-code-plugin-from-existing-repo/) | plugin | Claude, Codex | Single-skill plugin: claude-code-plugin-from-existing-repo |
| [`claude-code-plugin-python-bootstrap` plugin](./plugins/claude-code-plugin-python-bootstrap/) | plugin | Claude, Codex | Single-skill plugin: claude-code-plugin-python-bootstrap |
| [`claude-code-plugin-update-flow` plugin](./plugins/claude-code-plugin-update-flow/) | plugin | Claude, Codex | Single-skill plugin: claude-code-plugin-update-flow |
| [`claude-json-mcp-migration-slice` plugin](./plugins/claude-json-mcp-migration-slice/) | plugin | Claude, Codex | Single-skill plugin: claude-json-mcp-migration-slice |
| [`macos-bash-3.2-compat` plugin](./plugins/macos-bash-3.2-compat/) | plugin | Claude, Codex | Single-skill plugin: macos-bash-3.2-compat |
| [`emacs-batch-package-verify-pitfalls` plugin](./plugins/emacs-batch-package-verify-pitfalls/) | plugin | Claude, Codex | Single-skill plugin: emacs-batch-package-verify-pitfalls |
| [`python-symtable-no-col-offset-pairing` plugin](./plugins/python-symtable-no-col-offset-pairing/) | plugin | Claude, Codex | Single-skill plugin: python-symtable-no-col-offset-pairing |
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
  cmux-search/SKILL.md
  gh-git-heredoc-body-file/SKILL.md
  claude-code-static-allow-bypasses-hook/SKILL.md
  python-ast-static-analyzer-scoping/SKILL.md
  wordpress-com-publish/SKILL.md
  git-add-u-rename-pitfall/SKILL.md
  git-branch-cleanup-script-races/SKILL.md
  git-graft-worktree-onto-remote/SKILL.md
  multi-phase-feature-pr-worktrees/SKILL.md
  gist-to-repo-migration/SKILL.md
  vercel-token-deploy-branch-domains/SKILL.md
  s3-presigned-upload-fails-nonexistent-bucket/SKILL.md
  neon-vercel-db-identify-and-migrate/SKILL.md
  gh-api-f-vs-F-body-file/SKILL.md
  gh-api-jq-no-arg/SKILL.md
  gh-fork-issues-disabled/SKILL.md
  gh-pr-graphql-401-rest-fallback/SKILL.md
  gh-pr-merge-delete-branch-closes-dependent-pr/SKILL.md
  gh-workflow-run-matching/SKILL.md
  github-api-list-endpoint-staleness-fresh-pr/SKILL.md
  github-closing-keywords-default-branch-only/SKILL.md
  github-private-repo-readme-image-rendering/SKILL.md
  claude-code-claudemd-symlink-write-refused/SKILL.md
  claude-code-codex-plugin-parity/SKILL.md
  claude-code-piebald-lsp-binary-on-path/SKILL.md
  claude-code-plugin-from-existing-repo/SKILL.md
  claude-code-plugin-python-bootstrap/SKILL.md
  claude-code-plugin-update-flow/SKILL.md
  claude-json-mcp-migration-slice/SKILL.md
  macos-bash-3.2-compat/SKILL.md
  emacs-batch-package-verify-pitfalls/SKILL.md
  python-symtable-no-col-offset-pairing/SKILL.md
.claude-plugin/
  marketplace.json                 # Claude Code marketplace (lists all plugin entries)
.codex-plugin/
  marketplace.json                 # Codex marketplace (lists all plugin entries)
plugins/                           # per-plugin manifests + skill symlinks
  skillz/                          # full bundle (per-host skill dirs)
    .claude-plugin/plugin.json     # "skills": "./skills-claude/"
    .codex-plugin/plugin.json      # "skills": "./skills-codex/"
    skills-claude/                 # every claude-hosted skill (excludes continuous-learning, codex-only)
      work-on-pr -> ../../../skills/work-on-pr
      claudeception -> ../../../skills/claudeception
      ...                          # symlink per claude-hosted catalog skill
    skills-codex/                  # every codex-hosted skill (excludes claudeception, claude-only)
      work-on-pr -> ../../../skills/work-on-pr
      continuous-learning -> ../../../skills/continuous-learning
      ...                          # symlink per codex-hosted catalog skill
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
  cmux-search/                     # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/cmux-search -> ../../../skills/cmux-search
  gh-git-heredoc-body-file/        # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/gh-git-heredoc-body-file -> ../../../skills/gh-git-heredoc-body-file
  claude-code-static-allow-bypasses-hook/   # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/claude-code-static-allow-bypasses-hook -> ../../../skills/claude-code-static-allow-bypasses-hook
  python-ast-static-analyzer-scoping/       # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/python-ast-static-analyzer-scoping -> ../../../skills/python-ast-static-analyzer-scoping
  wordpress-com-publish/           # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/wordpress-com-publish -> ../../../skills/wordpress-com-publish
  git-add-u-rename-pitfall/        # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/git-add-u-rename-pitfall -> ../../../skills/git-add-u-rename-pitfall
  git-branch-cleanup-script-races/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/git-branch-cleanup-script-races -> ../../../skills/git-branch-cleanup-script-races
  git-graft-worktree-onto-remote/  # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/git-graft-worktree-onto-remote -> ../../../skills/git-graft-worktree-onto-remote
  multi-phase-feature-pr-worktrees/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/multi-phase-feature-pr-worktrees -> ../../../skills/multi-phase-feature-pr-worktrees
  gist-to-repo-migration/          # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/gist-to-repo-migration -> ../../../skills/gist-to-repo-migration
  vercel-token-deploy-branch-domains/       # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/vercel-token-deploy-branch-domains -> ../../../skills/vercel-token-deploy-branch-domains
  s3-presigned-upload-fails-nonexistent-bucket/  # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/s3-presigned-upload-fails-nonexistent-bucket -> ../../../skills/s3-presigned-upload-fails-nonexistent-bucket
  neon-vercel-db-identify-and-migrate/      # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/neon-vercel-db-identify-and-migrate -> ../../../skills/neon-vercel-db-identify-and-migrate
  gh-api-f-vs-F-body-file/         # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/gh-api-f-vs-F-body-file -> ../../../skills/gh-api-f-vs-F-body-file
  gh-api-jq-no-arg/                # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/gh-api-jq-no-arg -> ../../../skills/gh-api-jq-no-arg
  gh-fork-issues-disabled/         # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/gh-fork-issues-disabled -> ../../../skills/gh-fork-issues-disabled
  gh-pr-graphql-401-rest-fallback/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/gh-pr-graphql-401-rest-fallback -> ../../../skills/gh-pr-graphql-401-rest-fallback
  gh-pr-merge-delete-branch-closes-dependent-pr/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/gh-pr-merge-delete-branch-closes-dependent-pr -> ../../../skills/gh-pr-merge-delete-branch-closes-dependent-pr
  gh-workflow-run-matching/        # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/gh-workflow-run-matching -> ../../../skills/gh-workflow-run-matching
  github-api-list-endpoint-staleness-fresh-pr/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/github-api-list-endpoint-staleness-fresh-pr -> ../../../skills/github-api-list-endpoint-staleness-fresh-pr
  github-closing-keywords-default-branch-only/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/github-closing-keywords-default-branch-only -> ../../../skills/github-closing-keywords-default-branch-only
  github-private-repo-readme-image-rendering/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/github-private-repo-readme-image-rendering -> ../../../skills/github-private-repo-readme-image-rendering
  claude-code-claudemd-symlink-write-refused/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/claude-code-claudemd-symlink-write-refused -> ../../../skills/claude-code-claudemd-symlink-write-refused
  claude-code-codex-plugin-parity/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/claude-code-codex-plugin-parity -> ../../../skills/claude-code-codex-plugin-parity
  claude-code-piebald-lsp-binary-on-path/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/claude-code-piebald-lsp-binary-on-path -> ../../../skills/claude-code-piebald-lsp-binary-on-path
  claude-code-plugin-from-existing-repo/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/claude-code-plugin-from-existing-repo -> ../../../skills/claude-code-plugin-from-existing-repo
  claude-code-plugin-python-bootstrap/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/claude-code-plugin-python-bootstrap -> ../../../skills/claude-code-plugin-python-bootstrap
  claude-code-plugin-update-flow/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/claude-code-plugin-update-flow -> ../../../skills/claude-code-plugin-update-flow
  claude-json-mcp-migration-slice/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/claude-json-mcp-migration-slice -> ../../../skills/claude-json-mcp-migration-slice
  macos-bash-3.2-compat/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/macos-bash-3.2-compat -> ../../../skills/macos-bash-3.2-compat
  emacs-batch-package-verify-pitfalls/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/emacs-batch-package-verify-pitfalls -> ../../../skills/emacs-batch-package-verify-pitfalls
  python-symtable-no-col-offset-pairing/ # single-skill plugin
    .claude-plugin/plugin.json
    .codex-plugin/plugin.json
    skills/python-symtable-no-col-offset-pairing -> ../../../skills/python-symtable-no-col-offset-pairing
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

From any shell, add this repo as a Codex marketplace:

```bash
codex plugin marketplace add voitta-ai/skillz
```

Then open Codex's plugin browser and install whichever plugin entry
you want from the `skillz` marketplace — same set as Claude Code,
plus two Codex-only entries:

```text
/plugins
```

- `skillz` — full bundle (host-aware: the Claude manifest loads
  `skills-claude/`, the Codex manifest loads `skills-codex/`, so a
  claude-only skill like `claudeception` never lands in a Codex
  install and a codex-only skill like `continuous-learning` never
  lands in a Claude install)
- `pr-loop` — work-on-pr + review-pr-loop
- `work-on-pr` — single skill
- `review-pr-loop` — single skill
- `continuous-learning` — single skill, no hooks
- `codex-continuous-learning` — skill + UserPromptSubmit/Stop hooks

From a local checkout, point Codex at the repo root instead:

```bash
codex plugin marketplace add /absolute/path/to/skillz
```

If you add a local checkout, keep that checkout up to date yourself
with `git pull` in the clone.

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
redirects, so existing installs keep working. To switch the
configured marketplace entry to the new owner explicitly:

```bash
codex plugin marketplace remove skillz
codex plugin marketplace add voitta-ai/skillz
```

Then reopen `/plugins`, select the `skillz` marketplace, and
reinstall or update the same plugin entry you were already using.

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
- **Codex plugin (GitHub marketplace source):** open `/plugins`,
  select `skillz`, run the update action.
- **Codex plugin (local checkout source):** `git pull` inside the
  checkout you added, then reopen `/plugins` if needed.
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
