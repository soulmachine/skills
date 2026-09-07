#!/bin/bash
# Health check for the Chrome CDP endpoint. Usage: verify_cdp.sh [port]
# Prints the raw signals, then a one-line verdict naming the state and the fix.
# Exit status is 0 only when flag-mode CDP is healthy.
set -uo pipefail
PORT="${1:-9222}"
DEFAULT_PROFILE="$HOME/Library/Application Support/Google/Chrome"
CDP_PROFILE="$HOME/Library/Application Support/Google/Chrome-CDP"

echo "--- /json/version ---"
BODY=$(mktemp)
HTTP=$(curl -s -o "$BODY" -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/json/version")
if [ "$HTTP" = "200" ]; then cat "$BODY"; echo; else echo "(HTTP $HTTP)"; fi
rm -f "$BODY"

echo "--- listener (expect 127.0.0.1:$PORT only) ---"
LISTEN=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
[ -n "$LISTEN" ] && echo "$LISTEN" || echo "(nothing listening)"
LISTEN_PID=$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)

echo "--- chrome main process launched with --remote-debugging-port=$PORT ---"
# Helpers repeat the flag; only the main process's command starts with the Chrome binary.
# Match the exact port, or a wrapper on 9222 would count as "flagged" for any port checked.
FLAGGED=$(ps -axo pid=,command= | grep -E -- "MacOS/Google Chrome --remote-debugging-port=$PORT( |\$)" | grep -v grep || true)
[ -n "$FLAGGED" ] && echo "$FLAGGED" || echo "(no flagged Chrome process)"
FLAGGED_PID=$(echo "$FLAGGED" | awk 'NR==1{print $1}')

echo "--- DevToolsActivePort (approval mode writes the default profile's; flag mode with an explicit port writes none) ---"
for dir in "$DEFAULT_PROFILE" "$CDP_PROFILE"; do
    if [ -f "$dir/DevToolsActivePort" ]; then
        echo "$(basename "$dir"): port $(head -1 "$dir/DevToolsActivePort"), written $(stat -f '%Sm' "$dir/DevToolsActivePort")"
    else
        echo "$(basename "$dir"): (missing)"
    fi
done

if [ "$(uname -m)" = "arm64" ]; then
    echo "--- architecture (expect ARM64; X86_64 = Rosetta, see REFERENCE.md 'Rosetta trap') ---"
    # lsappinfo printed Arch=arm64 on older macOS and Arch=ARM64 on macOS 26.
    ARCH=$(lsappinfo info -app com.google.Chrome 2>/dev/null | grep -io "Arch=[a-z0-9_]*" || true)
    echo "${ARCH:-(Chrome not running)}"
fi

echo "--- verdict ---"
if [ "$HTTP" = "200" ] && [ -n "$FLAGGED" ]; then
    echo "OK: flag-mode CDP on 127.0.0.1:$PORT, no approval prompts."
    exit 0
fi
if [ -z "$LISTEN" ]; then
    if [ -n "$FLAGGED" ]; then
        echo "NOT LISTENING: the flagged Chrome is running but nothing listens on $PORT."
        echo "  Right after launch, wait a few seconds and re-run. Otherwise the port was busy at launch and"
        echo "  flag mode binds with no fallback: quit Chrome, free the port, relaunch from the Dock."
    else
        echo "DOWN: no Chrome listens on $PORT. Launch from the Dock tile (Google Chrome CDP), then re-run."
    fi
    exit 1
fi
if [ -z "$FLAGGED" ]; then
    if echo "$LISTEN" | grep -q "^Google"; then
        echo "APPROVAL MODE: a flag-less Chrome (chrome://inspect toggle) holds port $PORT on the default profile."
        echo "  /json/* answers 404 and every WebSocket connection needs a human to click 'Allow remote debugging?'."
        echo "  Fix: quit that Chrome, then relaunch from the Dock tile (Google Chrome CDP). See REFERENCE.md 'Approval mode'."
    else
        echo "PORT TAKEN: something other than Chrome listens on $PORT (see listener above). Free it, then relaunch from the Dock."
    fi
    exit 1
fi
if [ -n "$LISTEN_PID" ] && [ -n "$FLAGGED_PID" ] && [ "$LISTEN_PID" != "$FLAGGED_PID" ]; then
    echo "PORT STOLEN: the flagged Chrome (pid $FLAGGED_PID) has no CDP; pid $LISTEN_PID holds $PORT instead."
    echo "  Flag mode binds with no fallback, so the wrapper started while another Chrome still held the port."
    echo "  Fix: quit both Chromes, then relaunch from the Dock tile only."
    exit 1
fi
echo "UNHEALTHY: flagged Chrome listens on $PORT but /json/version returned HTTP $HTTP."
echo "  Right after launch this is normal for a few seconds: retry with curl --retry 30 --retry-delay 1 --retry-all-errors."
exit 1
