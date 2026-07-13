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
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/launcher" <<SH
#!/bin/bash
# Chrome 136+ ignores --remote-debugging-port on the default user-data-dir,
# so this launches against the cloned profile dir instead.
exec "$CHROME_BIN" --remote-debugging-port=$PORT --user-data-dir="\$HOME/Library/Application Support/Google/Chrome-CDP"
SH
chmod +x "$APP/Contents/MacOS/launcher"

cp "$CHROME_APP/Contents/Resources/app.icns" "$APP/Contents/Resources/app.icns"
codesign --force -s - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "==> Swapping Dock tile (backup: $DOCK_BACKUP)"
[ -f "$DOCK_BACKUP" ] || defaults export com.apple.dock "$DOCK_BACKUP"
WORK=$(mktemp /tmp/dock-edit.XXXXXX)
defaults export com.apple.dock "$WORK"
python3 - "$WORK" <<'PY'
import plistlib, sys

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
PY
defaults import com.apple.dock "$WORK"
rm -f "$WORK"
killall Dock || true

echo "==> Launching CDP Chrome"
open -a "$APP"
echo "==> Waiting for CDP endpoint on port $PORT"
curl -s --retry 30 --retry-delay 1 --retry-all-errors "http://127.0.0.1:$PORT/json/version" \
    || { echo "ERROR: CDP endpoint never came up on port $PORT" >&2; exit 1; }
echo
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN
echo "==> Done. Agents connect via http://127.0.0.1:$PORT"
