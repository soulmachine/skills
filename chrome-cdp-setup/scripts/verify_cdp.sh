#!/bin/bash
# Health check for the Chrome CDP endpoint. Usage: verify_cdp.sh [port]
set -uo pipefail
PORT="${1:-9222}"

echo "--- /json/version ---"
curl -s --max-time 5 "http://127.0.0.1:$PORT/json/version" || echo "(no response)"
echo
echo "--- listener (expect 127.0.0.1:$PORT only) ---"
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN || echo "(nothing listening)"
echo "--- chrome main process flags ---"
ps -axo command | grep -- "--remote-debugging-port" | grep "Contents/MacOS/Google Chrome --" | grep -v grep || echo "(no flagged Chrome process)"
echo "--- DevToolsActivePort file ---"
cat "$HOME/Library/Application Support/Google/Chrome-CDP/DevToolsActivePort" 2>/dev/null || echo "(missing)"
