# Chrome CDP Setup — Reference

## Why a separate profile directory is mandatory

Since Chrome 136 (2025), `--remote-debugging-port` and `--remote-debugging-pipe` are
ignored when Chrome runs on the default user-data-dir
(`~/Library/Application Support/Google/Chrome`) — an anti-cookie-theft hardening. The
flag works only with `--user-data-dir` pointing somewhere else. Verified on Chrome 150
and 152: flags show in `ps` but nothing listens until a non-default dir is used.

"Default" is decided on the resolved path (`chrome::IsUsingDefaultDataDirectory()`,
consulted by `chrome/browser/devtools/remote_debugging_server.cc`), and the check fails
closed — when Chrome cannot tell, it treats the dir as default:

- Spelling the default path out in `--user-data-dir=` changes nothing.
- `--user-data-dir=default` is a **relative** path: Chrome creates a blank profile named
  `default` under the cwd. It listens, with none of your state.
- `--profile-directory=Default` is a different knob (a sub-profile inside a data dir)
  and does not help — no listener, no `DevToolsActivePort`.
- Chrome is single-instance per data dir: if the real Chrome is already running, a
  second launch with flags hands off to the existing process and the flags never apply.
- The refusal is logged to stderr only (`DevTools remote debugging requires a
  non-default data directory`), so a Dock or `open -a` launch shows nothing; run the
  binary from a terminal to see it.
- The `RemoteDebuggingAllowed` enterprise policy can only turn remote debugging off; it
  neither lifts the default-dir rule nor skips the approval prompt below.

Cloning the real profile into the new dir keeps every login, bookmark, and extension:

- Quit Chrome first — cloning a live profile tears SQLite files.
- `cp -Rc` uses APFS copy-on-write clonefile: instant, near-zero disk (falls back to
  plain `cp -R` on non-APFS).
- Cookie/password decryption survives the copy because Chrome's "Chrome Safe Storage"
  key lives in the macOS Keychain, not in the profile dir. (Windows app-bound cookie
  encryption can refuse a moved profile; this skill is macOS-only.)
- Delete stale `Singleton*` entries in the clone (`find <dir> -maxdepth 1 -name
  'Singleton*' -delete` — a bare `rm Singleton*` aborts under zsh when there are no
  matches).
- The active profile folder is often `Profile N`, not `Default`. Read
  `profile.last_used` from the clone's `Local State` to find it before declaring the
  clone broken.
- The clone is a fork, not a mirror: from the switch on, the clone is the daily driver
  and the original is a frozen fallback. Nothing re-seeds in either direction.

## Approval mode (`chrome://inspect/#remote-debugging`, Chrome 144+)

Chrome 144 added a toggle at `chrome://inspect/#remote-debugging` that starts a DevTools
server on the **default** profile with no flag at all. Read against
`chrome/browser/devtools/remote_debugging_server.cc` and
`content/browser/devtools/devtools_http_handler.cc` at the 152 tag:

- The toggle persists in `Local State` (`devtools.remote_debugging.user-enabled`), and
  a pref listener starts or stops the server as it changes, so every later flag-less
  launch comes up in this mode.
- The port comes from the default profile's `DevToolsActivePort` (9222 when the file is
  absent) and is written back there. If the port is busy the server falls back to a
  random free one — unlike flag mode, which then starts no server at all.
- Every HTTP endpoint (`/json/version`, `/json/list`, `/`) answers a bare 404. Playwright
  reports `Unexpected status 404 ... This does not look like a DevTools server`.
- A WebSocket upgrade to any path under `/devtools/browser` (no GUID needed) opens a
  browser-modal "Allow remote debugging?" dialog on the last-active window and holds the
  handshake until a human answers; Cancel returns `403 Connection rejected`.
- `--remote-debugging-port` and `--remote-debugging-pipe` take precedence over this
  mode, so the Dock wrapper keeps flag-mode HTTP discovery with no prompt even though
  the clone's `Local State` carries the toggle too.

Signature of a wrong-instance launch on a Chrome with the toggle on:

- `lsof -nP -iTCP:9222 -sTCP:LISTEN` shows Google Chrome, yet
  `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9222/json/version` prints 404.
- `ps -axo command | grep 'MacOS/Google Chrome --remote-debugging-port'` matches nothing.
- `~/Library/Application Support/Google/Chrome/DevToolsActivePort` — the **default**
  profile's — exists. It outlives the instance that wrote it, so on its own it proves
  nothing; the two live signals above do.

`verify_cdp.sh` prints exactly this verdict. Fix: quit that Chrome, then relaunch from
the Dock. Order matters: flag mode binds its port with no fallback, so a wrapper
launched while the approval-mode instance still holds 9222 comes up with no CDP at all
(`verify_cdp.sh` calls that `PORT STOLEN`; `setup_chrome_cdp.sh` refuses to build on a
held port for the same reason).

The prompt cannot be disabled, pre-approved, or remembered:

- No launch flag, no `chrome://flags` entry, no "remember my choice"; the enterprise
  policy only turns remote debugging off. Persisting the approval was requested
  upstream (chrome-devtools-mcp #825) and closed as not planned; the prompt also stacks
  up, one per client, when several connect at once (#1794, open).
- Synthesizing the Allow click or patching Chrome fights a security control and breaks
  on minor updates. Leave the click to the user: it is their consent gate.
- A prompt nobody answers stays open on that window, one per attempt, until cancelled
  by hand. Clicking Allow on a stale one approves nothing and leaves the "controlled by
  automated test software" infobar until its X is clicked.

Attaching to the real profile in this mode anyway (human present):

```bash
PLAYWRIGHT_MCP_CDP_TIMEOUT=0 playwright-cli attach --cdp=chrome
```

- `--cdp=chrome` (a channel name, accepted by playwright-cli 0.1.19) reads the default
  profile's `DevToolsActivePort` and connects to `ws://localhost:<port>/devtools/browser`
  directly, skipping the HTTP step that 404s. `--cdp=http://…` against this server can
  only fail.
- The connect deadline is 30 s by default, too short for someone at another screen.
  `PLAYWRIGHT_MCP_CDP_TIMEOUT` (milliseconds) reaches the attach daemon through the
  environment, and `0` removes the deadline. Measured on playwright-cli 0.1.19 against
  a socket that never answers: `4000` failed at 4 s, `0` was still waiting at 40 s.
- One approval per *connection*, not per command. Keep that one session and route every
  tool through it; a second tool opening its own connection prompts again.
- Per-tab access with no Chrome prompt is what `playwright-cli attach --extension=chrome`
  (the Playwright extension) is for. Its own approval popup takes a shared token from
  `PLAYWRIGHT_MCP_EXTENSION_TOKEN`; not exercised here.

## Wrapper app anatomy

`/Applications/Google Chrome CDP.app` is a minimal bundle: an `Info.plist` (unique
bundle id `com.archauto.chrome-cdp`), Chrome's own `app.icns` copied into Resources,
and a `launcher` shell script that `exec`s the real Chrome binary with the two flags
(prefixed with `arch -arm64` on Apple Silicon — see the Rosetta trap below).
Ad-hoc sign it (`codesign --force -s -`) and register with `lsregister -u` followed
by a plain `lsregister` — not `-f` alone (see the Rosetta trap). Locally created
bundles carry no quarantine attribute, so Gatekeeper does not complain.

## Rosetta trap (Apple Silicon)

Observed 2026-07-21 on an M2: the wrapper made the entire Chrome tree run x86_64
under Rosetta 2 — four renderers pegged at ~100% CPU each on workloads that should
have been light, load average 15+, every JS worker paying the translation tax.

Mechanism:

- LaunchServices **snapshots the wrapper's `Info.plist` at registration** and keys
  freshness on file mtime. If the bundle is created/rewritten twice within the same
  second (typical when a script or agent iterates), LS keeps the first snapshot
  forever — even `lsregister -f` does not replace it. Only `lsregister -u <app>`
  followed by re-registration purges it.
- If that stale snapshot contains `LSArchitecturePriority = (x86_64, arm64)`, LS
  launches the wrapper's `/bin/bash` translated, and **`exec` preserves Rosetta
  translation into the universal Chrome binary** and all its helpers. Nothing in
  Chrome's own plist or binary is wrong; the wrapper's LS record alone decides.

Diagnosis (fast):

```bash
lsappinfo info -app com.google.Chrome | grep -io "Arch=[a-z0-9_]*"  # want ARM64 (arm64 on older macOS)
sample <renderer-pid> 1 2>/dev/null | grep "Code Type"    # "X86-64 (translated)" = Rosetta
lsregister -dump | grep -B4 -A6 "com.archauto.chrome-cdp" # look for LSArchitecturePriority
```

`lsappinfo` prints `Arch=arm64` on older macOS and `Arch=ARM64` on macOS 26 — match
case-insensitively, or a healthy native Chrome reads as Rosetta.

Fix: quit Chrome, `lsregister -u "/Applications/Google Chrome CDP.app"`, re-register
with plain `lsregister <app>`, relaunch from the Dock. Prevention (both baked into
`setup_chrome_cdp.sh`): the launcher script uses `exec arch -arm64 ...` on Apple
Silicon so even a bad LS record cannot force Rosetta, and setup registers with
`-u` + re-register instead of `-f`.
(`lsregister` lives at `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`.)

## Dock tile swap

Never edit `~/Library/Preferences/com.apple.dock.plist` directly — cfprefsd caching
will clobber it. Round-trip through `defaults`:

1. `defaults export com.apple.dock backup.plist` (keep the first backup forever)
2. Edit a working copy with Python `plistlib`: find the `persistent-apps` tile whose
   `_CFURLString` contains `Google%20Chrome.app`, replace the whole tile (this drops
   the `book` bookmark blob, which would otherwise override the URL).
3. `defaults import com.apple.dock work.plist && killall Dock`

## Verification signals

`verify_cdp.sh` prints all of these and ends with a verdict (`OK`, `APPROVAL MODE`,
`PORT STOLEN`, `PORT TAKEN`, `NOT LISTENING`, `DOWN`, `UNHEALTHY`); exit status is 0
only on `OK`.

- `curl http://127.0.0.1:<port>/json/version` → JSON with `webSocketDebuggerUrl`.
  The server needs a few seconds after launch; the first curl racing startup and
  failing is normal. Use `--retry 30 --retry-delay 1 --retry-all-errors`. A 404 with a
  listener present is approval mode, not a slow start — no retry helps.
- `lsof -nP -iTCP:<port> -sTCP:LISTEN` → must show `127.0.0.1:<port>` (loopback only;
  Chrome binds IPv4 first, and `[::1]` does not answer).
- `ps -axo command | grep 'MacOS/Google Chrome --remote-debugging-port'` → confirms the
  flags on the live main process. Helpers repeat the flag; only the main process's
  command starts with the Chrome binary itself.
- `DevToolsActivePort`: flag mode with an explicit port writes **none** (Chrome writes
  it only for `--remote-debugging-port=0`), so the clone never has one. The file under
  the **default** profile is written by approval mode and lingers after that instance
  quits.
- Apple Silicon: `lsappinfo info -app com.google.Chrome | grep -io 'Arch=[a-z0-9_]*'`
  must read `ARM64` (lowercase on older macOS); `X86_64` is the Rosetta trap.

## Connecting

```python
# Playwright (Python) — pip install playwright; no `playwright install` needed
browser = p.chromium.connect_over_cdp("http://127.0.0.1:9222", timeout=120_000)
ctx = browser.contexts[0]          # the real logged-in context
```

```js
// Puppeteer
const browser = await puppeteer.connect({ browserURL: "http://127.0.0.1:9222" });
```

```bash
# playwright-cli: one long-lived session; later commands reuse it
playwright-cli attach --cdp=http://127.0.0.1:9222
playwright-cli tab-new https://example.com   # tab-new, not goto: goto navigates the user's current tab
```

Raw CDP: `GET /json/version` for the browser WebSocket URL (rotates every launch —
always re-fetch), `GET /json` for targets, and note `/json/new?url=...` requires
`PUT` on Chrome 111+. `browser.close()` after `connect_over_cdp` only disconnects;
it does not kill Chrome.

The first attach to a long-running daily driver can exceed the default 30 s connect
timeout: `connect_over_cdp` attaches to every target (tabs, iframes, service workers)
and waits for each, and renderers Chrome has frozen answer slowly. Measured here with
~35 tabs: 14 s, then 1 s on retry. Pass a longer timeout, or retry once.

## Gotchas

- **Wrong-instance launches**: Spotlight, "Relaunch to update", or a link click while
  no Chrome is running start plain `Google Chrome.app` — default profile, no flag-mode
  CDP, and with the `chrome://inspect` toggle on, port 9222 held in approval mode. Quit
  it and relaunch from the Dock icon. While the CDP instance IS running, link clicks
  from other apps route to it correctly (LaunchServices targets the running process).
- **Never run both instances simultaneously**: sessions diverge (sites may rotate
  cookies and log one out) and duplicated extensions (e.g. claude-in-chrome) open
  duplicate connections.
- **The original profile goes stale** the moment the clone becomes the daily driver.
  Treat it as a frozen fallback; new browsing state lives only in `Chrome-CDP`.
- **`--cdp=chrome` cannot reach the wrapper**: it resolves through the default profile's
  `DevToolsActivePort` and connects without the browser GUID, which flag mode requires.
  Use `--cdp=http://127.0.0.1:9222` for the wrapper and `--cdp=chrome` only for a
  flag-less Chrome in approval mode.

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
