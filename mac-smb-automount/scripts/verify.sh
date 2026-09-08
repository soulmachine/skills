#!/bin/zsh
# Verify an installed agent: silent no-op passes, repair of a lost mount, recovery from an empty
# credential cache.   verify.sh [label]      (default com.user.mount-smb-shares)
emulate -L zsh
LABEL=${1:-com.user.mount-smb-shares}
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/mount-smb-shares.log"
[[ -f $PLIST ]] || { print -u2 "no agent plist at $PLIST"; exit 2; }
shares=(${(s:|:)$(plutil -extract EnvironmentVariables.SMB_SHARES raw -o - "$PLIST")})

# Run a command inside the GUI session even when this shell is an SSH session.
ingui() { if [[ $(launchctl managername 2>/dev/null) == Aqua ]]; then "$@"; else sudo -n launchctl asuser "$(id -u)" sudo -u "$(id -un)" -i "$@"; fi }
kick() { launchctl kickstart -k "gui/$(id -u)/$LABEL" }
lines() { wc -l < "$LOG" 2>/dev/null | tr -d ' ' }
mounted() { local n=0 s; for s in $shares; do /sbin/mount | grep -qF " on /Volumes/$s (smbfs" && n=$((n+1)); done; print $n }
wait_all() { for i in {1..30}; do (( $(mounted) == ${#shares} )) && return 0; sleep 2; done; return 1 }
integer fails=0
check() { if "$@"; then print "  PASS"; else print "  FAIL"; (( fails++ )); fi }

print "1. two forced runs are silent no-ops"
noop() { local b=$(lines); kick; sleep 6; local a=$(lines); (( a == b )) || { print "     run added $((a-b)) log lines"; return 1; }; return 0 }
check noop; check noop

print "2. a lost mount is repaired on the next run"
repair() { umount -f "/Volumes/${shares[1]}" 2>/dev/null; local b=$(lines); kick; wait_all || return 1; sed -n "$((b+1)),\$p" "$LOG" | sed 's/^/     /'; return 0 }
check repair

print "3. recovery from an empty credential cache with nothing mounted"
cold() {
  ingui kdestroy -A 2>/dev/null
  local s; for s in $shares; do umount -f "/Volumes/$s" 2>/dev/null; done
  local b=$(lines); kick; wait_all || return 1
  sed -n "$((b+1)),\$p" "$LOG" | sed 's/^/     /'
  ingui klist --list-all 2>/dev/null | grep -q API: || { print "     no credential cache after recovery"; return 1; }
  pgrep -x NetAuthAgent >/dev/null && { print "     an auth dialog is up"; return 1; }
  return 0
}
check cold

print "mounts: $(mounted)/${#shares}   stderr: $(wc -c < "$HOME/Library/Logs/mount-smb-shares.err.log" 2>/dev/null | tr -d ' ') bytes"
(( fails == 0 )) && print "ALL PASS" || { print "$fails FAILED"; exit 1; }
