# Chrome CDP Setup — Reference

## Why a separate profile directory is mandatory

Since Chrome 136 (2025), `--remote-debugging-port` and `--remote-debugging-pipe` are
silently ignored when Chrome runs on the default user-data-dir
(`~/Library/Application Support/Google/Chrome`) — an anti-cookie-theft hardening. The
flag works only with `--user-data-dir` pointing somewhere else. Verified on Chrome 150:
flags show in `ps` but nothing listens until a non-default dir is used.

Cloning the real profile into the new dir keeps every login, bookmark, and extension:

- Quit Chrome first — cloning a live profile tears SQLite files.
- `cp -Rc` uses APFS copy-on-write clonefile: instant, near-zero disk (falls back to
  plain `cp -R` on non-APFS).
- Cookie/password decryption survives the copy because Chrome's "Chrome Safe Storage"
  key lives in the macOS Keychain, not in the profile dir.
- Delete stale `Singleton*` entries in the clone (`find <dir> -maxdepth 1 -name
  'Singleton*' -delete` — a bare `rm Singleton*` aborts under zsh when there are no
  matches).
- The active profile folder is often `Profile N`, not `Default`. Read
  `profile.last_used` from the clone's `Local State` to find it before declaring the
  clone broken.

## Wrapper app anatomy

`/Applications/Google Chrome CDP.app` is a minimal bundle: an `Info.plist` (unique
bundle id `com.archauto.chrome-cdp`), Chrome's own `app.icns` copied into Resources,
and a `launcher` shell script that `exec`s the real Chrome binary with the two flags.
Ad-hoc sign it (`codesign --force -s -`) and register with `lsregister -f`. Locally
created bundles carry no quarantine attribute, so Gatekeeper does not complain.

## Dock tile swap

Never edit `~/Library/Preferences/com.apple.dock.plist` directly — cfprefsd caching
will clobber it. Round-trip through `defaults`:

1. `defaults export com.apple.dock backup.plist` (keep the first backup forever)
2. Edit a working copy with Python `plistlib`: find the `persistent-apps` tile whose
   `_CFURLString` contains `Google%20Chrome.app`, replace the whole tile (this drops
   the `book` bookmark blob, which would otherwise override the URL).
3. `defaults import com.apple.dock work.plist && killall Dock`

## Verification signals

- `curl http://127.0.0.1:<port>/json/version` → JSON with `webSocketDebuggerUrl`.
  The server needs a few seconds after launch; the first curl racing startup and
  failing is normal. Use `--retry 30 --retry-delay 1 --retry-all-errors`.
- `lsof -nP -iTCP:<port> -sTCP:LISTEN` → must show `127.0.0.1:<port>` (loopback only).
- `<clone dir>/DevToolsActivePort` → first line is the active port.
- `ps -axo command | grep remote-debugging-port` → confirms the flags on the live process.

## Connecting

```python
# Playwright (Python) — pip install playwright; no `playwright install` needed
browser = p.chromium.connect_over_cdp("http://127.0.0.1:9222")
ctx = browser.contexts[0]          # the real logged-in context
```

```js
// Puppeteer
const browser = await puppeteer.connect({ browserURL: "http://127.0.0.1:9222" });
```

Raw CDP: `GET /json/version` for the browser WebSocket URL (rotates every launch —
always re-fetch), `GET /json` for targets, and note `/json/new?url=...` requires
`PUT` on Chrome 111+. `browser.close()` after `connect_over_cdp` only disconnects;
it does not kill Chrome.

## Gotchas

- **Wrong-instance launches**: Spotlight, "Relaunch to update", or a link click while
  no Chrome is running start plain `Google Chrome.app` — default profile, no CDP.
  Quit it and relaunch from the Dock icon. While the CDP instance IS running, link
  clicks from other apps route to it correctly (LaunchServices targets the running
  process).
- **Never run both instances simultaneously**: sessions diverge (sites may rotate
  cookies and log one out) and duplicated extensions (e.g. claude-in-chrome) open
  duplicate connections.
- **The original profile goes stale** the moment the clone becomes the daily driver.
  Treat it as a frozen fallback; new browsing state lives only in `Chrome-CDP`.

## Security

- CDP grants total control: any local process can drive the browser, read cookies,
  and act in every logged-in session of that profile. Acceptable only because the
  listener is loopback-bound — never pass `--remote-debugging-address`, never port-
  forward 9222 off the machine.

## Revert

```bash
defaults import com.apple.dock ~/Library/Preferences/com.apple.dock.backup-before-cdp.plist
killall Dock
rm -rf "/Applications/Google Chrome CDP.app"
# Only after confirming nothing in Chrome-CDP is needed (it holds all browsing
# state created since the switch):
rm -rf "$HOME/Library/Application Support/Google/Chrome-CDP"
```
