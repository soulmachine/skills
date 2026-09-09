#!/bin/zsh
# Install mount-smb-shares.sh as a LaunchAgent for the current login user.
#   install.sh --host <fqdn> --share <name> [--share <name> …] [--user <server-account>]
#              [--label <reverse.dns>] [--tailscale <path>]
emulate -L zsh
set -e
HOST= USER_= LABEL=com.user.mount-smb-shares TS=/usr/local/bin/tailscale
typeset -a SHARES
while (( $# )); do
  case $1 in
    --host) HOST=$2; shift 2 ;;      --user) USER_=$2; shift 2 ;;
    --share) SHARES+=("$2"); shift 2 ;; --label) LABEL=$2; shift 2 ;;
    --tailscale) TS=$2; shift 2 ;;
    *) print -u2 "unknown argument: $1"; exit 2 ;;
  esac
done
[[ -n $HOST && ${#SHARES} -gt 0 ]] || { print -u2 "usage: $0 --host <fqdn> --share <name> [--share …] [--user <account>]"; exit 2; }
(( $(id -u) )) || { print -u2 "run as the login user, not root"; exit 2; }

DIR=${0:A:h}
install -d "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 "$DIR/mount-smb-shares.sh" "$HOME/.local/bin/mount-smb-shares.sh"

xml() { local v=$1; v=${v//&/&amp;}; v=${v//</&lt;}; print -r -- "$v" }
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$(xml "$LABEL")</string>
	<key>ProgramArguments</key>
	<array><string>$HOME/.local/bin/mount-smb-shares.sh</string></array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>SMB_HOST</key><string>$(xml "$HOST")</string>
		<key>SMB_USER</key><string>$(xml "$USER_")</string>
		<key>SMB_SHARES</key><string>$(xml "${(j:|:)SHARES}")</string>
		<key>TAILSCALE</key><string>$(xml "$TS")</string>
	</dict>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>300</integer>
	<key>WatchPaths</key><array><string>/var/run/resolv.conf</string></array>
	<key>LaunchEvents</key>
	<dict>
		<key>com.apple.notifyd.matching</key>
		<dict>
			<key>com.apple.powermanagement.systempowerstate</key>
			<dict><key>Notification</key><string>com.apple.powermanagement.systempowerstate</string></dict>
		</dict>
	</dict>
	<key>ProcessType</key><string>Background</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/mount-smb-shares.err.log</string>
</dict>
</plist>
PL
plutil -lint "$PLIST" >/dev/null

LOG="$HOME/Library/Logs/mount-smb-shares.log"; : > "$LOG"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

mounted() { local n=0 s; for s in $SHARES; do /sbin/mount | grep -qF " on /Volumes/$s (smbfs" && n=$((n+1)); done; print $n }
for i in {1..45}; do (( $(mounted) == ${#SHARES} )) && break; sleep 2; done

print "log:"; sed 's/^/  /' "$LOG"
print "mounts: $(mounted)/${#SHARES}"; /sbin/mount | grep smbfs | sed 's/ (smbfs.*//; s/^/  /'
launchctl print "gui/$(id -u)/$LABEL" | grep -E '^\s*(runs|last exit code) ' | sed 's/^\s*/  /'
(( $(mounted) == ${#SHARES} ))
