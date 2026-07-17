#!/bin/bash
# Approach A: wire a long-lived Claude Code OAuth token (from `claude setup-token`)
# into the SSH environment via CLAUDE_CODE_OAUTH_TOKEN, bypassing the macOS
# keychain entirely. Interactive by design — the token is typed by a human with
# no echo, never passed as an argument.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

TOKEN_FILE="$HOME/.claude/.oauth-token.zsh"
mkdir -p "$HOME/.claude"

read_secret 'Paste the token from `claude setup-token` (input hidden): ' TOKEN
printf "export CLAUDE_CODE_OAUTH_TOKEN='%s'\n" "$TOKEN" > "$TOKEN_FILE"
unset TOKEN
chmod 600 "$TOKEN_FILE"

append_marked_block "$HOME/.zshrc" "$OAUTH_MARKER" \
'# Load the Claude Code long-lived OAuth token (keychain-free auth over SSH).
[ -f "$HOME/.claude/.oauth-token.zsh" ] && source "$HOME/.claude/.oauth-token.zsh"'

echo 'Done. Open a fresh SSH session and verify with:'
echo '  [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo "token set" && claude'
