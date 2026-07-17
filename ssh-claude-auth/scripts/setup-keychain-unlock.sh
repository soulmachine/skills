#!/bin/bash
# Approach B: auto-unlock the macOS login keychain for headless/SSH Claude Code.
# Installs a password file (600), an unlock script (700), a login LaunchAgent,
# and a ~/.zshrc SSH hook. Interactive by design — the macOS password is read
# with no echo, never passed as an argument.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PW_FILE="$HOME/.claude/.keychain-password"
UNLOCK="$HOME/.claude/unlock-keychain.sh"
LABEL="com.claude.unlock-keychain"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/.claude" "$HOME/Library/LaunchAgents"

# 1. Password file (kept if present so a re-run never clobbers it).
if [ -f "$PW_FILE" ]; then
  echo "$PW_FILE already exists; keeping it. (Delete it first to re-enter.)"
else
  read_secret 'macOS login password (input hidden): ' PW
  printf '%s' "$PW" > "$PW_FILE"
  unset PW
fi
chmod 600 "$PW_FILE"

# 2. Unlock script.
cat > "$UNLOCK" <<'SCRIPT'
#!/bin/bash
# Unlock the login keychain from the stored password so Claude Code can read its creds.
PW_FILE="$HOME/.claude/.keychain-password"
[ -f "$PW_FILE" ] || exit 1
exec security unlock-keychain -p "$(cat "$PW_FILE")" "$HOME/Library/Keychains/login.keychain-db"
SCRIPT
chmod 700 "$UNLOCK"

# 3. LaunchAgent: runs the unlock at login so non-interactive contexts (cron,
# launchd jobs) also see an unlocked keychain.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$UNLOCK</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

# 4. (Re)load it. bootstrap/bootout are modern launchctl; fall back to load.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null ||
  echo "warning: could not load the LaunchAgent (no GUI session?); the .zshrc hook still covers SSH logins."

# 5. ~/.zshrc hook so every SSH login unlocks too.
append_marked_block "$HOME/.zshrc" "$KEYCHAIN_MARKER" \
'# Unlock the login keychain on SSH login so Claude Code can read its credentials.
if [[ -n "$SSH_CONNECTION" && -x "$HOME/.claude/unlock-keychain.sh" ]]; then
  "$HOME/.claude/unlock-keychain.sh" 2>/dev/null
fi'

echo "Done. Test now with:  bash \"$UNLOCK\" && echo ok"
echo "Then open a fresh SSH session and run: claude"
