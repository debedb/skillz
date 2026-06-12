---
name: wordpress-com-publish
description: |
  Publish a post to a WordPress.com (or Jetpack-connected) blog in one step,
  or, if no usable token exists yet, get one first and then publish. Use when:
  (1) the user asks to post or draft something to their WordPress.com site,
  (2) you have content to publish and need to resolve or mint a WordPress.com
  OAuth2 bearer token, (3) a publish call returns 401 / authorization_required
  and the token must be re-minted, (4) a token exchange fails with
  invalid_client or invalid_grant. Operating contract: resolve a token (env
  then Keychain); if present, publish; if absent, run the authorization-code
  flow, store the token, then publish. NOT for self-hosted WordPress using
  application-password REST - this targets public-api.wordpress.com.
author: Claude Code
version: 1.1.0
date: 2026-06-12
source: https://github.com/voitta-ai/skillz
source_file: skills/wordpress-com-publish/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file: `skills/wordpress-com-publish/SKILL.md`).
> Updates go through the repo's worktree + PR workflow - open an issue,
> branch, PR.

# wordpress-com-publish

Publish to **WordPress.com** / **Jetpack-connected** sites via the REST API at
`public-api.wordpress.com`, authenticated with a long-lived OAuth2 bearer
token. (NOT self-hosted WordPress application-password REST - different auth.)

## Operating procedure - post, or get a token if we can't

This is the contract. Given content to publish:

1. **Resolve a token**, in order:
   - `$WPCOM_TOKEN` if set;
   - else macOS Keychain: `security find-generic-password -s wpcom_token -w 2>/dev/null`.
2. **Token found -> Publish** (below). If Publish returns `401` /
   `authorization_required`, the token was revoked: treat as no token.
3. **No token -> Authorize** (below), store the token in Keychain, then Publish.

**Site**: use `$WPCOM_SITE` (a `blog_id` or domain, e.g. `blog.example.com`),
or ask the user. List the sites a token can reach with
`GET /rest/v1.1/me/sites`.

The one-shot `publish.sh` below implements this whole contract; run it, or
follow the steps by hand.

## Publish

```bash
curl -sS -X POST "https://public-api.wordpress.com/rest/v1.1/sites/$WPCOM_SITE/posts/new" \
  -H "Authorization: Bearer $WPCOM_TOKEN" \
  --data-urlencode "title=My title" \
  --data-urlencode "content=<p>Body as HTML.</p>" \
  --data-urlencode "status=draft"
```
- Use `--data-urlencode` (not `-d`) so titles/bodies with spaces, `&`, or
  markup are sent intact.
- `status`: `draft` (verify first), then `publish`. Also `private`, `pending`,
  `future` (+ `date`).
- Response JSON includes the new post's `ID`, `URL`, `status`. Update later by
  POSTing to `.../posts/<ID>`; delete via `.../posts/<ID>/delete`.
- `content` is **HTML**, not markdown - convert markdown to HTML first.

## Authorize (only when there is no token)

Needs an app at https://developer.wordpress.com/apps/ (Settings tab:
**Client ID**, **Client Secret**, **Redirect URL**).

1. Open the authorize URL, approve, copy the `code` from the
   `redirect_uri?code=...` landing (the page may fail to load if nothing
   listens on the redirect - the `code` is still in the URL bar):
   ```
   https://public-api.wordpress.com/oauth2/authorize?client_id=CLIENT_ID&redirect_uri=REDIRECT_URI&response_type=code&scope=global
   ```
2. Exchange the `code` (single-use, expires in minutes - do this immediately):
   ```bash
   curl -sX POST https://public-api.wordpress.com/oauth2/token \
     -d client_id=CLIENT_ID -d client_secret=CLIENT_SECRET \
     -d redirect_uri=REDIRECT_URI -d grant_type=authorization_code -d code=CODE
   ```
   Returns `{"access_token":"...","blog_id":"0","blog_url":null,"scope":"global"}`.
3. **Store the token** (never the secret) in Keychain, then publish:
   ```bash
   security add-generic-password -a "$USER" -s wpcom_token -U -w "$ACCESS_TOKEN"
   ```

**Secret handling:** never echo the Client Secret into the conversation, a
file, a commit, or memory. Take it from a hidden prompt (`read -rs`) and pass
it once to the token curl.

## One-shot script

Save as `publish.sh`. With a token in `$WPCOM_TOKEN` or Keychain it posts; with
no token it runs the auth flow, stores the token, then posts. `--data-urlencode`
keeps content intact. No placeholders to leave un-substituted.

```bash
#!/usr/bin/env bash
# publish.sh "Title" "Body HTML" [draft|publish] [site]   - post to WordPress.com
# publish.sh --auth                                       - just mint+store a token
# Token: $WPCOM_TOKEN, else macOS Keychain item `wpcom_token`.
# Site:  4th arg, else $WPCOM_SITE (blog_id or domain).
# Auth (only if no token): $WPCOM_CLIENT_ID, $WPCOM_REDIRECT_URI (+ prompts).
set -euo pipefail
API=https://public-api.wordpress.com

token() { [[ -n "${WPCOM_TOKEN:-}" ]] && { printf '%s' "$WPCOM_TOKEN"; return; }
          security find-generic-password -s wpcom_token -w 2>/dev/null || true; }

authorize() {
  : "${WPCOM_CLIENT_ID:?set WPCOM_CLIENT_ID (https://developer.wordpress.com/apps/)}"
  : "${WPCOM_REDIRECT_URI:?set WPCOM_REDIRECT_URI (must match a registered Redirect URL)}"
  echo "Open, approve, copy the ?code= from the redirect:" >&2
  echo "  $API/oauth2/authorize?client_id=$WPCOM_CLIENT_ID&redirect_uri=$WPCOM_REDIRECT_URI&response_type=code&scope=global" >&2
  local code secret tok
  read -rp 'Paste code: ' code
  read -rsp 'Paste client secret: ' secret; echo >&2
  tok=$(curl -sS -X POST "$API/oauth2/token" \
        -d client_id="$WPCOM_CLIENT_ID" -d client_secret="$secret" \
        -d redirect_uri="$WPCOM_REDIRECT_URI" -d grant_type=authorization_code -d code="$code" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
  [[ -n "$tok" ]] || { echo "token exchange failed (check client_id/secret, redirect match, fresh code)" >&2; exit 1; }
  security add-generic-password -a "$USER" -s wpcom_token -U -w "$tok"
  printf '%s' "$tok"
}

[[ "${1:-}" == "--auth" ]] && { authorize >/dev/null && echo "token stored in Keychain (wpcom_token)"; exit 0; }

TITLE="${1:?usage: publish.sh \"Title\" \"Body HTML\" [draft|publish] [site]}"
BODY="${2:-}"; STATUS="${3:-draft}"
SITE="${4:-${WPCOM_SITE:?set WPCOM_SITE or pass site as 4th arg}}"

post() { curl -sS -X POST "$API/rest/v1.1/sites/$SITE/posts/new" \
           -H "Authorization: Bearer $1" \
           --data-urlencode "title=$TITLE" --data-urlencode "content=$BODY" \
           --data-urlencode "status=$STATUS"; }

TOK="$(token)"; [[ -n "$TOK" ]] || TOK="$(authorize)"
RESP="$(post "$TOK")"
if echo "$RESP" | grep -q '"error":"authorization_required"'; then
  echo "token rejected (revoked/expired); re-authorizing..." >&2
  TOK="$(authorize)"; RESP="$(post "$TOK")"
fi
echo "$RESP" | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(d["URL"]) if d.get("URL") else (print(json.dumps(d)) or sys.exit(1))'
```

## Gotchas

- **No placeholders to forget.** The manual-curl path repeatedly failed when a
  literal placeholder was left in (`client_id=YOUR_CLIENT_ID` ->
  `{"error":"invalid_client"}`; `WPCOM_TOKEN='PASTE_...'` -> empty `/me/sites`).
  The script takes every value from env or a `read` prompt, so there is nothing
  to leave un-substituted. Prefer it over hand-typed curls.
- **`invalid_client` / "Unknown client_id"**: the request used a placeholder or
  wrong Client ID. The number in the app URL is usually the client_id, but
  confirm on the Settings page.
- **`invalid_grant`**: the `code` expired (single-use, ~minutes) or was reused,
  or `redirect_uri` does not **byte-match** a registered Redirect URL (a
  trailing slash counts). Get a fresh code and exchange immediately.
- **`blog_id:"0"`, `blog_url:null` after exchange**: normal for a
  `scope=global` (account-wide) token; it is not bound to one blog. Pick the
  site per call; get real site IDs from `GET /rest/v1.1/me/sites`.
- **401 / `authorization_required` on publish**: token was revoked - re-run the
  auth flow (the script does this automatically once).
- **Markdown does not render.** `content` is treated as HTML.

## Quick reference

| Goal | Call |
|---|---|
| Resolve token | `$WPCOM_TOKEN`, else `security find-generic-password -s wpcom_token -w` |
| List reachable sites | `GET /rest/v1.1/me/sites` |
| Publish / draft | `POST /rest/v1.1/sites/$SITE/posts/new` (Bearer; `--data-urlencode`) |
| Update post | `POST /rest/v1.1/sites/$SITE/posts/$ID` |
| Authorize (browser) | `GET /oauth2/authorize?client_id=..&redirect_uri=..&response_type=code&scope=global` |
| Exchange code -> token | `POST /oauth2/token` (`grant_type=authorization_code`) |
| Revoke token | https://wordpress.com/me/security/connected-applications |

Base URL for all calls: `https://public-api.wordpress.com`.
