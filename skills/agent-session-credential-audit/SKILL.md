---
name: agent-session-credential-audit
description: |
  Find, triage, rotate and scrub credentials that leaked into AI agent session
  transcripts and logs. Use when: (1) auditing whether secrets ended up in
  Claude Code / Codex / other agent session files, (2) a credential is suspected
  leaked and you must decide how bad it is, (3) rotating a credential that a
  teammate or another machine uses, (4) scrubbing transcripts after rotation.
  Covers the surfaces a naive scan misses (file-history snapshots, prompt
  history, hook logs, soft-deleted session tombstones, editor-backup siblings),
  why `rg` silently reports clean without `-uu`, the false-positive taxonomy
  (vendored `node_modules` literals, redaction-test fixtures, docs example keys,
  self-expiring temp creds), the key-id-vs-secret severity test that decides
  whether this is housekeeping or an incident, non-destructive liveness probes
  per credential class, reporting at capability granularity instead of identity
  granularity, and a scrub driven by a kill-list of verified-dead fingerprints
  so it cannot erase a live secret ahead of its rotation.
author: Claude Code
version: 1.0.0
date: 2026-08-15
source: https://github.com/voitta-ai/skillz
source_file: skills/agent-session-credential-audit/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file:
> `skills/agent-session-credential-audit/SKILL.md`). Updates go through the
> repo's worktree + PR workflow - open an issue, branch, PR.

# Auditing agent sessions for leaked credentials

## Problem

Agent sessions are permanent, plaintext, on-disk records. The transcript captures
your messages, the assistant's messages, every command run, and **the complete
stdout of every command**. Nothing scrolls away. A secret visible for one second
persists indefinitely and propagates into every backup of that machine.

Two consequences drive everything below:

1. **The check can become the leak.** `grep <value>`, `echo $TOKEN`, or printing a
   matched line writes the secret into the very transcript you are auditing, plus
   shell history and any verbatim-logging hook.
2. **The remediation can become the leak.** Rotating a credential *through* an
   agent session puts fresh key material into a transcript - a longer-lived
   exposure than the one being fixed. This is not hypothetical; it is the single
   most common way an audit makes things worse.

## Golden rules

- Never pass a secret on argv. It hits `ps`, shell history, and logging hooks.
- Read values in-process (`os.environ`, or a file the script opens). Match with
  Python `in` / `count`, never by shelling out with the value.
- Report **file + status + fingerprint** (`sha256[:10]`). Never the value.
- Rotate **outside** any transcribed session.
- **Rotate first, scrub second.** Rotation kills the value; scrubbing is cleanup.
  Scrubbing a live secret destroys your evidence trail and manufactures false
  confidence.

## Step 1 - Sweep the right surfaces

`~/.claude/projects/` is the obvious one and is never the whole story:

| Surface | Why it matters |
|---|---|
| `<agent-home>/projects/**/*.jsonl` | main transcripts |
| `<agent-home>/file-history/**` | file snapshots; holds pre-edit copies of config files |
| `<agent-home>/history.jsonl` | prompt history |
| `<agent-home>/*.log` (hook/plugin logs) | command-logging hooks record commands verbatim |
| other agents' session dirs | one machine usually runs several agent stacks |
| `*.jsonl.deleted.<timestamp>` | **soft-delete is not delete**; tombstoned sessions keep full content |
| `credentials~`, `#credentials#`, `*.bak`, `*.orig` | editor backups shadow a gitignored secret file |

```bash
rg -uu --no-messages -o -a \
  -e "(AKIA|ASIA)[0-9A-Z]{16}" \
  -e "xox[baprse]-[A-Za-z0-9-]{10,}" \
  -e "hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+" \
  -e "npm_[A-Za-z0-9]{36}" \
  -e "BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY" \
  <agent-home> <other-agent-home> ~/.aws > raw.txt
```

**`-uu` is mandatory.** Without it `rg` skips hidden directories and honors ignore
files - so every agent home scans clean and tells you nothing is wrong.

Prefix-anchored patterns beat generic high-entropy detection, which over-flags
UUIDs and paths. Err toward false positives: an extra file to eyeball costs a
minute, a missed live leak costs an incident.

## Step 2 - Strip the noise before counting

Four classes produce confident-looking garbage:

- **Vendored `node_modules`.** Bundled parsers contain literals matching
  credential regexes (a well-known JS formatter's bundled flow parser matches the
  AWS access-key pattern). Exclude, or you cry wolf.
- **Redaction-test fixtures.** Any secret-scrubbing library ships tests full of
  realistic samples. Plugin *cache* and *marketplace* copies double every hit.
- **Docs examples.** Vendor docs and skill/README files carry example keys
  (AWS publishes an `AKIA`-prefixed 20-character sample key in its own
  docs; that literal, and its `wJalrXUt...` secret counterpart, show up
  verbatim across the ecosystem).
- **Self-expiring temp creds.** STS `ASIA...` credentials expire by design - a
  separate, low-urgency class. Triage them apart from long-lived keys.

Also: a provider may offer a *free format check*. For AWS,
`aws sts get-access-key-info --access-key-id <id>` returns `ValidationError` for a
malformed candidate - a cheap real/fake discriminator that needs no secret.

## Step 3 - Classify by where the value lives

This single question resolves most findings:

| Value found in | Means |
|---|---|
| credentials/config file **only** | configured credential, **not** an exposure |
| transcript/log but **no** local config | real leak; the consumer is on another machine |
| **both** | leaked *and* locally used - rotate and update local config |

**Being in the active config is not evidence of being live.** Probe before
claiming it. Conversely, a key that resolves to no local profile tells you the
consumer is off-box - which is what makes it worth chasing.

## Step 4 - The severity test (do not skip)

**A key ID in a log is a shrug. The secret in a log is an emergency.** Most audits
never establish which they are looking at.

For AWS, pull secret-shaped candidates (40-char base64ish) from the *same lines*
that carry the key ID, then try each in a subprocess environment and emit only a
boolean:

```python
def secret_present(access_key_id, candidate):
    env = dict(os.environ)
    env.pop("AWS_PROFILE", None)
    env.pop("AWS_SESSION_TOKEN", None)
    env["AWS_ACCESS_KEY_ID"] = access_key_id
    env["AWS_SECRET_ACCESS_KEY"] = candidate
    r = subprocess.run(["aws", "sts", "get-caller-identity"],
                       capture_output=True, env=env, timeout=40)
    retval = r.returncode == 0
    return retval
```

Nothing is printed, nothing is written. The same shape generalises: pair the
public identifier with each candidate secret and call the provider's cheapest
authenticated no-op.

## Step 5 - Liveness, non-destructively

Status only, never the value:

| Class | Probe | Live | Dead |
|---|---|---|---|
| Bearer **webhook** URL | POST a deliberately **malformed, non-JSON** body | `400 invalid_payload` | `404 no_service` |
| Chat **bot token** | `auth.test` (read-only) | `ok: true` | `invalid_auth` / `account_inactive` |
| npm token | `GET /-/whoami` | 200 | 401 |
| Cloud access key | provider key-info / caller-identity | resolves | absent from inventory |

The malformed-body trick matters: a webhook has **no status API**, and a
well-formed probe would post a message to a real channel. A malformed payload is
rejected before delivery, so nothing is posted.

**Read the failure mode, not just the verdict.** `account_inactive` on a token
plus `no_service` on *all* of that app's webhooks means the whole app was
uninstalled - not that keys were rotated individually. That distinction usually
has operational consequences: something that used to deliver is now silently
dropping traffic.

## Step 6 - Report at capability granularity, not identity granularity

Findings get written into issues, chats, and blog posts - all permanent surfaces.

| Safe to emit | Never emit |
|---|---|
| credential *type* | the value, or any prefix beyond the scheme tag |
| `sha256[:10]` fingerprint | key IDs, ARNs, usernames |
| hit count, file *class* | account IDs, workspace/org/project names |
| liveness status | anything that routes a reader to the resource |
| coarse reachability ("an account with admin-grade IAM") | which account |

Fingerprints do the correlation work identifiers would otherwise do - that is what
makes the tier workable rather than merely vaguer.

This inverts *inside* lookups: an ownership call returns the account ID, so keep
its output in-process and emit only `OWNED` / `FOREIGN` / `INVALID`.

## Step 7 - Rotate (outside the session)

- **Mint on the machine that will use the key**, piped straight into config so it
  is never displayed. No transit, no secure-channel problem, no second copy.
- **Precheck for environment-variable override.** Env vars beat config files, so
  writing a new key to the file while `<PROVIDER>_ACCESS_KEY` is exported means
  nothing reads it - and the verification step *still passes on the old key*. A
  false green that only surfaces when the old key is deleted. Test by printing a
  message, never a value.
- Most providers allow two live keys: create the new one alongside the old, verify,
  then retire the old. No outage.
- **Deactivate before deleting.** Deactivation is reversible in one call; watch the
  audit log 24-48h for stragglers, then delete.
- Keep the destructive step with a second person who can read the audit log.

## Step 8 - Scrub (after rotation)

Drive the scrubber from a **kill-list of verified-dead fingerprints**, not a regex
sweep. Values are re-derived from the files at runtime and never stored. A secret
whose fingerprint is not on the list is left alone, so the tool *structurally
cannot* erase a live secret ahead of its rotation.

Replace with `[REDACTED:<kind>:<fp>]` - keeping the fingerprint means future scans
still correlate sightings without the value existing anywhere.

Three operational traps:

1. **A scrub is a stop-the-world operation.** Agent session files have live
   writers. Rewriting under one loses its concurrent appends. Stop the service
   first (`launchctl bootout` / equivalent), scrub, restart.
2. **A scrubber cannot clean the session it runs inside.** The current transcript,
   prompt history, and hook log are being appended to as it works. Defer those and
   scrub from outside the session.
3. **Back up first, then delete the backups.** Backups contain the secrets by
   definition. Mode `0700`, and removed once the re-scan verifies.

Finish by re-scanning and asserting **residual == 0**.

## Verifying a rotation actually rotated

The most common way this audit fails is not missing a leak - it is believing a
rotation landed when it did not. Three distinct failure shapes, all observed:

**1. One provider, two credential systems.** Rotating in one console leaves the
other untouched, and the leaked credential is often the one you did not visit.

| Provider | Surface A | Surface B (separately revoked) |
|---|---|---|
| GitHub | personal access tokens (`settings/tokens`) | authorized **OAuth app** grants (`settings/applications`) - the CLI's keyring token lives here |
| A cloud/inference vendor | account/registry keys | inference-gateway keys, listed in a different console |

The tell: an auth-status command that lists **two entries** with different scope
sets and different sources (env var vs keyring). Two entries means two
credentials to account for. Probe each endpoint separately - a key can be
revoked for account APIs and still authenticate for inference/billing APIs.

**2. Delete-from-config is not revoke-at-provider.** Removing a key from a file
stops *your* use of it; every other copy - backups, transcripts, another
machine - keeps working. Revoke at the provider, then scrub.

**3. Mint-new without retire-old.** Most providers allow concurrent keys, so
creating a replacement does not disable the predecessor. Always re-probe the
**old** value after rotating; that probe, not the console, is the proof.

Re-probing by fingerprint after every rotation catches all three, costs one HTTP
call, and is the only step that distinguishes "rotated" from "believed rotated".

## Probes that lie: use a known-bad control

Some providers return the **same status code for valid and invalid keys**, so a
status-only probe silently misclassifies. One search API answers `422` in both
cases; only the body differs - an invalid key returns a
`SUBSCRIPTION_TOKEN_INVALID` error object, a valid one returns real (possibly
gzipped, hence unreadable-looking) results.

So: **run a deliberately invalid control alongside every candidate.** If the
control and the candidate produce indistinguishable responses, your probe has no
discriminating power and its verdicts are worthless. This is the liveness
equivalent of sanity-checking a scan regex against a value you know is present.

## Shadow families: renames and editor backups multiply the surface

A credential is rarely in one file. Two multipliers recur:

- **Renamed products leave their old-named config family behind.** After a
  project renames itself, `<oldname>.json` and all *its* backups survive
  alongside `<newname>.json` - a complete second family, still holding live
  credentials, that a glob for the new name never sees.
- **Shell profiles and configs have backup siblings** (`~`, `.bak`, `.bak.N`,
  `.last-good`, `.clobbered.<timestamp>`, `.archive`, `.pysave`).

Enumerate by *directory listing*, not by expected filename. In one audit a single
dead token had 24 copies across 21 config files spanning two naming families;
the live key in the same directory was in every one of them.

**Corollary for scrubbing:** never scrub the active shell profile or config the
same way you scrub transcripts. That file supplies your working credentials -
rotation updates it, a scrubber must leave it alone.

## Related skills

This is the **response** phase of a four-part family; use the right one:

- `secrets-in-agent-sessions` - prevention *during* a session: how not to write a
  credential into the transcript in the first place.
- `agent-credential-leak-surfaces` - the local surfaces where copies accumulate,
  for a pre-rotation completeness check.
- `prevent-committing-secrets` - prevention at commit time (pre-commit scanner,
  push protection).
- **this skill** - what to do once a credential *has* leaked: triage, severity,
  liveness, rotation verification, and scrub.

## Quick reference

| Task | Move |
|---|---|
| Sweep | `rg -uu` over every agent home + tombstones + editor backups |
| De-noise | drop `node_modules`, redaction fixtures, docs examples, temp creds |
| Classify | where does the value live? config-only vs transcript-only vs both |
| Severity | pair public ID with candidate secret, in-process, boolean out |
| Liveness | malformed body (webhook), `auth.test`, `whoami`, key-info |
| Report | type + fingerprint + status; never value, ID, account, or name |
| Rotate | mint in place, precheck env override, deactivate then delete |
| Verify | re-probe the **old** value; check for a second credential surface |
| Probe | run a known-bad control; if it matches, the probe proves nothing |
| Enumerate | list the directory - renames and backups leave shadow families |
| Scrub | kill-list of dead fingerprints, writers stopped, residual 0 |
