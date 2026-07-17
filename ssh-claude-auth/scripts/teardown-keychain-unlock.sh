#!/bin/bash
# Undo Approach B: unload the LaunchAgent, delete the unlock script, plist, and
# the plaintext password file, and remove the marked ~/.zshrc hook. Run this when
# switching to Approach A so the macOS password stops living on disk.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

LABEL="com.claude.unlock-keychain"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST" "$HOME/.claude/unlock-keychain.sh" "$HOME/.claude/.keychain-password"
remove_marked_block "$HOME/.zshrc" "$KEYCHAIN_MARKER"

echo "Removed the LaunchAgent, unlock script, plist, and plaintext password file."
echo "Any keychain-unlock lines added to ~/.zshrc by hand (without the >>> markers) must be removed manually."
