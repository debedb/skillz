---
name: agent-credential-leak-surfaces
description: |
  Find and clean the places a coding agent quietly accumulates copies of your
  secrets on local disk, and stop it recurring. Use when: (1) you found a token
  in one place and need to know where else it went before rotating; (2) you are
  about to rotate a credential and want the rotation to actually be complete;
  (3) an agent echoed a secret into a session and you want to know what
  persisted it; (4) you are writing a redactor and need to know which patterns
  work and which are unwinnable; (5) periodic hygiene on a machine where an
  agent has been editing config files. Covers the six surfaces (git remote URLs,
  agent memory stores, the agent's own file-history snapshots, MCP config
  literals, permission allowlists, tool-output caches), why prefix-grep gives
  false confidence, why keyword-adjacency regexes lose to prose, why bare
  high-entropy matching is unusable, and the fingerprint-not-echo technique.
author: Claude Code
version: 1.0.0
---

# Where a coding agent leaves copies of your secrets

## Problem

You rotate a leaked credential and consider it handled. But rotation only closes
the exposure you found. Around a coding agent, one secret typically exists in
**several** places you did not put it, created by machinery you never
configured, and none of them are in git.

The failure mode is not "a secret leaked." It is **"we rotated the copy we knew
about."**

## The six surfaces

Ordered by how often they are missed, not by severity.

### 1. Credentials embedded in git remote URLs

```
https://<user>:<token>@<host>/<org>/<repo>.git
```

Lives in `.git/config`, per clone. Clone the same way ten times and there are
ten copies of the token, which then age independently of wherever you think the
canonical copy lives.

```bash
find ~ -maxdepth 5 -name config -path '*/.git/*' \
  -exec grep -lE 'url = https?://[^/]*:[^@/]+@' {} \;
```

Strip them without touching anything else:

```bash
git -C <repo> remote set-url <name> \
  "$(git -C <repo> remote get-url <name> | sed -E 's|://[^/@]+@|://|')"
```

Then give git a real credential source, or the next person just pastes the token
back in. A credential helper or an SSH remote is the fix; a token in the URL is
the symptom.

### 2. Agent memory / session-transcript stores

Any "remember this session" feature persists prompts and replies verbatim into a
long-lived, usually embedded and searchable store. Anything you pasted, and
anything the assistant echoed back in prose, is now in it. Embedded means it can
resurface in a *later* session's context, which is a feedback loop: the secret
gets re-injected and re-persisted.

Check what your store ingests and whether it filters. Most do not.

### 3. The agent's own file-history snapshots

This is the one nobody looks at. Coding agents commonly snapshot every file they
edit so edits can be undone. Edit a config containing secrets three times and
there are three preserved generations of the then-current secrets — including
ones you already rotated and believed gone.

Symptom that gives it away: a token you rotated months ago is still on disk, in
a directory you have never opened, under an opaque filename.

```bash
grep -rlE '(gh[posru]_|xox[baprs]-|xapp-|glpat-|AKIA)[A-Za-z0-9_-]{10,}' \
  <agent-state-dir> 2>/dev/null
```

Rotating without clearing these leaves the old values sitting next to the new
ones, and the next rotation adds another generation.

### 4. MCP / tool config with literal secrets

Config files that wire up tool servers often take secrets as an `env` map. It is
easy to paste the literal. Then it is a second copy that silently keeps the old
value after you rotate the "real" one — the server keeps working until the token
expires, or keeps failing long after you fixed the env var, and nobody connects
the two.

Prefer an environment reference (`"${MY_TOKEN}"`) over a literal, so there is one
copy and one place to rotate. Audit with:

```bash
python3 - <<'PY'
import json, os, re
d = json.load(open(os.path.expanduser("<config>.json")))
pat = re.compile(r"(gh[posru]_|xox|xapp-|glpat-|AKIA|sk-)[A-Za-z0-9_-]{10,}")
def walk(n, p=""):
    if isinstance(n, dict):
        for k, v in n.items():
            if isinstance(v, str) and pat.search(v): print("LITERAL at %s.%s" % (p, k))
            else: walk(v, p + "." + k)
    elif isinstance(n, list):
        for i, v in enumerate(n): walk(v, p + "[%d]" % i)
walk(d)
PY
```

### 5. Permission allowlists

Agents that ask before running commands often record the **approved command
string** so they need not ask again. Approve one `curl` with a token in the
header, or one `git clone` with a token in the URL, and the credential is now
inside a permission file — which is exactly the kind of file people share or
commit, because it looks like configuration rather than a secret.

### 6. Tool-output caches and logs

Large tool results get spilled to files. Anything a command printed — including
a secret it legitimately fetched — can persist there long after the session.

## Three lessons about detection, learned the hard way

### Prefix-grep gives false confidence

Sweeping for one token shape finds one token shape. A sweep for `gh[posru]_`
across a machine came back "clean" while an API key, a chat bot token and an
app-level token sat untouched in the same files.

**Sweep for the union of shapes, not the one you are chasing.** Minimum useful
set: `gh[posru]_`, `github_pat_`, `glpat-`, `xox[baprse]-`, `xapp-`, `AKIA`,
`ASIA`, `sk-`, and `-----BEGIN * PRIVATE KEY-----`.

### Keyword-adjacency regexes lose to prose

The obvious redaction rule is *a secret-ish word, a delimiter, then the value*:

```
(api[_-]?key|secret|token|password)\s*[=:]\s*["']?([A-Za-z0-9/+=_-]{16,})
```

One real 64-char key appeared **fourteen times in one document in eight
phrasings**, and that pattern caught four of them. The misses:

| written as | why it missed |
|---|---|
| `API key: \`<value>\`` | value is in **backticks**; `["']?` has no backtick. In markdown transcripts this is the *common* case |
| `API key value: \`<value>\`` | a word sits between the name and the delimiter |
| `Fetched API key from Secrets Manager: <value>` | several words do |
| `**API key**: <value>` | markdown emphasis is punctuation between name and delimiter |
| `Authorization: <value>` | "Authorization" was not in the keyword list |
| `API key \`<value>\`` | no delimiter at all |

Widening to allow intervening text then broke other things (see below). **Do not
try to win this.** For cleaning a known leak, do a **literal replacement of the
known value** — exact, complete, no regex. Save patterns for *prevention at
ingest*, where a miss costs one leak rather than the whole cleanup.

### Bare high-entropy matching is unusable

The tempting fix for the above is to match the value shape alone — say
`[0-9a-f]{32,}`. It does not survive contact with a real transcript, because
**64-hex strings are everywhere and almost none are secrets**: container image
digests (`sha256:…`), object-store canonical user ids, avatar hashes, diff
anchors, trace ids. Raising the bound to exclude 40-char SHA-1 does not help,
since the collisions are at 64.

### What does work: keyword adjacency plus a value-shape guard

Keep the adjacency requirement, add backticks to the quote class, allow a short
run of **letters and spaces only** between the name and the delimiter, and then
reject captures that are *names* rather than values:

```python
_IDENTIFIER_SHAPES = (
    re.compile(r"^\$"),                            # $ENV_REFERENCE
    re.compile(r"^[A-Z][A-Z0-9_]*$"),              # ENV_VAR_NAME
    re.compile(r"^[a-z0-9]+(?:[-_][a-z0-9]+)+$"),  # kebab-or-snake resource name
)
```

Without that guard the redactor eats `MY_SERVICE_API_KEY`, `some-service-auth-token-dev`
and `$SOME_TOKEN` — protecting nothing while making the stored text useless.
Allowing punctuation in the intervening run also matches things like
`| token | POST /oauth2/token (grant_type=` and redacts a URL.

Validate a redactor by running it over a **large real corpus** and reading every
line it changes. A run over ~730k lines that changes 8 lines, all genuine, is
evidence. A run that changes 300 lines is a bug.

## Do not let the cleanup become another copy

An agent investigating a leak must never print the values it finds, or the
investigation itself lands the secret in the session transcript, the tool-output
cache and the logs — i.e. three more of the six surfaces above.

The short version: compare by **fingerprint** (`printf '%s' "$T" | shasum | cut -c1-10`),
identify a token by **asking the service who it is** rather than by reading it,
and count with `grep -c` / `grep -l` so no value reaches scrollback.

See **`secrets-in-agent-sessions`** for the full set of techniques and the traps
that put secrets into transcripts in the first place.

## Prevention

- **One copy.** Environment references in config, never literals. A second copy
  is a future stale credential.
- **No tokens in git remotes.** Credential helper or SSH.
- **Redact at ingest** in anything that persists sessions. Structured token
  prefixes are reliable; prose-shaped assignments are best-effort. Both beat
  nothing.
- **Never paste a secret into an agent session** to hand it to another process.
  Move it out-of-band; the transcript is a permanent store.
- **After rotating, sweep for the OLD value** across all six surfaces. If it is
  still on disk, the rotation is not finished.

## Related

- `pre-open-source-credential-audit` — the adjacent problem: auditing a git repo
  and its **history** before making it public. Disjoint from this skill; nothing
  here is git-tracked.
