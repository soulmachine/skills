#!/bin/bash
# Set up a Dock launcher that starts Google Chrome with CDP enabled.
# Usage: setup_chrome_cdp.sh [port]   (default 9222)
#
# Idempotent: reuses an existing profile clone, rebuilds the wrapper app,
# and leaves the Dock alone if the tile already points at the wrapper.
set -euo pipefail

PORT="${1:-9222}"
CHROME_APP="/Applications/Google Chrome.app"
CHROME_BIN="$CHROME_APP/Contents/MacOS/Google Chrome"
APP="/Applications/Google Chrome CDP.app"
SRC="$HOME/Library/Application Support/Google/Chrome"
UDD="$HOME/Library/Application Support/Google/Chrome-CDP"
DOCK_BACKUP="$HOME/Library/Preferences/com.apple.dock.backup-before-cdp.plist"

[ -x "$CHROME_BIN" ] || { echo "ERROR: Google Chrome not found at $CHROME_APP" >&2; exit 1; }
[ -d "$SRC" ] || { echo "ERROR: no Chrome profile at $SRC" >&2; exit 1; }
# /usr/bin/clang exists even without Command Line Tools (it is a shim that pops an
# install dialog), so ask xcode-select instead of `command -v`.
xcode-select -p >/dev/null 2>&1 || { echo "ERROR: Command Line Tools required to compile the launcher: xcode-select --install" >&2; exit 1; }
echo "==> $("$CHROME_BIN" --version)"

echo "==> Quitting Chrome (session restores on relaunch)"
osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1 || true
python3 - <<'PY'
import subprocess, time, sys
for _ in range(60):
    if subprocess.run(["pgrep", "-x", "Google Chrome"], capture_output=True).returncode != 0:
        sys.exit(0)
    time.sleep(0.5)
subprocess.run(["pkill", "-x", "Google Chrome"])
time.sleep(2)
PY
# Flag-mode CDP binds its port with no fallback: if anything still holds it
# (typically a flag-less Chrome in chrome://inspect approval mode that the
# quit above did not reach), the wrapper would come up without CDP at all.
HOLDER=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
if [ -n "$HOLDER" ]; then
    echo "ERROR: port $PORT is still held; quit or kill this first:" >&2
    echo "$HOLDER" >&2
    exit 1
fi

if [ -d "$UDD" ]; then
    echo "==> Profile clone already exists, reusing: $UDD"
else
    echo "==> Cloning profile (APFS copy-on-write, near-zero disk)"
    cp -Rc "$SRC" "$UDD" 2>/dev/null || { rm -rf "$UDD"; cp -R "$SRC" "$UDD"; }
    find "$UDD" -maxdepth 1 -name 'Singleton*' -delete
fi
LAST_USED=$(python3 -c "import json; print(json.load(open('$UDD/Local State')).get('profile', {}).get('last_used', 'Default'))")
[ -f "$UDD/$LAST_USED/Preferences" ] || { echo "ERROR: clone missing $LAST_USED/Preferences" >&2; exit 1; }
echo "    clone OK (active profile: $LAST_USED)"

echo "==> Building wrapper app: $APP"
# A tiny Mach-O that execs Chrome. Mach-O, because with SIP on macOS 26 refuses to
# launch a bundle whose executable is a shell script (LaunchServices -10669). exec,
# because it keeps the process LaunchServices started from this bundle, so the Dock
# shows one tile named Google Chrome CDP for the running browser. See REFERENCE.md
# "Wrapper app anatomy".
TMPD=$(mktemp -d)
BUILD="$TMPD/$(basename "$APP")"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
# CFBundleURLTypes / CFBundleDocumentTypes claim what a browser claims, so the bundle
# can be picked as the default handler for links and .html files. Declaring them does
# not take the default away from Chrome — scripts/set_default_browser.sh does that.
cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>launcher</string>
	<key>CFBundleIconFile</key>
	<string>app.icns</string>
	<key>CFBundleIdentifier</key>
	<string>com.archauto.chrome-cdp</string>
	<key>CFBundleName</key>
	<string>Google Chrome CDP</string>
	<key>CFBundleDisplayName</key>
	<string>Google Chrome CDP</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>Web site URL</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>http</string>
				<string>https</string>
			</array>
		</dict>
	</array>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>HTML document</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.html</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST
# --user-data-dir: Chrome 136+ ignores --remote-debugging-port on the default dir.
# --profile-directory: with several profiles in the clone Chrome would open the
#   profile picker, and until one is picked there is no default browser context —
#   Playwright's connect_over_cdp dies at attach.
# A URL or file handed to this bundle arrives as a GURL/odoc Apple Event, not argv;
# the event survives the exec and Chrome opens it, which is what lets the wrapper
# stand in as the default browser.
cat > "$TMPD/launcher.c" <<C
#include <unistd.h>
int main(void) {
    char *argv[] = {"$CHROME_BIN",
                    "--remote-debugging-port=$PORT",
                    "--user-data-dir=$UDD",
                    "--profile-directory=$LAST_USED",
                    0};
    execv(argv[0], argv);
    return 1;
}
C
# Native slice only: with no x86_64 slice the stub cannot run under Rosetta, which
# retires the Rosetta trap (REFERENCE.md) for this launcher.
clang -arch "$(uname -m)" -o "$BUILD/Contents/MacOS/launcher" "$TMPD/launcher.c"
cp "$CHROME_APP/Contents/Resources/app.icns" "$BUILD/Contents/Resources/app.icns"
codesign --force -s - "$BUILD"
# Swap in only once built and signed, so a failed build leaves the old wrapper working.
rm -rf "$APP"
mv "$BUILD" "$APP"
rm -rf "$TMPD"
# Unregister then register: LaunchServices snapshots the Info.plist at first
# registration and keys freshness on mtime. Rebuilding the bundle within the
# same second leaves the mtime unchanged, and `lsregister -f` alone does NOT
# replace the stale snapshot (a snapshot with LSArchitecturePriority x86_64-
# first silently forces Rosetta). Only -u + re-register reliably purges it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" "$APP"

echo "==> Swapping Dock tile (backup: $DOCK_BACKUP)"
[ -f "$DOCK_BACKUP" ] || defaults export com.apple.dock "$DOCK_BACKUP"
WORK=$(mktemp /tmp/dock-edit.XXXXXX)
defaults export com.apple.dock "$WORK"
python3 - "$WORK" <<'PY'
import plistlib, subprocess, sys, time

path = sys.argv[1]
with open(path, "rb") as f:
    d = plistlib.load(f)
apps = d.get("persistent-apps", [])

new_tile = {
    "tile-type": "file-tile",
    "tile-data": {
        "file-data": {
            "_CFURLString": "file:///Applications/Google%20Chrome%20CDP.app/",
            "_CFURLStringType": 15,
        },
        "file-label": "Google Chrome CDP",
        "file-type": 41,
    },
}

def url_of(tile):
    try:
        return tile["tile-data"]["file-data"]["_CFURLString"]
    except (KeyError, TypeError):
        return ""

if any("Google%20Chrome%20CDP.app" in url_of(t) for t in apps):
    print("    Dock tile already points at wrapper; no change")
    sys.exit(0)

idx = next((i for i, t in enumerate(apps) if "Google%20Chrome.app" in url_of(t)), None)
if idx is None:
    apps.append(new_tile)
    print("    no Chrome tile found; appended wrapper tile")
else:
    apps[idx] = new_tile
    print(f"    replaced Chrome tile at position {idx}")
d["persistent-apps"] = apps
with open(path, "wb") as f:
    plistlib.dump(d, f)
subprocess.run(["defaults", "import", "com.apple.dock", path], check=True)
# A Dock still starting up when Chrome launches infers the app from the process
# (Google Chrome.app) and shows a second tile for that session, so wait for the new
# Dock to register with LaunchServices before anything launches.
old = subprocess.run(["pgrep", "-x", "Dock"], capture_output=True, text=True).stdout.strip()
subprocess.run(["killall", "Dock"])
for _ in range(50):
    new = subprocess.run(["pgrep", "-x", "Dock"], capture_output=True, text=True).stdout.strip()
    if new and new != old and b"pid" in subprocess.run(["lsappinfo", "info", "-app", "com.apple.dock"], capture_output=True).stdout:
        break
    time.sleep(0.2)
PY
rm -f "$WORK"

echo "==> Launching CDP Chrome"
open -a "$APP"
echo "==> Waiting for CDP endpoint on port $PORT"
curl -s --retry 30 --retry-delay 1 --retry-all-errors "http://127.0.0.1:$PORT/json/version" \
    || { echo "ERROR: CDP endpoint never came up on port $PORT" >&2; exit 1; }
echo
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN

if [ "$(uname -m)" = "arm64" ]; then
    echo "==> Verifying Chrome runs native (not under Rosetta)"
    sleep 2
    # lsappinfo printed Arch=arm64 on older macOS and Arch=ARM64 on macOS 26.
    if lsappinfo info -app com.google.Chrome | grep -qi "Arch=arm64"; then
        echo "    native arm64 OK"
    else
        echo "ERROR: Chrome is running x86_64 under Rosetta — expect multiplied CPU usage." >&2
        echo "       See REFERENCE.md 'Rosetta trap'." >&2
        exit 1
    fi
fi
echo "==> Done. Agents connect via http://127.0.0.1:$PORT"
