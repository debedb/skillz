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
  rather than reading the bundle, (6) the harness is installed but captures
  nothing on an Angular/zone.js app — prototype patches are bypassed and you
  need the constructor-level swap plus a pre-flight proof before any risky
  click, (7) you must prove a submission actually created something, not just
  that a request left the browser. Covers patching window.fetch AND
  XMLHttpRequest together (the XHR half is the one usually missed), the
  constructor swap for zone.js apps, the pre-flight gate, matcher scope (block
  the commit call, never the dialog's own reads), recording responses,
  blocking cleanly, and disarming afterwards — including why a hash-route
  navigation does not remove the patch.
author: Claude Code
version: 1.1.0
date: 2026-08-28
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
- You patched `XMLHttpRequest.prototype` too and STILL saw nothing on an
  Angular app. **zone.js saved references to the native methods at page load**
  and routes app traffic through them, bypassing prototype patches installed
  later. Browser-extension network trackers are no fallback: they record only
  from the moment they are first invoked — there is no retrospective view of a
  request that already happened.
- You need to distinguish two candidate endpoints and the code has both in a
  map keyed by mode.

## Solution

Install one harness that patches **both** transports, records the parsed body on
`window`, and refuses to let the matching request leave.

**Matcher scope first.** `MATCH` must match ONLY the commit/submit call. Many
dialogs fetch their own configuration when they open (saved settings, allowed
integrations, credit balances); a broad matcher such as `/export/i` blocks
those reads, the dialog never finishes assembling, and the submit you wanted
to capture is never even formed — which looks exactly like "the harness works
but nothing happens". Let the dialog's read endpoints pass; block the one
POST that commits. If you do not know the commit endpoint, find it in the
minified bundle first (the code usually keeps an endpoint map keyed by mode)
rather than guessing wide.

### Standard harness (non-zone.js apps)

```js
(() => {
  if (window.__capInstalled) return 'already installed';
  window.__cap = [];
  const MATCH = /<url-fragment-of-the-commit-endpoint>/i;   // the COMMIT call only

  const origFetch = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    if (MATCH.test(url)) {
      let body = init && init.body;
      try { body = JSON.parse(body); } catch (e) {}
      window.__cap.push({ via: 'fetch', url, body, blocked: true });
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
      window.__cap.push({ via: 'xhr', method: this.__capMethod, url: this.__capUrl, body: parsed, blocked: true });
      try { this.abort(); } catch (e) {}
      return;                       // never call origSend — nothing leaves
    }
    return origSend.apply(this, arguments);
  };

  window.__capInstalled = true;
  return 'armed';
})()
```

### Constructor swap (zone.js / Angular apps)

If the pre-flight below shows zero app traffic, the app is calling saved
native references and the prototype patch above is invisible to it. Swap the
**constructor** instead — every XHR the app creates from now on is built by
your wrapper, which zone.js cannot have saved:

```js
(() => {
  if (window.__capInstalled) return 'already installed';
  window.__cap = [];
  const BLOCK = /<url-fragment-of-the-commit-endpoint>/i;   // commit call ONLY
  const NativeXHR = window.XMLHttpRequest;

  function CapXHR() {
    const xhr = new NativeXHR();
    const origOpen = xhr.open, origSend = xhr.send;
    xhr.open = function (method, url) {
      xhr.__capUrl = url; xhr.__capMethod = method;
      return origOpen.apply(xhr, arguments);
    };
    xhr.send = function (body) {
      const url = xhr.__capUrl || '';
      if (BLOCK.test(url)) {
        let parsed = body; try { parsed = JSON.parse(body); } catch (e) {}
        window.__cap.push({ via: 'xhr', method: xhr.__capMethod, url, body: parsed, blocked: true });
        try { xhr.abort(); } catch (e) {}
        return;
      }
      xhr.addEventListener('loadend', () => {
        window.__cap.push({ via: 'xhr', method: xhr.__capMethod, url,
          status: xhr.status, response: String(xhr.responseText || '').slice(0, 2000) });
      });
      return origSend.apply(xhr, arguments);
    };
    return xhr;
  }
  CapXHR.prototype = NativeXHR.prototype;
  window.XMLHttpRequest = CapXHR;

  const origFetch = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    if (BLOCK.test(url)) {
      let body = init && init.body;
      try { body = JSON.parse(body); } catch (e) {}
      window.__cap.push({ via: 'fetch', url, body, blocked: true });
      return Promise.reject(new Error('[capture] blocked by harness'));
    }
    return origFetch.apply(this, arguments).then(res => {
      res.clone().text().then(t => window.__cap.push({
        via: 'fetch', url, status: res.status, response: t.slice(0, 2000) })).catch(() => {});
      return res;
    });
  };

  window.__capInstalled = true;
  return 'armed (constructor swap)';
})()
```

This variant also records **responses** for the non-blocked traffic — see
"Capture the response" below.

### Pre-flight gate — prove the hook sees traffic BEFORE the risky click

Never take the destructive click on faith that the harness works. After
installing, drive a harmless action that must produce app traffic (a search,
a list navigation) and count what the hook logged:

```js
window.__cap.length   // and inspect the URLs — they must be APP calls, not telemetry
```

Only proceed when the hook has observed real application requests (a passing
pre-flight looks like "17 app requests observed, including the list search").
Zero entries, or only analytics/telemetry hosts, means the app's traffic is
bypassing you — a miss on the real click is a real, possibly billable
submission. This gate is what converted an unexplained "captured nothing" into
a verified capture-and-block on a zone.js app: the prototype patch failed
pre-flight, the constructor swap passed it, and only then was the export
clicked.

Then: perform the click, and read `JSON.stringify(window.__cap, null, 1)`.

**Order matters.** Install *after* the page has finished loading and *after* any
route navigation you need, because a full document load wipes the patch. Install
before opening the dialog that builds the request — some apps assemble the job
config when the dialog opens.

**Disarm when done.** `location.reload()`. This is not optional housekeeping: a
left-behind harness silently breaks that endpoint for the human using the
browser afterwards.

## Capture the response, not just the request (observe mode)

When you are letting a submission through on purpose (a test environment),
an outbound payload is **not** proof anything was created. One observed run
logged a clean outgoing request and the server created nothing — the only
tell was the missing row in the product's own list UI; the harness had
recorded the request and nothing else. A real submit is the **2xx response
with the created resource's id in the body** (e.g. a
`{"data":{"createdJobId":..., "code":0}}` shape). The constructor-swap
harness above records `status` + a response snippet on `loadend` for exactly
this reason; keep observe-mode captures until the response confirms creation,
and treat "request out, no response captured, no row in the UI" as a failed
submit, not a slow one.

## Verification

- The captured entry exists and its `url` is the endpoint you expected — if it
  is *not*, that mismatch is itself the finding.
- The app shows a failure (or nothing) rather than a success toast, and no
  record appears in the product's own list/history UI. Check that UI, not just
  the network panel; "blocked" must mean "nothing was created".
- In observe mode, "submitted" means a 2xx response carrying the created
  resource id — never just an outbound request.
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
  wedge the app in a way that looks like a product bug — and, worse, it can
  block the dialog's own configuration reads so the submit is never formed
  (see "Matcher scope first").
- **Prototype patch vs constructor swap.** Prefer the standard harness; if
  pre-flight fails on an Angular app, switch to the constructor swap — zone.js
  holds saved native references that prototype patches never intercept.
  Whichever variant you use, the pre-flight gate is mandatory before any
  click with a side effect.
- **Extension/devtools network trackers start empty.** They log from first
  invocation onward; arm them (or the harness) BEFORE the flow you care
  about — there is no way to recover a request that fired earlier.
- **Rendering the capture for a screenshot:** append a fixed-position `<div>`
  with the JSON as `textContent` and screenshot that — legible evidence for a
  ticket, and it avoids pasting a payload that may contain identifiers.
- Prefer the parsed body over the raw string in reports, but keep the raw one if
  the endpoint is not JSON.
- Blocking is what makes this safe to run against a customer's real account. If
  you cannot block (the action is fired server-side, or through a worker), do
  not use a live account — the harness is only half the safety.
