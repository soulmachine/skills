# Reference: cua sandbox VMs on lume

Diagnostics, traps, and the version history behind [SKILL.md](SKILL.md). Everything here was
verified on a Mac Studio M3 Ultra / macOS 26.6.1 host with lume 0.5.3 and cua-driver 0.20.0, against
guest macOS 26.4 (build 25E246), unless a date says otherwise.

---

## 1. What the images actually contain

Read from the registry without pulling (`ghcr.io/v2/trycua/<image>/manifests/latest`):

| | `macos-tahoe-vanilla:latest` | `macos-tahoe-cua:latest` |
|---|---|---|
| layers | 201 | 301 |
| compressed | 19 GB | 21 GB |
| default disk | 100 GB | 150 GB |
| uploaded | 2026-03-25 | 2026-07-15 |
| tags | `latest`, `26.2`, `26.2-oci` | `latest`, `26.2`, `26.5.2` |

Then pulled and inspected in-guest:

| | vanilla | cua |
|---|---|---|
| SIP | enabled | **disabled** |
| Autologin / Aqua session on first boot | no | **yes** |
| Xcode Command Line Tools | not checked | **yes** (`/Library/Developer/CommandLineTools`) |
| `CuaDriver.app` | no | **no** |
| `cua-computer-server` | no | **no** (no venvs, `pip list` empty) |
| TCC grants pre-applied | no | **no** |
| Homebrew | no | no |
| `lume`/`lume` admin account + SSH | yes | yes |

The vanilla image is stock macOS. Its entire `/Applications` is `Safari.app` and `Utilities`:

```bash
csrutil status                      # -> enabled
ls -d /Applications/CuaDriver.app   # -> No such file or directory
which brew                          # -> nothing; python3 is only /usr/bin/python3
```

**"Pre-provisioned" on the cua image means the environment, not the cua software.** The payoff is
SIP-off and autologin. The cua image also pre-seeds a `kTCCServiceAccessibility` row for
`com.trycua.driver` with `auth_value=0` — *denied* — which changes how you write the grant (§3).

---

## 2. The load-bearing finding: vanilla images have no autologin

**A pulled `macos-*-vanilla` image boots to the login window, not to a desktop.** Autologin comes
from `lume create --unattended` or `lume setup <vm>`, neither of which runs on a plain `lume pull`.

Diagnose it in one command — the console owner *is* the answer:

```bash
lume ssh <vm> "stat -f '%Su' /dev/console"
# root  -> no Aqua session (login window)
# lume  -> a real GUI session exists
```

Everything cua needs collapses without that session, and the three symptoms look unrelated until you
check `/dev/console`:

| Symptom | Actual cause |
|---|---|
| `open -n -g -a CuaDriver --args serve` → `OSLaunchdErrorDomain Code=125 "Domain does not support specified action"` | no Aqua launchd domain to launch a GUI app into |
| `~/Library/LaunchAgents/*.plist` never loads; `launchctl list` shows nothing | LaunchAgents load per-GUI-session; there is no session |
| `cua-driver permissions status --json` → `{"daemon_running": false, "status": "unknown"}` | no daemon can run, so TCC status is unreadable |

Fix, with the VM stopped: `lume setup <vm> --unattended tahoe` — an offline disk patch that skips
Setup Assistant, creates the `lume` user, enables autologin + SSH, disables the screensaver lock,
verifies SSH, then stops the VM.

**SSH working is not evidence of a GUI session.** The vanilla image ships a working `lume`/`lume`
admin account with SSH enabled, which is exactly what makes this misleading. Never infer the session
from SSH — boot the VM and read `/dev/console`.

`--unattended` also accepts a **YAML path** instead of a preset name. The built-in presets live at
`lume.app/Contents/Resources/lume_lume.bundle/unattended-presets/{tahoe,sequoia}.yml` and support a
top-level `post_ssh_commands:` list (alongside `boot_wait`, `boot_commands`, `health_check`) that
lume runs over SSH during the verification boot — an alternative place to hang provisioning steps.

---

## 3. Scripting the TCC grants with SIP off

cua's docs say *"SSH access read-only; cannot raise macOS permission UI remotely"* — the grants must
be clicked at the VM's screen. **That is true with SIP enabled.** On `macos-tahoe-cua`, SIP ships
disabled, which makes `TCC.db` writable as root, and the whole provision becomes unattended.

```bash
lume ssh <vm> "echo lume | sudo -S sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' \"
  INSERT OR REPLACE INTO access
    (service,client,client_type,auth_value,auth_reason,auth_version,
     indirect_object_identifier_type,indirect_object_identifier,flags)
  VALUES
    ('kTCCServiceAccessibility','com.trycua.driver',0,2,3,1,0,'UNUSED',0),
    ('kTCCServiceScreenCapture','com.trycua.driver',0,2,3,1,0,'UNUSED',0),
    ('kTCCServicePostEvent','com.trycua.driver',0,2,3,1,0,'UNUSED',0),
    ('kTCCServiceListenEvent','com.trycua.driver',0,2,3,1,0,'UNUSED',0);\"
  echo lume | sudo -S killall tccd"
lume ssh <vm> "launchctl kickstart -k gui/\$(id -u)/com.trycua.driver"
```

- **`INSERT OR REPLACE`, not `INSERT`.** The image pre-seeds a denied `kTCCServiceAccessibility` row
  for `com.trycua.driver`; a plain INSERT collides with the primary key
  `(service, client, client_type, indirect_object_identifier)`.
- `auth_value=2` is allow, `auth_reason=3`, `auth_version=1`, `client_type=0` (bundle id). macOS 26.4
  uses the familiar 17-column `access` table, and a NULL `csreq` is accepted while SIP is off.
- **`killall tccd` matters** — tccd caches; without it the change is not observed.
- **The driver only picks up a changed grant after a full relaunch** (`launchctl kickstart -k`).
- **The grants survive a guest reboot**, and the LaunchAgent restarts the daemon on its own.

Result, with nobody at the VM's screen: `{"accessibility": true, "screen_recording": true}`, and
`cua-driver call get_desktop_state '{}'` returns a real PNG.

### The one grant that is NOT in TCC.db: Tahoe's direct capture

After provisioning, a modal is left sitting on the guest's desktop:

> *"CuaDriver" is requesting to bypass the system private window picker and directly access your
> screen and audio.* — **Allow** / **Open System Settings**

This is the third item in cua-driver's own list ("Accessibility, Screen Recording, **and Tahoe's
direct-capture consent**") and it is **separate from the four TCC rows above**. Confirmed 2026-08-17
by clicking Allow and re-reading state: **no new row appears in
`/Library/Application Support/com.apple.TCC/TCC.db`**, so this consent is stored elsewhere and cannot
be granted with the SQL above.

What it does and does not affect:

- **Full-display capture works without it.** `get_desktop_state` returned a correct 1920x1080 PNG
  both before and after the dialog was answered.
- **The modal itself is the problem.** It is focused and on top, so it will interfere with UI
  automation until dismissed — and a screenshot of a "provisioned" VM will show a permission prompt.
- **`direct_capture_status` does not track it.** The field reads `"not_checked"` both before and
  after granting; it means the daemon has not run a direct-capture probe, not that consent is
  missing. Do not use it as a grant check — `cua-driver permissions grant` is what runs the probe.

Dismiss it once at the VM's screen (`lume run <vm> --display vnc`), or have the driver click its own
dialog — Accessibility and PostEvent are already granted, so it can. Then `lume clone` the result as
a golden image so no future rebuild sees it again.

### When SIP is on (vanilla image)

The grants must be clicked at the VM's screen. Two traps:

- Toggling the switch in System Settings is required; clicking "Open System Settings" is not enough.
- When macOS offers to quit and reopen CuaDriver after a toggle, **accept** — see the relaunch note
  above.

`xcode-select --install` and the Homebrew bootstrap also need interactive sudo, so the practical
structure is *one* sitting at the VM screen rather than several. Then `lume clone` the result so you
never do it again.

### Does cua-driver need SIP disabled at runtime?

**No.** With SIP *enabled*, `cua-driver doctor` is all-green and never mentions SIP, and the
installer completes with no privilege escalation. The driver's mechanism is TCC, which is orthogonal
to SIP — cua installs on ordinary Macs with SIP on. SIP-off buys **provisioning automation**, nothing
at runtime.

---

## 4. cua-driver specifics

Install (no sudo required — the `lume` user is in `admin`, and `/Applications` is admin-writable):

```bash
curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-install.sh && bash /tmp/cua-install.sh
```

- Installs `/Applications/CuaDriver.app` plus a `~/.local/bin/cua-driver` symlink to it.
- **A LaunchAgent must invoke the in-bundle path**, `/Applications/CuaDriver.app/Contents/MacOS/cua-driver`,
  so the process keeps the app's code signature and therefore its TCC identity (`com.trycua.driver`).
- `cua-driver autostart` is **Windows-only today** — on macOS you hand-roll the LaunchAgent.
- `permissions status` is read-only and answers *via a running daemon*; with no daemon it reports
  `unknown`, never your terminal's grants. `permissions grant` is the interactive path — it launches
  the app via LaunchServices so dialogs attribute correctly.
- Permission modes: `standard` (promptless default), `bounded` (needs a reviewed capability
  manifest), `unrestricted` (needs `--dangerously-bypass-approvals`).
- Two CLI shapes, both real: `cua-driver list_apps '{}'` vs `cua-driver call get_desktop_state '{}'`.

### 0.20.0 (2026-08-17) — three things changed

`install.sh` now resolves a "baked release", `cua-driver-rs-v0.20.0`, shipped as
`cua-driver-rs-<ver>-darwin-universal.tar.gz` (a Rust rewrite).

- **`permissions status --json` changed shape.** No more `daemon_running` / `status`; it returns
  `accessibility` and `screen_recording` booleans plus a `source` block naming the responsible
  process. **Any check grepping for `daemon_running` silently reports failure on a healthy install.**
- **There is no `take_screenshot` tool.** Capture is `get_desktop_state`. The old name fails with
  `Permission denied: tool 'take_screenshot' has no reviewed risk classification` — that reads like a
  TCC error but is the driver's own tool-manifest gate. `cua-driver list-tools` is the authority.
- New subcommands: `list-tools`, `describe`, `manifest`, `skills`, `sessions`, `channel`,
  `cursor-theme`, `diagnose`.

Version skew is tolerated: the `cua_driver` Python SDK wheel is 0.12.5 while the CLI/daemon was
0.19.3, and daemon mode worked fine across that gap.

---

## 5. lume quirks

### `lume set --display` never reaches the guest

It makes the mode **available** to the virtual GPU; macOS keeps rendering at whatever it used before.
`lume ls` reported `1920x1080` while the guest sat at 1024x768 — and cua-driver screenshots at the
*guest's* resolution, so captures came back 1024x768. `displayplacer list` confirmed 1920x1080 *was*
offered as mode 20, so the flag did reach the GPU; only macOS's chosen mode was stale.

```bash
curl -fsSL -o ~/.local/bin/displayplacer \
  https://github.com/jakehilborn/displayplacer/releases/download/v1.4.0/displayplacer-apple-v140
chmod +x ~/.local/bin/displayplacer
ID=$(displayplacer list | awk '/^Persistent screen id:/ {print $4; exit}')
displayplacer "id:$ID res:1920x1080 hz:60 color_depth:7 enabled:true scaling:off origin:(0,0) degree:0"
```

The GitHub `latest/download/displayplacer` path 404s — the asset is named `displayplacer-apple-v140`.

### `lume stop` is unreliable

Observed both a silent no-op leaving the VM running, and — from `stop` itself — `Error: Cannot modify
<vm>: the VM is running. Stop it first.` The REST API (`POST :7777/lume/vms/<vm>/stop`) was equally
ineffective. Terminating the `lume run <vm>` process works and is what stop would do anyway. Match
with a trailing space so `foo` does not also kill `foo-golden`.

### Image cache and cloning

- Caching is on by default (`lume config get` → `Caching enabled: true`); layers live in
  `~/.lume/cache/ghcr/<org>/sha256_<manifest>/sha256_<layer>`.
- **Only the current manifest per image is kept.** A pull ends with `Checking for old versions of
  image to clean up current_manifest_id=sha256_…`, so when a `:latest` tag moves upstream the old
  layers are dropped — a tag that looks unchanged can still cost a full re-download.
- Budget for both: the cache holds the image (~21 GB) *in addition to* the materialized VM (~26 GB).
- `lume prune` removes **all** cached images; the next pull re-downloads from scratch.
- **`lume clone` is APFS copy-on-write** — ~2 s and ~0 bytes. Keep one pristine VM as a golden image
  and clone from it. Never delete every copy of a VM; a surviving clone makes a rebuild instant.
- `lume images` lists the **local cache only**, not the registry. To enumerate remote tags, query
  ghcr directly.

### `lume set --disk-size` is increase-only

And the image defaults differ — 100 GB (vanilla) vs 150 GB (cua). `--disk-size 128GB` succeeds on the
former and is **rejected as a shrink** on the latter. The resize relocates the recovery partition and
expands the APFS container; it took 17 s for 100→128 GB. `--no-backup` skips the pre-resize backup,
`--dry-run` prints the plan.

### `lume sip off` is broken against Tahoe recoveryOS (0.5.1)

Two distinct failures. First run is a **race**: lume boots the VM to validate credentials, stops it,
then starts the recovery boot before the previous process released `nvram.bin` →
`Failed to lock auxiliary storage`. Retrying clears it.

Second run is a **deterministic UI-automation bug**:

```
Error: VNC driver timeout: Framebuffer for 'csrutil prompt' did not contain expected text
```

The `--screenshot-dir` frames show `04-terminal-opened.png` and `05-csrutil-prompt.png` are
byte-identical and both show the **"About Recovery" window**, not Terminal — lume's menu navigation
picks the wrong item on Tahoe's Recovery menu bar. Always pass `--screenshot-dir`; it is what makes
this diagnosable. Rollback: `lume sip on <vm> --yes`.

This is moot if you use `macos-tahoe-cua`, which already ships SIP off.

### Undocumented: `lume run --recovery-mode`

Absent from `lume run --help` in 0.5.1 but real, found via `lume dump-docs`. The **value is required**:

```bash
lume run <vm> --recovery-mode true --display none --vnc-port 5999
```

This is the hook for driving recoveryOS manually with `vncdo` when lume's automation fails. With
`--display none` the VNC password lands in `~/.lume/<vm>/sessions.json` (`jq -r '.url'`), not in the
command output.

### Other

- **API port is `:7777`**, not `:3000`. A `lume serve --port 7777` daemon can silently start VMs in
  the background.
- `vncdotool` 1.3.0 (a `lume sip` prerequisite) supports Python ≤ 3.13. On a host whose default
  `python3` is 3.14, `pip3 install vncdotool` fails — use `uv tool install --python 3.13 vncdotool`.
- `lume run --clipboard` was **absent in 0.5.1 and is back in 0.5.3** ("bidirectional clipboard sync
  via SSH; automatic for native macOS display"). 0.5.3 also un-hid `--vnc-port` / `--recovery-mode`
  and added `--vnc-password`, `--network`, `--disk-path`, `--nvram-path`. Verify flags against the
  installed version rather than trusting any list.
- **Shared dirs are reported as absent even when mounted.** `lume ls` shows an empty `shared_dirs`
  column and the API returns `sharedDirectories: null`, while inside the guest
  `/Volumes/My Shared Files/<name>` is mounted over AppleVirtIOFS. Cosmetic gap, not a failure.

### Terminfo: install per-user, and `lume ssh` eats stdin

SSHing into a stock guest from Ghostty (or kitty/WezTerm) gives `unknown terminal type
xterm-ghostty` — no colors, broken arrows and backspace. The fix is to compile the host's entry
into the guest's `~/.terminfo`, which ncurses already searches first on stock macOS:

```
$ infocmp -D
/Users/lume/.terminfo
/usr/share/terminfo
```

Nothing else is needed — no `TERMINFO_DIRS`, no `/etc/zshenv` or `/etc/profile` edit, no sudo. Two
things to know anyway.

**The system terminfo dir cannot be written, SIP off or not**, so a system-wide install is not the
easy alternative it looks like. macOS mounts `/` from a *sealed* APFS snapshot:

```
$ mount | grep 'on / '
/dev/disk4s1s1 on / (apfs, sealed, local, read-only, journaled)
$ sudo tic -x -o /usr/share/terminfo -    # even as root, csrutil disabled
tic: /usr/share/terminfo: Read-only file system
```

SIP being disabled is irrelevant — the read-only system volume is the Signed System Volume, and
writing it means `csrutil authenticated-root disable` plus a reboot. The writable data-volume
substitute, `/usr/local/share/terminfo`, is *not* on the compiled-in search path, so going that
route drags in `TERMINFO_DIRS` exported from both `/etc/zshenv` (zsh sources it on every
invocation) and `/etc/profile` (a clean-env bash login shell gets nothing from zshenv) — three
root-owned files patched to serve the one user the sandbox has. `~/.terminfo` costs none of that.

**`lume ssh` does not forward stdin.** The canonical one-liner hangs and then dies:

```
$ echo hi | lume ssh nickel cat
Error: SSH operation timed out
```

So `infocmp -x xterm-ghostty | lume ssh vm tic -x -` cannot work. `provision.sh` base64s the
terminfo source into the command string instead. (Raw `ssh lume@<ip>` *does* pipe fine — this is a
`lume ssh` wrapper limitation, not an SSH one.)

`tic` prints `older tic versions may treat the description field as an alias` on these entries and
still exits 0, so the check that counts is reading the entry back:

```
$ lume ssh "$VM" 'infocmp xterm-ghostty >/dev/null && echo OK'
```

---

## 6. Path B: the HTTP API (`cua-computer-server`)

`--backend cua-driver` is real, but **a PyPI install cannot reach it**. PyPI's latest release and git
`main` both report `cua-computer-server 0.3.42` while being different code:

| | PyPI `0.3.42` | git `main` (also `0.3.42`) |
|---|---|---|
| `--backend` choices | `{native, vnc}` | `{native, vnc, `**`cua-driver`**`}` |
| `--driver-mode` / `--capture-scope` | absent | `{embedded, daemon}` / `{auto, window, desktop}` |
| `[driver]` extra | **does not exist** | exists — pulls the `cua_driver` SDK wheel |

So `pip install "cua-computer-server[driver]"` from PyPI installs a **nonexistent extra**, and
`--backend cua-driver` dies with `invalid choice: 'cua-driver'`. The version number gives no hint.
Omitting `[driver]` still *parses* the flag, then fails at startup with
`RuntimeError: CUA_BACKEND=cua-driver requires cua-computer-server[driver]`.

```bash
python3 -m venv ~/.venvs/cua-main
~/.venvs/cua-main/bin/pip install \
  'cua-computer-server[driver] @ git+https://github.com/trycua/cua.git#subdirectory=libs/python/computer-server'
~/.venvs/cua-main/bin/python -m computer_server --host 0.0.0.0 --port 8000 \
  --backend cua-driver --driver-mode daemon --capture-scope desktop
# confirm via log line: "Using Cua Driver automation backend (daemon mode)"
```

### Why `cua-driver` beats `native` — measured

Identical `POST /cmd {"command":"screenshot"}`, same guest, two backends:

```
cua-driver :8001 -> {"success": true,  "image_data": "iVBORw0KGgo..."}   # 2.3 MB PNG
native     :8000 -> {"success": false, "error": "Screenshot error:
                     Command '['screencapture','-x',...]' returned non-zero exit status 1"}
```

`native` shells out to `screencapture` under **the venv python's own TCC identity**, which holds no
Screen Recording grant — so it fails even though `CuaDriver.app` is fully granted. `--driver-mode
daemon` routes through the running CuaDriver daemon and inherits `com.trycua.driver`'s grants, so
Path A and Path B share **one** permission identity instead of two.

Prefer `--backend cua-driver` on macOS. `native` only makes sense if you deliberately want an
automation identity separate from the driver, and will grant Screen Recording to a bare Python
interpreter to get it.

Harmless noise: `could not create image from display` prints at import time, even from `--help`.

---

## 7. Don't rename the `lume` guest account

Tempting on a fresh VM. Don't — treat `lume` as an infrastructure service account.

- **lume has no first-class way to choose the username.** The unattended presets are only `sequoia`
  and `tahoe`, and the YAML path is for "compatibility and optional post-SSH commands", not naming.
  `lume dump-docs` states *"VMs created with `--unattended` use lume/lume credentials by default"*.
- **Every lume convenience command defaults to it**: `lume ssh` (`--user lume --password lume`),
  `lume sip on/off` (`--admin-user lume`), `lume setup --unattended` (creates the `lume` user).
- **cua hardcodes `/Users/lume`** — its docs, the MCP registration shape, and the LaunchAgent path.
- **macOS short-name renames are genuinely fiddly**: change `RecordName` *and* `NFSHomeDirectory` via
  `dscl`, move the home directory, do it while logged in as a *different* admin, then chase keychain
  and permission fallout.
- **The security gain is ~zero.** The weak part of `lume`/`lume` is the password, and the guest sits
  on host-only NAT (192.168.64.0/24) the LAN cannot reach. Change the password and keep the name:
  `dscl . -passwd /Users/lume '<newpass>'`.

The one exception is a long-lived *personal workstation* VM you drive directly — but create that
account fresh during setup, never by renaming `lume`. Wanting a VM to feel personal usually means it
should be a different VM from the agent sandbox.

---

## 8. MCP wiring that survives reboots

cua's docs bake `VM_IP` into the MCP registration, but a NAT VM's IP drifts across reboots and the
MCP server then fails silently. `scripts/cua-mcp-wrapper.sh` re-resolves at connect time instead.

Host-key checking is disabled **deliberately**: a rebuilt guest reusing a NAT IP otherwise trips
`REMOTE HOST IDENTIFICATION HAS CHANGED` and breaks the transport with no visible error. This is
sound only for a local NAT-only sandbox — never a pattern for anything routable.

**stdout is the JSON-RPC channel**, so the wrapper must keep every diagnostic on stderr.

---

## 9. Provenance

Compiled from a provisioning run on 2026-08-14 (vanilla image, lume 0.5.1, cua-driver 0.19.3) and a
rebuild on 2026-08-17 (cua image, lume 0.5.3, cua-driver 0.20.0) that verified the image contents and
the unattended TCC path. Previously carried as `raw/agent-notes/cua-nickel-vm-setup.md` in the
author's llm-wiki vault; related vault notes that did not travel here:
`raw/agent-notes/cua-mac-mini-host-and-lume-sandbox.md` (the two-scenario architecture this applies),
`raw/agent-notes/agent-sandbox.md` (macOS sandbox landscape, the 2-guest XNU cap), and
`raw/agent-notes/macos-ssh-tcc-fix.md` (the host-side analogue: `sshd` needing Full Disk Access).

Upstream docs: <https://cua.ai/docs/how-to-guides/driver/run-in-macos-lume-vm.md>,
<https://cua.ai/docs/tutorials/drive-your-first-app.md>.
