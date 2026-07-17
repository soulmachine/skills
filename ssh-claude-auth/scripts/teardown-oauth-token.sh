#!/bin/bash
# Undo Approach A: delete the stored OAuth token file and its ~/.zshrc block.
# Claude Code then falls back to keychain-based credentials (which must be
# unlocked — see Approach B or unlock manually).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

rm -f "$HOME/.claude/.oauth-token.zsh"
remove_marked_block "$HOME/.zshrc" "$OAUTH_MARKER"

echo "Removed the OAuth token file and its ~/.zshrc block."
echo "Fresh sessions will use the keychain again — it must be unlocked to work over SSH."
