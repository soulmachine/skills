---
name: chrome-cdp-setup
description: Set up Google Chrome on macOS to always launch with the Chrome DevTools Protocol enabled (127.0.0.1:9222) via a Dock launcher app, so local AI agents (Playwright, Puppeteer, browser-use, OpenClaw) can drive the real logged-in browser. Use when the user wants to enable a CDP/remote-debugging port for Chrome, connect an agent to Chrome, test a CDP connection, or troubleshoot/revert an existing Chrome-CDP Dock setup.
---

# Chrome CDP Setup (macOS Dock launcher)

Makes the Dock's Chrome icon launch Chrome with `--remote-debugging-port` so any local
agent can connect over CDP. Chrome 136+ silently ignores that flag on the default
profile directory, so the launcher points Chrome at a one-time APFS clone of the real
profile — all logins, bookmarks, and extensions carry over at near-zero disk cost.

Scripts live in this skill's `scripts/` dir; run them with absolute paths
(`~/.claude/skills/chrome-cdp-setup/scripts/...`).

## Quick start

```bash
scripts/setup_chrome_cdp.sh              # full setup (default port 9222)
scripts/verify_cdp.sh                    # endpoint + loopback + flags health check
uv run --with playwright python scripts/cdp_agent_test.py   # external-agent smoke test
```

## Setup workflow

1. Preflight: confirm `/Applications/Google Chrome.app` exists and `/Applications` is
   writable; note profile size with `du -sh ~/Library/Application\ Support/Google/Chrome`.
2. Run `scripts/setup_chrome_cdp.sh [port]`. It is idempotent and:
   - quits Chrome cleanly (session restores on relaunch)
   - clones `~/Library/Application Support/Google/Chrome` → `Chrome-CDP` (`cp -Rc`;
     skipped if the clone already exists)
   - builds `/Applications/Google Chrome CDP.app` (Chrome's own icon, ad-hoc signed)
   - swaps the Dock's Chrome tile for the wrapper (Dock prefs backed up first) and
     restarts the Dock
   - launches the wrapper and waits for `http://127.0.0.1:<port>/json/version`
3. Confirm with `scripts/verify_cdp.sh [port]` — expect version JSON plus a
   `127.0.0.1:<port> (LISTEN)` line.
4. Prove end-to-end with `cdp_agent_test.py` — it connects from an independent process,
   lists the real tabs, opens its own tab, rewrites the DOM, screenshots, and
   disconnects leaving Chrome running.

## Connecting agents

- Playwright: `chromium.connect_over_cdp("http://127.0.0.1:9222")`
- Puppeteer: `puppeteer.connect({ browserURL: "http://127.0.0.1:9222" })`
- Raw WS: re-fetch `webSocketDebuggerUrl` from `/json/version` each launch (it rotates).
- Python agents need only `pip install playwright` or `uv run --with playwright` — no
  `playwright install` browser download, since they attach to the running Chrome.

## Rules that prevent breakage

- Always start Chrome from the Dock icon. Spotlight, Chrome's "Relaunch to update", or
  a link click while Chrome is closed all launch the non-CDP default-profile instance —
  quit it and relaunch from the Dock.
- Never run both instances at once (session divergence, duplicate extension connections).
- The CDP server takes a few seconds after launch: poll with
  `curl --retry 30 --retry-delay 1 --retry-all-errors`.
- The active profile may be `Profile N`, not `Default` — read `profile.last_used` from
  the clone's `Local State` before asserting the clone is broken.
- Loopback only: never add `--remote-debugging-address`. Any local process can drive
  the browser and read that profile's cookies — the machine is the trust boundary.

## Details

Gotchas, troubleshooting, raw-CDP notes, and revert steps: see [REFERENCE.md](REFERENCE.md).
