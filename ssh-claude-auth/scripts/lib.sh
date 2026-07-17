#!/bin/bash
# Shared helpers for the ssh-claude-auth skill scripts.
# The marker names below are the single source of truth for the ~/.zshrc blocks
# the setup scripts append and the teardown scripts remove. Marker text must stay
# regex-safe (letters/spaces only) and must not change, or teardown of blocks
# written by older versions breaks.

OAUTH_MARKER="claude oauth token"
KEYCHAIN_MARKER="claude keychain unlock"

marker_start() { printf '# >>> %s >>>' "$1"; }
marker_end()   { printf '# <<< %s <<<' "$1"; }

# read_secret <prompt> <varname> — read a secret from stdin with no echo into
# the named variable. Fails (nonzero) on empty input. Works on macOS bash 3.2.
read_secret() {
  local prompt="$1" __var="$2" val
  printf '%s' "$prompt"
  IFS= read -rs val
  printf '\n'
  if [ -z "$val" ]; then
    echo "Nothing entered; aborting." >&2
    return 1
  fi
  printf -v "$__var" '%s' "$val"
}

# append_marked_block <file> <marker-name> <content> — append content wrapped in
# marker comments, unless a block with that marker already exists (idempotent).
append_marked_block() {
  local file="$1" name="$2" content="$3"
  if grep -qF "$(marker_start "$name")" "$file" 2>/dev/null; then
    echo "$file already has the '$name' block; left it unchanged."
    return 0
  fi
  {
    printf '\n%s\n' "$(marker_start "$name")"
    printf '%s\n' "$content"
    printf '%s\n' "$(marker_end "$name")"
  } >> "$file"
  echo "Added the '$name' block to $file."
}

# remove_marked_block <file> <marker-name> — delete the marker-delimited block.
# No-op if the file or block is absent. /usr/bin/sed pins BSD sed in case a GNU
# sed shadows PATH (homebrew/mise).
remove_marked_block() {
  local file="$1" name="$2"
  [ -f "$file" ] || return 0
  if grep -qF "$(marker_start "$name")" "$file"; then
    /usr/bin/sed -i '' "/^$(marker_start "$name")\$/,/^$(marker_end "$name")\$/d" "$file"
    echo "Removed the '$name' block from $file."
  fi
}
