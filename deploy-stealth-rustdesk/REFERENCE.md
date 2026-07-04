# Deploy reference — rollback, redeploy, connection & stealth failures

Companion to [SKILL.md](SKILL.md) for `deploy-stealth-rustdesk`: uninstall, redeploying a rebuilt app, and debugging a connection or a stealth surface that leaks. For build failures, pins, and the fork, see the **`build-stealth-rustdesk`** skill and its `REFERENCE.md`.

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

## Redeploying a rebuilt app over a running install

After `build-stealth-rustdesk` produces a new `$APP` (e.g. a version bump), restage it on the target and:

```bash
launchctl bootout gui/$(id -u)/com.carriez.RustDesk_server; sudo launchctl bootout system/com.carriez.RustDesk_service
sudo rm -rf /Applications/RustDesk.app && sudo cp -R "$APP" /Applications/RustDesk.app && sudo chown -R root:wheel /Applications/RustDesk.app
sudo codesign --force --deep --sign - /Applications/RustDesk.app   # sudo: bundle is now root-owned; without it, nested dylibs fail to sign. Use your stable identity here if you have one.
sudo launchctl load -w /Library/LaunchDaemons/com.carriez.RustDesk_service.plist
launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.carriez.RustDesk_server.plist
```

Config (ID, password, options) persists across a redeploy; only the binary changes. **Permissions re-prompt** after an ad-hoc-signed rebuild — a stable signing identity at build time avoids it (see `build-stealth-rustdesk` → "Stable signing identity").

## Connection / stealth failures

- **Keyboard dead, mouse works** — the **daemon trap**: the controlling process is a LaunchDaemon (outside the user session), not the LaunchAgent. Confirm `RustDesk --server` runs in the GUI session (`launchctl print gui/$(id -u)/com.carriez.RustDesk_server` → running) and that the app was built by `build-stealth-rustdesk` (tray patch, **not** an `hide-tray=Y` custom-client build — that flag is what forces the daemon path).
- **CM panel still pops out** — either the `ipc.rs` hunk isn't in the running binary (it wasn't built by `build-stealth-rustdesk`, or an old build is installed — rebuild + redeploy), or the three Step 2 options aren't all set in the config the running process reads. Confirm `approve-mode` / `verification-method` / `allow-hide-cm` are present in **both** `~/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml` and the `/var/root/...` copy.
- **`Connected, waiting for image` after a rebuild/re-sign** — the new binary's ad-hoc cdhash no longer matches the `csreq` bound to the old TCC grant, so macOS silently denies screen capture even though the row still reads `auth_value=2` (ALLOWED). Checking the row is misleading; it looks granted. Fix: `sudo tccutil reset ScreenCapture com.carriez.rustdesk` (also `Accessibility`, `ListenEvent`), restart both services, re-grant. To stop this recurring on every update, build with a **stable self-signed identity** (see `build-stealth-rustdesk` → "Stable signing identity") — TCC then binds to the cert, not the cdhash. Or, if SIP is off on the target, rewrite the grant's `csreq` to an identifier-only requirement once — see **"Make ad-hoc TCC grants survive rebuilds"** below.
- **Remote access works only while a RustDesk window is open / agent won't stay up** — the stock agent `KeepAlive` restarts only on an *unsuccessful* exit (`SuccessfulExit=false`), so a clean exit (e.g. closing a GUI window ends the `--server`) leaves it down, and with no user-session agent a connection can't capture or inject. Permanent fix (Step 1): force always-restart — `sudo /usr/libexec/PlistBuddy -c "Delete :KeepAlive" -c "Add :KeepAlive bool true" /Library/LaunchAgents/com.carriez.RustDesk_server.plist` then re-bootstrap the agent. To just bring it up now: `launchctl kickstart -k gui/$(id -u)/com.carriez.RustDesk_server`. The root daemon (`service`) has plain `KeepAlive=true` already.
- **CM panel returns after the password step** — RustDesk reset `verification-method` to `use-both-passwords` because the service started "permanent-only but with no valid permanent password" (usually the `--password` step raced the IPC socket and printed `Connection refused` instead of `Done!`). `hide_cm()` then reads false. Fix: confirm the permanent password is set (retry `--password` until `Done!`), then `sed -i '' "s/^verification-method = .*/verification-method = 'use-permanent-password'/"` both `RustDesk2.toml` and restart. It sticks once a valid permanent password exists.
- **Can't connect at all after reboot** — check both launchctl labels are loaded (`state = running`); the daemon has `RunAtLoad`+`KeepAlive` and the agent loads in the `LoginWindow` session, so it should come up with nobody logged in.
- **ID or password rejected** — daemon (root) and agent (user) configs drifted (different `enc_id`/key). Re-sync (Step 2, part 3) so both `RustDesk.toml` files are identical, then restart both services.

## Make ad-hoc TCC grants survive rebuilds (SIP-off shortcut)

The two standard fixes for the `Connected, waiting for image` breakage above are `tccutil reset` + re-grant (every rebuild) or a stable self-signed identity at build time (once). A **third option**, when the target has **SIP off** and the `RustDesk.app` is **ad-hoc signed**: rewrite the stored requirement from the cdhash to `identifier "com.carriez.rustdesk"`. That checks only the bundle identifier, not the exact bytes, so your future stealth rebuilds will keep the permissions (Screen Recording / Accessibility / Input Monitoring) without a re-grant.

The trade-off is that it's a weaker check — *any* binary claiming that bundle id would match — fine on your own locked-down machine, but the reason macOS doesn't do this by default (it binds to the cdhash precisely to stop that). You're editing `TCC.db` directly, so it requires SIP off.

```bash
# Preconditions: `csrutil status` → disabled, and RustDesk.app is ad-hoc signed.
# Compile an identifier-only requirement to a blob. `csreq -r` reads a FILE, so feed
# the requirement text via process substitution (a here-string / stdin will not work):
csreq -r <(printf 'identifier "com.carriez.rustdesk"') -b /tmp/rustdesk.csreq
# GUARD: a zero-byte blob would corrupt every row it is written to — only proceed if
# csreq actually produced one. The whole rewrite is chained off `test -s` so an empty
# blob aborts before it can touch the DB:
test -s /tmp/rustdesk.csreq && HEX=$(xxd -p /tmp/rustdesk.csreq | tr -d '\n') && \
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "UPDATE access SET csreq=X'$HEX' WHERE client='com.carriez.rustdesk';" && \
  sudo launchctl kickstart -k system/com.apple.tccd   # reload TCC so the new requirement is honored
```

**Done when:** `codesign --verify -R='identifier "com.carriez.rustdesk"' /Applications/RustDesk.app` exits 0, and a fresh ad-hoc rebuild + redeploy still streams the screen (no `Connected, waiting for image`) with no new permission prompt.
