# Build reference — pins, fork bumps, build failures, signing

Companion to [SKILL.md](SKILL.md) for `build-stealth-rustdesk`: re-deriving the toolchain pins for a new RustDesk tag, bumping the fork, build-failure fixes, and the stable signing identity. For install / connection / stealth-at-runtime issues, see the **`deploy-stealth-rustdesk`** skill and its `REFERENCE.md`.

## Re-deriving pins for a new RustDesk tag

The pins drift release to release; for any tag other than 1.4.8, read them from *that tag's* own files before building:

- Rust (macOS), Flutter, vcpkg commit, `FLUTTER_RUST_BRIDGE_VERSION`, `CARGO_EXPAND_VERSION`, vcpkg triplet → `.github/workflows/flutter-build.yml` and `bridge.yml` (env block).
- `flutter_rust_bridge` version → `Cargo.toml` (must match the codegen version).
- Build feature flags → the macOS `build.py` line in `flutter-build.yml` (was `--flutter --hwcodec --unix-file-copy-paste`).

## Bumping the fork to a new tag

Normal path is the `git rebase --onto`/cherry-pick in SKILL.md Step 1. If the patch **conflicts**, upstream moved the code — re-locate the two sites by hand:

- tray: `src/tray.rs`, the `Event::NewEvents(StartCause::Init)` handler in `make_tray()`, the `OPTION_HIDE_TRAY == "Y"` early-return — add `cfg!(target_os = "macos") ||` in front of it.
- CM gate: `src/ipc.rs`, the `get_config` handler's `name == "hide_cm"` arm — drop the `is_pro() || is_custom_client()` condition so `value = Some(hide_cm().to_string())` unconditionally.

If the hunks changed, re-export the canonical patch so it keeps matching the fork:

```bash
git diff <new-tag>..stealth-<new-tag> -- src/ipc.rs src/tray.rs > "$SKILL_DIR/assets/stealth.patch"
```

After building the new tag, redeploy with `deploy-stealth-rustdesk` (its "Redeploying a rebuilt app" section). Permissions re-prompt on every rebuild **unless** you use a stable signing identity (below).

## Build failures

- **`file not found for module bridge_generated` / `EventToUI: IntoIntoDart`** — Step 4 (FRB codegen) was skipped or failed. Confirm `src/bridge_generated.rs` exists; if not, re-run codegen. `build.py` never runs it for you.
- **vcpkg link errors / missing codec** — wrong triplet or the manifest install didn't finish. Confirm `$VCPKG_ROOT/installed/arm64-osx/lib` has `libvpx.a libyuv.a libaom.a libopus.a` (and `libavcodec.a` for `--hwcodec`). Re-run `vcpkg install --triplet arm64-osx --x-install-root="$VCPKG_ROOT/installed"` from the repo.
- **`xcodebuild requires Xcode`** — CLT is active, not full Xcode. `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- **Flutter/pod errors** — wrong Flutter version. Must be the pinned one (3.24.5 for 1.4.8), not `brew`'s latest. `flutter --version` to check.

## Stable signing identity (stop re-granting on every update)

Ad-hoc (`-s -`) binds `deploy-stealth-rustdesk`'s TCC grants to the exact binary, so each rebuild breaks them (symptom on the deploy side: `Connected, waiting for image` even though the TCC row still reads `auth_value=2`). A self-signed code-signing cert binds grants to the **cert** instead, so rebuilds keep their permissions. One-time setup (Keychain Access is the reliable route — creating a codesigning cert non-interactively is fiddly):

1. Keychain Access ▸ **Certificate Assistant ▸ Create a Certificate…** → Name e.g. `RustDeskStealth`, Identity Type **Self-Signed Root**, Certificate Type **Code Signing** → Create.
2. Confirm it is usable: `security find-identity -v -p codesigning` lists `RustDeskStealth`.
3. Sign with it wherever ad-hoc was used (Step 6, and deploy's rebuild-redeploy): `codesign --force --deep --sign "RustDeskStealth" "$APP"` (`sudo` for an already-installed root-owned copy).
4. On the deploy side, grant the three permissions once against this identity. Every later rebuild signed with the same cert keeps them — no reset, no re-grant.

The cert need not be trusted for Gatekeeper; codesign only needs the identity present in the keychain, and TCC keys on the cert in the app's designated requirement.
