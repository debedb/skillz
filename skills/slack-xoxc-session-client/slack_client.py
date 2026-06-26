"""
slack_client.py -- programmatic Slack access via a live browser session
(xoxc web token + d session cookie). No Slack app, no admin, no OAuth.
Acts as the logged-in browser user.

Both auth secrets are auto-extracted from the local browser profile:

  - `d` (+ `d-s`) session cookie  -> decrypted from the browser cookie store via
                                     pycookiecheat (beats the httpOnly barrier that
                                     document.cookie / JS extraction cannot cross)
  - `xoxc-` web token             -> scraped from the authenticated workspace HTML
                                     (key "api_token" in the bootstrap payload)

Then POST to https://<subdomain>.slack.com/api/<method> with
data={"token": xoxc, ...} and cookies={"d":..., "d-s":...}.

Personal use only. Undocumented Slack internals; ToS-gray. Do not scale, share,
or run on behalf of others. Secrets rotate on logout / password change / session
expiry -> the client re-extracts automatically when a call returns invalid_auth.

SECURITY: tokens are held in memory only. This script never writes them to disk.
Do not print, log, or commit the xoxc token or the d / d-s cookies.

Requires: pycookiecheat, requests  (install in a .venv).

Cross-platform / cross-browser:
  pycookiecheat decrypts the cookie store for the named browser. Pass --browser
  to target Firefox or a Chromium variant. Supported names depend on the installed
  pycookiecheat version; common values: chrome, chromium, brave, edge, firefox,
  slack, arc, opera. macOS unlocks the Keychain (may prompt); Linux uses the
  Secret Service / libsecret; Windows uses DPAPI.

Usage (library):
    from slack_client import SlackSessionClient
    sc = SlackSessionClient("<workspace-subdomain>")          # e.g. acme-corp
    print(sc.call("auth.test"))
    print(sc.call("conversations.history", channel="C0123ABCD", limit=50))

    # Firefox instead of Chrome:
    sc = SlackSessionClient("<workspace-subdomain>", browser="firefox")

CLI:
    python3 slack_client.py [--browser NAME] <subdomain> <method> [k=v ...]
    python3 slack_client.py <workspace-subdomain> auth.test
    python3 slack_client.py <workspace-subdomain> conversations.history channel=C0123 limit=20
"""
import re
import sys
import json

import requests
import pycookiecheat

_UA = "Mozilla/5.0"


class SlackSessionClient:
    """Slack web-API client authenticated by a live browser session."""

    def __init__(self, subdomain, browser="chrome"):
        self.subdomain = subdomain
        # BASE must be the team subdomain host. A generic slack.com host
        # silently fails auth for these session-token calls.
        self.base = f"https://{subdomain}.slack.com/api"
        self._browser = browser
        self._cookies = None
        self._token = None

    def _extract_cookies(self):
        """Decrypt the d / d-s session cookies from the local browser store."""
        raw = pycookiecheat.chrome_cookies(
            f"https://{self.subdomain}.slack.com", browser=self._browser
        )
        d = raw.get("d", "")
        if not d.startswith("xoxd-"):
            raise RuntimeError(
                f"No valid 'd' cookie for {self.subdomain}.slack.com "
                f"(not logged in to this workspace in {self._browser}?)"
            )
        # d-s is needed by some workspaces; include it when present.
        retval = {"d": d, "d-s": raw.get("d-s", "")}
        return retval

    def _extract_token(self):
        """Scrape the xoxc- web token from the authenticated workspace HTML."""
        html = requests.get(
            f"https://{self.subdomain}.slack.com/",
            cookies=self._cookies,
            headers={"User-Agent": _UA},
        ).text
        m = re.search(r'"api_token":"(xoxc-[^"]+)"', html)
        if not m:
            raise RuntimeError(
                "Could not find xoxc- token in workspace HTML "
                "(session may be expired; re-login in the browser)"
            )
        retval = m.group(1)
        return retval

    def _ensure_auth(self):
        if self._cookies is None:
            self._cookies = self._extract_cookies()
        if self._token is None:
            self._token = self._extract_token()

    def _reset_auth(self):
        """Force re-extraction on the next call (after invalid_auth)."""
        self._cookies = None
        self._token = None

    def call(self, method, **params):
        """POST to a Slack web-API method, return parsed JSON dict.

        On invalid_auth (rotated/expired secrets), re-extract once and retry.
        """
        self._ensure_auth()
        result = self._post(method, params)
        if result.get("error") == "invalid_auth":
            self._reset_auth()
            self._ensure_auth()
            result = self._post(method, params)
        return result

    def _post(self, method, params):
        resp = requests.post(
            f"{self.base}/{method}",
            data={"token": self._token, **params},
            cookies=self._cookies,
        )
        retval = resp.json()
        return retval


def _main(argv):
    args = argv[1:]
    browser = "chrome"
    if args and args[0] == "--browser":
        if len(args) < 2:
            print(__doc__)
            retval = 2
            return retval
        browser = args[1]
        args = args[2:]
    if len(args) < 2:
        print(__doc__)
        retval = 2
        return retval
    subdomain = args[0]
    method = args[1]
    params = {}
    for kv in args[2:]:
        k, _, v = kv.partition("=")
        params[k] = v
    client = SlackSessionClient(subdomain, browser=browser)
    result = client.call(method, **params)
    print(json.dumps(result, indent=2))
    retval = 0 if result.get("ok") else 1
    return retval


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
