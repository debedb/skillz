---
name: spa-request-capture-and-block
description: |
  Capture the exact outbound request body a single-page app sends, and stop it
  before it reaches the server. Use when: (1) you need the real JSON payload of
  an action (export, purchase, submit) to compare against an expected fix,
  (2) triggering the action for real would cost money, credits, or create a
  record you cannot undo, (3) a fetch-only interceptor "did not fire" and the
  request went out anyway, (4) you must prove which of two endpoints an action
  actually posts to, (5) you are verifying a frontend fix by observing behaviour
  rather than reading the bundle. Covers patching window.fetch AND
  XMLHttpRequest together (the XHR half is the one usually missed), blocking
  cleanly, and disarming afterwards — including why a hash-route navigation does
  not remove the patch.
author: Claude Code
version: 1.0.0
date: 2026-08-19
---

# Capture and block a SPA's outbound request

## Problem

You need the literal request body an app sends when a user clicks something —
to prove a fix changed it, or to find which endpoint the action really uses.
Two obstacles: browser devtools are awkward to drive programmatically, and the
click itself may have a real side effect (spends credits, creates an export,
sends an email) that you must not incur just to read a payload.

## Context / Trigger conditions

- "Does the deployed build actually send the new value?"
- An action whose side effect is billable or irreversible.
- You installed a `window.fetch` wrapper, saw nothing, and the request still
  hit the network. **The app used `XMLHttpRequest`.** Many enterprise SPAs
  (Angular's `HttpClient` by default, older SDKs, upload paths) never touch
  `fetch`.
- You need to distinguish two candidate endpoints and the code has both in a
  map keyed by mode.

## Solution

Install one harness that patches **both** transports, records the parsed body on
`window`, and refuses to let the matching request leave.

```js
(() => {
  if (window.__capInstalled) return 'already installed';
  window.__cap = [];
  const MATCH = /<url-fragment-of-the-endpoint>/i;   // keep it narrow

  const origFetch = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    if (MATCH.test(url)) {
      let body = init && init.body;
      try { body = JSON.parse(body); } catch (e) {}
      window.__cap.push({ via: 'fetch', url, body });
      return Promise.reject(new Error('[capture] blocked by harness'));
    }
    return origFetch.apply(this, arguments);
  };

  const origOpen = XMLHttpRequest.prototype.open;
  const origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__capUrl = url; this.__capMethod = method;
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    if (MATCH.test(this.__capUrl || '')) {
      let parsed = body;
      try { parsed = JSON.parse(body); } catch (e) {}
      window.__cap.push({ via: 'xhr', method: this.__capMethod, url: this.__capUrl, body: parsed });
      try { this.abort(); } catch (e) {}
      return;                       // never call origSend — nothing leaves
    }
    return origSend.apply(this, arguments);
  };

  window.__capInstalled = true;
  return 'armed';
})()
```

Then: perform the click, and read `JSON.stringify(window.__cap, null, 1)`.

**Order matters.** Install *after* the page has finished loading and *after* any
route navigation you need, because a full document load wipes the patch. Install
before opening the dialog that builds the request — some apps assemble the job
config when the dialog opens.

**Disarm when done.** `location.reload()`. This is not optional housekeeping: a
left-behind harness silently breaks that endpoint for the human using the
browser afterwards.

## Verification

- The captured entry exists and its `url` is the endpoint you expected — if it
  is *not*, that mismatch is itself the finding.
- The app shows a failure (or nothing) rather than a success toast, and no
  record appears in the product's own list/history UI. Check that UI, not just
  the network panel; "blocked" must mean "nothing was created".
- Re-read the value you came for from `window.__cap[0].body`.

## Example

Verifying a frontend fix that was supposed to cap a bulk export to the count
shown on screen. The captured body read `"recordsRequested": 65628` — equal to
the displayed count — where the unfixed build sent `-1` (meaning "no limit").
The click would otherwise have spent the account's export credits. Running the
same harness against production showed `-1`, which is how the fix was shown to
be merged but not actually serving.

## Notes

- **A hash-route change does not reload the document.** Navigating
  `#/a` → `#/b` leaves the harness installed. Verify with
  `!!window.__capInstalled` rather than assuming.
- **Keep `MATCH` narrow.** A broad regex can block auth or telemetry calls and
  wedge the app in a way that looks like a product bug.
- **Rendering the capture for a screenshot:** append a fixed-position `<div>`
  with the JSON as `textContent` and screenshot that — legible evidence for a
  ticket, and it avoids pasting a payload that may contain identifiers.
- Prefer the parsed body over the raw string in reports, but keep the raw one if
  the endpoint is not JSON.
- Blocking is what makes this safe to run against a customer's real account. If
  you cannot block (the action is fired server-side, or through a worker), do
  not use a live account — the harness is only half the safety.
