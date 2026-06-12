---
name: wordpress-com-publish
description: |
  Acquire a WordPress.com OAuth2 bearer token and publish posts to a
  WordPress.com (or Jetpack-connected) blog from a chat/agent session. Use
  when: (1) the user wants to publish or draft a post to a WordPress.com site
  and has (or can create) an app at https://developer.wordpress.com/apps/,
  (2) you need to mint a long-lived WordPress.com access token via the
  authorization-code flow, (3) a token exchange is failing with
  `invalid_client` ("Unknown client_id") or `invalid_grant`. Covers the
  interactive authorize -> paste-code -> exchange flow (prompting for Client
  ID and Client Secret without storing them), the publish/update REST call,
  and the failure modes (placeholder client_id, single-use code expiry,
  redirect_uri byte-match, 2FA). NOT for self-hosted WordPress using
  application-password REST - this targets public-api.wordpress.com.
author: Claude Code
version: 1.0.0
date: 2026-06-11
source: https://github.com/voitta-ai/skillz
source_file: skills/wordpress-com-publish/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file: `skills/wordpress-com-publish/SKILL.md`).
> Updates go through the repo's worktree + PR workflow - open an issue,
> branch, PR.

# wordpress-com-publish

## Scope
This targets **WordPress.com** and **Jetpack-connected** sites through the
public REST API at `public-api.wordpress.com`, authenticated with an OAuth2
bearer token. It is **not** for self-hosted WordPress using the built-in
application-password REST API (`/wp-json/wp/v2/`, WP 5.6+) - that is a
different auth model entirely.

A WordPress.com access token is **long-lived**: it does not expire until the
user revokes it at https://wordpress.com/me/security/connected-applications.
So Part A is a one-time setup; everyday use is just Part B.

## Prerequisites
The user needs an OAuth2 application at https://developer.wordpress.com/apps/.
From its **Settings** tab, three values matter:
- **Client ID** (a number; it is also in the app URL, e.g. `/apps/133190`, but
  confirm against the Settings page - the displayed Client ID is authoritative).
- **Client Secret** (sensitive - see secret handling below).
- **Redirect URL(s)** - one or more registered redirect URIs.

Also identify the **target site**: its `blog_id` (number) or its domain
(e.g. `blog.example.com`). Both are returned by the token exchange in Part A.

## Part A - acquire a token (interactive, one-time)

1. **Ask the user** for the **Client ID** and the **Redirect URL** registered
   on the app. Do not guess the redirect; it must byte-match a registered one.

2. **Build and present the authorize URL** (fill in the two values):
   ```
   https://public-api.wordpress.com/oauth2/authorize?client_id=CLIENT_ID&redirect_uri=REDIRECT_URI&response_type=code&scope=global
   ```
   The user opens it in a browser and approves. WordPress redirects to:
   ```
   REDIRECT_URI?code=AUTH_CODE
   ```
   - `scope=global` grants access to all the user's sites. Drop `&scope=global`
     to be prompted to pick one site instead.
   - If the Redirect URL has no server listening, the browser shows a
     connection error - **the `code` is still in the URL bar**. Have the user
     copy it from there.

3. **Ask the user to paste the `code`.** It is **single-use and expires in
   minutes** - do step 5 immediately after getting it.

4. **Prompt the user for the Client Secret.** SECRET HANDLING (required):
   - Do **not** echo the secret back into the conversation.
   - Do **not** write it to any file, log, commit, or memory.
   - Use it only as an argument to the single curl in step 5. Prefer reading it
     from an env var the user sets (e.g. `read -s WPCOM_SECRET`) over inlining.

5. **Exchange the code for a token:**
   ```bash
   curl -sX POST https://public-api.wordpress.com/oauth2/token \
     -d client_id=CLIENT_ID \
     -d client_secret=CLIENT_SECRET \
     -d redirect_uri=REDIRECT_URI \
     -d grant_type=authorization_code \
     -d code=AUTH_CODE
   ```
   Success returns JSON:
   ```json
   {"access_token":"...","token_type":"bearer","blog_id":"123","blog_url":"https://blog.example.com","scope":"global"}
   ```
   Note the `blog_id` / `blog_url` - that is the `<site>` for Part B.

6. **Store the token outside the repo.** Suggest an env var in the user's shell
   profile (`export WPCOM_TOKEN=...` in `~/.bash_profile`) or macOS Keychain
   (`security add-generic-password -a "$USER" -s wpcom_token -w TOKEN`; read
   back with `security find-generic-password -s wpcom_token -w`). Never commit
   the token.

## Part B - publish or update a post

New post (`status=draft` first to verify, then `publish`):
```bash
curl -sX POST \
  "https://public-api.wordpress.com/rest/v1.1/sites/$SITE/posts/new" \
  -H "Authorization: Bearer $WPCOM_TOKEN" \
  -d title="My title" \
  -d content="<p>Body as HTML.</p>" \
  -d status=draft \
  -d tags="alpha,beta" \
  -d categories="Notes"
```
- `$SITE` = the `blog_id` (e.g. `123`) or the domain (e.g. `blog.example.com`).
- The response JSON includes the new post's `ID`, `URL`, and `status`.

Update an existing post - POST to its ID:
```bash
curl -sX POST \
  "https://public-api.wordpress.com/rest/v1.1/sites/$SITE/posts/$POST_ID" \
  -H "Authorization: Bearer $WPCOM_TOKEN" \
  -d content="<p>Edited body.</p>"
```

Common parameters for `posts/new` and `posts/$ID`:

| Param | Meaning |
|---|---|
| `title` | Post title (plain text) |
| `content` | Body. **HTML**, not markdown - convert markdown to HTML first |
| `status` | `publish`, `draft`, `private`, `pending`, or `future` (with `date`) |
| `date` | ISO 8601; schedule a future post with `status=future` |
| `tags` | Comma-separated tag names |
| `categories` | Comma-separated category names |
| `excerpt` | Optional summary |
| `slug` | URL slug |
| `type` | `post` (default) or `page` |

JSON bodies also work: add `-H "Content-Type: application/json"` and pass a
JSON object instead of `-d` pairs.

## Gotchas

- **`{"error":"invalid_client","error_description":"Unknown client_id."}`** -
  the request used a literal placeholder (e.g. `YOUR_CLIENT_ID`) or a wrong
  client_id. Substitute the real Client ID from the Settings page and retry.
- **`{"error":"invalid_grant"}`** - one of:
  - the `code` expired (single-use, ~minutes) or was already used -> re-run the
    authorize URL for a **fresh** code and exchange it immediately;
  - the `redirect_uri` does not **byte-match** a registered Redirect URL. A
    trailing slash counts: `https://blog.example.com/` != `https://blog.example.com`.
    Use exactly what is registered (and exactly where the browser landed).
- **2FA is fine.** The authorization-code flow works with two-factor enabled,
  unlike the `password` grant (which also only works for the app owner).
- **Tokens are long-lived.** No refresh dance; reuse the stored token until it
  is revoked. If calls start returning `401`, the token was revoked - redo Part A.
- **Markdown does not render.** `content` is treated as HTML. Convert any
  markdown to HTML before posting, or paragraphs/code blocks will be mangled.

## Quick reference

| Goal | Call |
|---|---|
| Authorize (browser) | `GET /oauth2/authorize?client_id=..&redirect_uri=..&response_type=code&scope=global` |
| Exchange code -> token | `POST /oauth2/token` (`grant_type=authorization_code`) |
| New post | `POST /rest/v1.1/sites/$SITE/posts/new` + `Authorization: Bearer` |
| Update post | `POST /rest/v1.1/sites/$SITE/posts/$POST_ID` |
| Delete post | `POST /rest/v1.1/sites/$SITE/posts/$POST_ID/delete` |
| Revoke token | https://wordpress.com/me/security/connected-applications |

Base URL for all calls: `https://public-api.wordpress.com`.
