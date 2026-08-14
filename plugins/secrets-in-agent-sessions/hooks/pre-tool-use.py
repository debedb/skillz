#!/usr/bin/env python3
"""PreToolUse hook: catch credentials embedded in a Bash command before it runs.

A secret that appears once in an agent session does not land in one place. It
lands in the transcript, any session-memory store, spilled tool-output files,
the agent's logs, and the permission allowlist if the approved command string
contained it. PreToolUse is the only point where that is preventable rather
than cleanable -- once the command has run, every copy already exists.

This is deliberately the EASY half of secret detection. Redacting secrets out
of prose is close to unwinnable; a command line is short and structured, so
matching known credential shapes against it is accurate.

Behaviour is advisory by default: it asks rather than blocks, because a control
that false-positives on real work gets disabled and then protects nothing.

    SECRETS_HOOK_MODE=ask    (default) surface it, let the operator decide
    SECRETS_HOOK_MODE=deny   refuse the command outright
    SECRETS_HOOK_MODE=off    disable

Stdlib only, by design: this runs on every Bash call, so it must not need a
dependency bootstrap and must not be slow.

NOTE TO ANYONE EDITING THIS FILE: never put a matched value into the response,
into stderr, or into any log. A secret-detector that emits secrets is the same
bug one layer down. Report the shape and the offset only.
"""

import json
import os
import re
import sys

MARKER = "credential-shaped string in command"

# Structured, high-confidence credential prefixes. These are worth acting on
# because a match is almost never a false positive.
_SHAPES = (
    ("github fine-grained PAT", re.compile(r"github_pat_[A-Za-z0-9_]{20,}")),
    ("github token", re.compile(r"gh[posru]_[A-Za-z0-9]{20,}")),
    ("gitlab PAT", re.compile(r"glpat-[A-Za-z0-9\-_]{20,}")),
    ("slack token", re.compile(r"xox[baprse]-[A-Za-z0-9-]{10,}")),
    ("slack app token", re.compile(r"xapp-[0-9]-[A-Za-z0-9-]{10,}")),
    ("aws access key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("openai-style key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9]{20,}")),
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("credentials in url", re.compile(r"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)")),
)

# Lower-confidence: a secret-ish name, a delimiter, then a value. Needs the
# guard below or it fires on env var names and resource identifiers.
_ASSIGNMENT = re.compile(
    r"(?i)\b(api[_\-\s]?key|secret|password|passwd|token|credential)\b"
    r"(\s*[=:]\s*[\"'`]?)"
    r"([A-Za-z0-9/+=_\-]{16,})"
)

# Shapes that are NAMES, not values. Without this the hook fires on
# `--token $MY_TOKEN` and `--secret some-service-auth-dev`, which is how a
# security control earns its way into someone's disable list.
_IDENTIFIER_SHAPES = (
    re.compile(r"^\$"),                            # $ENV_REFERENCE
    re.compile(r"^\{\{"),                          # {{ template }}
    re.compile(r"^[A-Z][A-Z0-9_]*$"),              # ENV_VAR_NAME
    re.compile(r"^[a-z0-9]+(?:[-_][a-z0-9]+)+$"),  # kebab-or-snake resource name
)


def _is_identifier(value):
    """True when a captured value is a name rather than a credential."""
    retval = any(p.search(value) for p in _IDENTIFIER_SHAPES)
    return retval


def findings(command):
    """Return [(label, offset)] for credential-shaped substrings.

    Never returns the matched text itself.
    """
    hits = []
    for label, pattern in _SHAPES:
        for m in pattern.finditer(command):
            hits.append((label, m.start()))
    for m in _ASSIGNMENT.finditer(command):
        if not _is_identifier(m.group(3)):
            hits.append(("%s assignment" % m.group(1).lower(), m.start(3)))
    hits.sort(key=lambda h: h[1])
    retval = hits
    return retval


def reason_text(hits):
    """Operator-facing explanation. Shapes and offsets only, never values."""
    lines = ["This command contains a %s." % MARKER, ""]
    for label, offset in hits:
        lines.append("  - %s at offset %d" % (label, offset))
    lines += [
        "",
        "Running it copies that value into the transcript, any session-memory",
        "store, spilled tool output, the agent log, and the permission",
        "allowlist if you approve it. argv is also readable by any process that",
        "can run `ps` while the command runs.",
        "",
        "Pass it through the environment instead, so the value never appears",
        "in the command string:",
        "",
        "    KEY=\"$(fetch-it)\" sh -c 'curl -H \"X-Api-Key: $KEY\" https://...'",
        "",
        "If this is a placeholder, a variable reference or a false positive,",
        "approve and carry on.",
    ]
    retval = "\n".join(lines)
    return retval


def respond(decision, reason=None):
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
        }
    }
    if reason:
        out["hookSpecificOutput"]["permissionDecisionReason"] = reason
    print(json.dumps(out))


def main():
    mode = os.environ.get("SECRETS_HOOK_MODE", "ask").strip().lower()
    if mode == "off":
        return 0
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # Never break the session over a hook parse failure.
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command:
        return 0
    hits = findings(command)
    if not hits:
        return 0
    respond("deny" if mode == "deny" else "ask", reason_text(hits))
    return 0


def selftest():
    """Runnable check: `pre-tool-use.py --selftest`.

    A regex-based security control with no verification is worse than none, so
    this ships with the cases that actually mattered. Fabricated values only.
    """
    # Fixtures are assembled from fragments on purpose. A secret-detector's
    # test data looks exactly like secrets, so written as literals they trip
    # every credential scanner pointed at this repo -- including this project's
    # own pre-publish gate. Splitting the prefix from the body keeps the
    # literals inert while the runtime strings still exercise the patterns.
    # All values below are fabricated.
    ghp = "gh" + "p_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
    xoxb = "xox" + "b-" + "1111111111-2222222222-AbCdEfGhIjKl"
    akia = "AKI" + "A" + "EXAMPLEKEYID1234"   # exactly 16 after the prefix
    glpat = "glp" + "at-" + "EXAMPLEEXAMPLEEXAMPLE"
    hexkey = "0123456789abcdef" * 4

    positive = [
        'curl -H "X-Api-Key: %s" https://example.test' % hexkey,
        "git clone https://user:%s@host/o/r.git" % ghp,
        "export TOK=%s" % xoxb,
        "aws configure set aws_access_key_id %s" % akia,
        "deploy --token %s" % glpat,
    ]
    negative = [
        'curl -H "X-Api-Key: $MY_API_KEY" https://example.test',
        "kubectl get secret my-service-auth-token-dev -o yaml",
        "echo API key env var is MY_SERVICE_API_KEY",
        "git log --oneline 2f70d66aa11bb22cc33dd44ee55ff66aa77bb88",
        "docker pull repo@sha256:" + "a1b9b47b" * 8,
        "curl -X POST https://slack.com/api/auth.test",
    ]
    bad = 0
    for c in positive:
        if not findings(c):
            print("MISS  %s" % c[:70])
            bad += 1
    for c in negative:
        hits = findings(c)
        if hits:
            print("FALSE POSITIVE %s -> %s" % (c[:60], hits))
            bad += 1
    print("selftest: %d positive, %d negative, %d problem(s)"
          % (len(positive), len(negative), bad))
    retval = 1 if bad else 0
    return retval


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
