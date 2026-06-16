---
name: claude-code-piebald-lsp-binary-on-path
description: |
  Fix the silent-fail case where Piebald-AI/claude-code-lsps plugins
  install cleanly, surface the native `LSP` tool in Claude Code, but
  the actual language-server process can't start because its binary
  isn't on PATH. Use when: (1) installing Piebald LSP plugins on a
  fresh machine, (2) `LSP` tool invocation returns
  `Executable not found in $PATH: "jdtls"` (or pyright / vtsls /
  kotlin-language-server / gopls), (3) `/reload-plugins` says
  `N plugin LSP servers` loaded but no actual LSP feature works,
  (4) confused why `claude mcp list | grep lsp` returns empty even
  after Piebald install — that command is the wrong verification
  because Piebald ships LSP plugins, not MCP servers. Also covers
  the related trap where `claude-plugins-official` marketplace
  adds empty `bin/` directories to `$PATH` so the path looks right
  but `which jdtls` still resolves to nothing. Includes the correct
  three-step verification (plugin count → ToolSearch → live smoke
  test) and the symlink fix.
author: Claude Code
version: 1.0.0
date: 2026-05-19
---

# Piebald LSP install — binary-on-PATH gotcha

## Problem

Piebald-AI/claude-code-lsps is a Claude Code **plugin marketplace** (not
an MCP server). It ships per-language plugins whose `.lsp.json` declares
`command: "<binary-name>"` — referring to the binary by bare name and
relying on it being resolvable via `$PATH`.

The install flow has two **independent** layers that neither verify the
other:

| Layer | What it does | What it does NOT check |
|---|---|---|
| `/plugin install <lang>` (Piebald) | Registers the `.lsp.json` with Claude Code | Whether the binary exists at all |
| `npm i -g pyright` / `brew install ...` / tarball extract | Installs the binary somewhere | Whether that somewhere is on `$PATH` |

Result: install "succeeds" by every visible signal. `LSP` tool surfaces
in the tool catalog. First real invocation fails with:

```
Error performing findReferences: Executable not found in $PATH: "jdtls"
```

## Context / Trigger Conditions

- Installing Piebald LSP plugins on a new machine
- LSP tool invocation returns `Executable not found in $PATH: "<server>"`
- `/reload-plugins` shows N plugin LSP servers but LSP ops never work
- Someone tried `claude mcp list | grep lsp`, got empty, and concluded
  install is broken (the command is wrong; see verification below)

## Solution

### The wrong-verification trap (clear this up first)

```bash
claude mcp list | grep -i lsp     # ALWAYS empty for Piebald, by design
```

Piebald plugins are **plugin LSP servers**, not MCP servers.
`/reload-plugins` explicitly distinguishes them:
```
Reloaded: N plugins · M skills · K agents · J hooks · 0 plugin MCP servers · 11 plugin LSP servers
```

The right verification is the three-step sequence below.

### Correct three-step verification

#### 1. Plugin count via /reload-plugins

In a Claude Code session:
```
/reload-plugins
```
Look for `... · N plugin LSP servers` where N = number of language
plugins you installed. If 0, plugin install itself failed — go fix that
first.

#### 2. Tool surface via ToolSearch

In a Claude Code session:
```
ToolSearch query: "+lsp find_references definition hover"  max_results: 5
```
Should return one tool literally named **`LSP`** with 9 operations:
`goToDefinition`, `findReferences`, `hover`, `documentSymbol`,
`workspaceSymbol`, `goToImplementation`, `prepareCallHierarchy`,
`incomingCalls`, `outgoingCalls`. All operations take
`(filePath, line, character, operation)`.

#### 3. Live smoke test (catches the binary-on-PATH bug)

```bash
# in a real Java repo
find . -name "*.java" -not -path "*/build/*" | head -1
```
Then invoke `LSP findReferences` on a known class declaration. Two
outcomes possible:

- **Real success** — returns file:line list or "No references found"
  (latter is fine for top-level entrypoint classes).
- **Binary missing** — returns `Executable not found in $PATH: "<bin>"`.
  Go to fix below.

### Fix: symlink the binary into a directory already on $PATH

`~/.local/bin/` is on the standard macOS user PATH. Symlink any
tarball-installed server there.

```bash
# jdtls (Eclipse JDT-LS — tarball install does NOT add to PATH)
ls ~/jdtls/bin/jdtls                          # confirm binary exists
ln -sf ~/jdtls/bin/jdtls ~/.local/bin/jdtls   # symlink into PATH
which jdtls                                    # verify resolves
```

Reversible: `rm ~/.local/bin/jdtls` removes the symlink without
touching the actual install.

### Per-server PATH audit

After Piebald install, run for every language you enabled:

```bash
for bin in jdtls pyright vtsls kotlin-language-server gopls; do
  echo "$bin: $(which $bin 2>&1 || echo MISSING)"
done
```

Anything `MISSING` → install the binary or symlink an existing install.

| Binary | Typical install | Auto-on-PATH? |
|---|---|---|
| `jdtls` | Eclipse tarball → `~/jdtls/bin/jdtls` | **No** — symlink to `~/.local/bin/` |
| `pyright` | `npm i -g pyright` | Yes if nvm |
| `vtsls` | `npm i -g @vtsls/language-server` | Yes if nvm |
| `kotlin-language-server` | `brew install` OR fwcd tarball | Brew yes; tarball no |
| `gopls` | `go install golang.org/x/tools/gopls@latest` | Yes if `$GOPATH/bin` on PATH |

### Compounding trap: claude-plugins-official ships empty bin/ dirs

Anthropic's `claude-plugins-official` marketplace also has LSP plugins
(`jdtls-lsp`, `pyright-lsp`, `kotlin-lsp`, `gopls-lsp`, `php-lsp`,
`typescript-lsp`). They add per-plugin `bin/` directories to `$PATH`
during install:

```
~/.claude/plugins/cache/claude-plugins-official/jdtls-lsp/1.0.0/bin/
```

**That bin/ is empty.** No binary inside. So `$PATH` *looks* like it
has jdtls (grep would match), but `which jdtls` still returns empty.

Diagnostic:
```bash
echo $PATH | tr ':' '\n' | grep -i lsp        # see if these phantom dirs exist
ls ~/.claude/plugins/cache/claude-plugins-official/jdtls-lsp/*/bin/ 2>&1
# expect: empty (or "No such file")
```

Always trust `which <binary>`, never trust `echo $PATH | grep`.

## Verification

After the symlink fix, re-run the smoke test (#3 above). Two positive
signals:

1. `LSP findReferences` returns results or a meaningful "No references
   found" instead of the PATH error.
2. Claude Code starts streaming `<new-diagnostics>` blocks (unused
   imports, unresolved Maven artifacts, type errors) — proves jdtls is
   actively indexing the workspace, not just a one-shot response.

Indexing on first run is slow (5-30s for jdtls warmup, longer for large
Gradle projects on first import).

## Example — what happened on KJX4533K4W on 2026-05-19

```
/reload-plugins
# → 11 plugin LSP servers ✓
ToolSearch +lsp find_references definition hover
# → LSP tool with 9 ops ✓
LSP findReferences OrcMerger.java:18:14
# → Error performing findReferences: Executable not found in $PATH: "jdtls"

which jdtls
# → (empty)
ls ~/jdtls/bin/jdtls
# → exists

ln -sf ~/jdtls/bin/jdtls ~/.local/bin/jdtls
which jdtls
# → /Users/<user>/.local/bin/jdtls

LSP findReferences OrcMerger.java:18:14
# → "No references found" (genuine, OrcMerger is entrypoint)
# → followed by streaming <new-diagnostics> showing unused imports
#   in other workspace files — jdtls now alive and indexing
```

## Notes

- Piebald CLAUDE.md says compatibility target: Claude Code 2.1.50+
- `tweakcc --apply` is the patch that wires Piebald plugins into CC's
  native LSP integration — needed once per CC install, requires full
  process exit + relaunch (not just `/clear`)
- Piebald is **curated**: cannot add custom servers via `.lsp.json`.
  For Terraform / YAML / Bash / SQL, pair with
  `isaacphi/mcp-language-server` (generic LSP-to-MCP bridge) instead
- The native `LSP` tool is **one tool, nine operations** — not nine
  separate tools. ToolSearch returns a single schema; `operation` is
  a required enum field

## Related

- `claude-code-plugin-update-flow` — general plugin lifecycle

## References

- Piebald marketplace: https://github.com/Piebald-AI/claude-code-lsps
- Anthropic blog source for original audit:
  https://claude.com/blog/how-claude-code-works-in-large-codebases-best-practices-and-where-to-start
