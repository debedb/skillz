---
name: claude-code-codex-plugin-parity
description: |
  Port a Claude Code plugin to the OpenAI Codex CLI (or vice versa), and
  understand where the two plugin systems are identical vs where they diverge.
  Use when: (1) you have a Claude Code plugin (.claude-plugin/plugin.json +
  marketplace.json + hooks/hooks.json) and want it to also work under Codex
  CLI, (2) you are writing a .codex-plugin/plugin.json and wonder if you can
  reuse the existing hooks.json, (3) a ported plugin installs under Codex but
  its hooks misbehave or do nothing, (4) ${CLAUDE_PLUGIN_ROOT} is empty when a
  hook runs under Codex, (5) you need to know whether "submit to the official
  marketplace" has a Codex equivalent. Covers the manifest/marketplace parity,
  the version-pin release discipline shared by both, the PLUGIN_ROOT env-var
  trap, and the runtime-protocol caveat.
author: Claude Code
version: 1.0.0
date: 2026-06-11
---

# Claude Code <-> Codex CLI plugin parity

## Problem

Codex CLI (plugins added ~v0.117) ships a plugin system that looks almost
identical to Claude Code's. The similarity is close enough that you assume a
Claude Code plugin drops into Codex unchanged - then the manifest installs
fine but the hooks silently do nothing, because two small things differ
(the plugin-root env var and the hook runtime protocol). This skill is the
map of what is shared vs what is not, so a port is a 20-minute job, not a
day of guessing.

## Context / Trigger Conditions

- Porting a Claude Code plugin to Codex CLI or vice versa.
- Writing a `.codex-plugin/plugin.json` alongside an existing
  `.claude-plugin/plugin.json`.
- A hook works under Claude Code but does nothing under Codex.
- `${CLAUDE_PLUGIN_ROOT}` resolves empty when a hook runs under Codex.
- Deciding how to distribute / release a plugin for both runtimes.

## What is IDENTICAL (copy almost verbatim)

| Concern | Claude Code | Codex CLI |
|---|---|---|
| Manifest path | `.claude-plugin/plugin.json` | `.codex-plugin/plugin.json` |
| Manifest fields | `name`, `version`, `description`, `author`, `homepage`, `repository`, `license`, `keywords` + component pointers | **same fields** |
| Component pointers | (varies) | `skills: "./skills/"`, `hooks: "./hooks/hooks.json"`, `mcpServers: "./.mcp.json"`, `apps: "./.app.json"` |
| Marketplace file | `.claude-plugin/marketplace.json` | `marketplace.json` (local: `~/.agents/plugins/marketplace.json`) |
| Hook registration shape | `hooks.json` with `PreToolUse` + `"matcher": "Bash"` + `{"type":"command","command":...}` | **same shape, same event names** (`PreToolUse`, `PostToolUse`, `SessionStart`, `Stop`, `UserPromptSubmit`, ...) |
| Version pinning | pins on the `version` string | **same** |
| Install cache | marketplace clone | `~/.codex/plugins/cache/$MARKETPLACE/$PLUGIN/$VERSION/` |

### Shared version-pin release discipline

Both runtimes **pin on the `version` string in plugin.json**: pushing new
commits without bumping `version` leaves existing installs on the cached
copy. Omit `version` entirely and the runtime falls back to the commit /
short SHA (Codex curated-cache entries use short SHAs; local installs use
`$VERSION = local`). So the same "bump version + tag" release step works for
both - a release script should bump **both** manifests in lockstep when a
repo distributes to both ecosystems.

## What DIFFERS (the actual port work)

1. **Plugin-root env var.** Claude Code hook commands reference
   `${CLAUDE_PLUGIN_ROOT}`. Codex sets a **different** variable named
   **`PLUGIN_ROOT`** ("a Codex-specific extension that points to the
   installed plugin root", per the Codex hooks doc). `${CLAUDE_PLUGIN_ROOT}`
   is simply unset under Codex, so a hooks.json copied verbatim runs a
   command with an empty path and fails silently. You **cannot alias the
   same hooks.json across both runtimes** unless every command path is
   runtime-portable. Practical fix: ship a separate Codex hooks file (the
   community uses a `hooks.codex.json`-style variant) that uses
   `${PLUGIN_ROOT}`, and point the Codex manifest's `hooks` pointer at it.

2. **Hook runtime protocol is unverified-equal.** Matching *registration*
   shape (same event names, same `matcher`, same `type: command`) does NOT
   guarantee *behavioral* parity. The stdin event JSON the hook receives and
   the decision/permission output contract it must emit (e.g. how Claude
   Code's PreToolUse allow/ask/deny decision is expressed) may differ between
   the two runtimes. Verify the actual stdin payload and expected stdout/exit
   contract under Codex before claiming a hook is ported - don't infer it
   from the manifest.

3. **No self-serve official Codex marketplace (yet).** Anthropic has an
   official-marketplace submission form (claude.ai/settings/plugins/submit,
   platform.claude.com/plugins/submit). Codex has **no public self-serve
   marketplace submission**: distribute via a repo-hosted `marketplace.json`
   + `codex plugin add`, or via Codex-app workspace sharing to named
   teammates. So "submit to the official marketplace" has a Claude Code path
   but, as of mid-2026, no Codex equivalent - only the repo/CLI path maps.

## Solution (port checklist, CC -> Codex)

1. Add `.codex-plugin/plugin.json` mirroring `.claude-plugin/plugin.json`
   (same name/version/description/author/homepage/repository/license;
   add `keywords` for discovery).
2. Do NOT point the Codex `hooks` pointer at the Claude hooks.json if that
   file uses `${CLAUDE_PLUGIN_ROOT}`. Either make the command paths portable
   or ship a Codex-specific hooks file using `${PLUGIN_ROOT}`.
3. Verify the hook's stdin/stdout/exit contract under an actual Codex run
   before declaring parity.
4. Keep both manifests' `version` in lockstep; bump both per release.
5. Distribute via repo `marketplace.json` + `codex plugin add`; there is no
   official-marketplace submission to do.

## Verification

- `codex plugin add <source>` then `codex plugin list --json` shows the
  plugin with the expected `name`, `version`, `installed`, `enabled`.
- Trigger the hooked event and confirm the hook command actually runs
  (echo `$PLUGIN_ROOT` from the hook to confirm it is populated under Codex).

## Notes

- Codex plugin CLI: `codex plugin add`, `codex plugin list` (both support
  `--json`). Plugins can bundle skills, MCP servers, apps, and hooks.
- Cross-pollination already exists: OpenAI ships `codex@openai-codex` as a
  *Claude Code* plugin (the rescue bridge), so the two marketplaces reference
  each other.
- Worked example: a plugin's repo added `scripts/release.sh` in one PR
  (version bump + tag for the shared pin-on-version model) and a metadata-only
  `.codex-plugin/plugin.json` scaffold in a follow-up PR, deliberately leaving
  the `hooks` pointer out pending the `${PLUGIN_ROOT}` rewrite + protocol check.

## References

- Codex plugins overview: https://developers.openai.com/codex/plugins
- Codex build plugins (manifest, marketplace, distribution): https://developers.openai.com/codex/plugins/build
- Codex hooks (confirms `PLUGIN_ROOT` env var): https://developers.openai.com/codex/hooks
- Codex changelog (plugin feature history): https://developers.openai.com/codex/changelog
- Community plugin list + "no self-serve marketplace submission" note: https://github.com/hashgraph-online/awesome-codex-plugins
- Claude Code plugin marketplaces (version resolution / SHA pinning): https://code.claude.com/docs/en/plugin-marketplaces
