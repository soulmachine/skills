#!/bin/zsh
# Mount a Mac's SMB shares at /Volumes/<share> via NetFS and keep them healthy.
# Idempotent and silent when everything is mounted: safe to run every few minutes.
# Configured through the environment (the LaunchAgent sets these):
#   SMB_HOST    server hostname (Tailscale MagicDNS name)            required
#   SMB_SHARES  share names separated by |                           required
#   SMB_USER    account on the server; empty = let NetAuth choose    optional
#   TAILSCALE   tailscale CLI path; skipped if absent                 default /usr/local/bin/tailscale
#   LOG         log file                                              default ~/Library/Logs/mount-smb-shares.log
emulate -L zsh
setopt no_unset

: ${SMB_HOST:?set SMB_HOST}
: ${SMB_SHARES:?set SMB_SHARES (share names separated by |)}
SMB_USER=${SMB_USER:-}
TAILSCALE=${TAILSCALE:-/usr/local/bin/tailscale}
LOG=${LOG:-$HOME/Library/Logs/mount-smb-shares.log}
shares=(${(s:|:)SMB_SHARES})

log() { print -r -- "$(date '+%F %T') $*" >> "$LOG" }
[[ -f $LOG && $(/usr/bin/stat -f%z "$LOG") -gt 1048576 ]] && : > "$LOG"

# Hard wall-clock cap; macOS has no timeout(1). exit 127 keeps a failed exec from reading as success.
watchdog() { /usr/bin/perl -e 'alarm shift; exec @ARGV; exit 127' "$@" }

is_mounted() { /sbin/mount | /usr/bin/grep -qF " on $1 (smbfs" }

# Liveness from smbfs kernel state (rc 0 live, 64 gone). Reading the directory instead is
# blocked by TCC under launchd ("Operation not permitted") and reads as a dead mount.
probe_ok() { /usr/bin/smbutil statshares -m "$1" >/dev/null 2>&1 }

# Percent-encode a share name for the URL (byte-wise, so non-ASCII names survive).
urlenc() {
  local s=$1 out= c; local LC_ALL=C
  for (( i = 1; i <= ${#s}; i++ )); do
    c=${s[i]}
    case $c in [A-Za-z0-9._~-]) out+=$c ;; *) out+=$(printf '%%%02X' "'$c") ;; esac
  done
  print -r -- "$out"
}

# --- 0. Dark wake (lid closed / maintenance wake): nothing to do, and no user to serve.
#        The wake trigger fires on every power-state change; only a full wake with the display
#        on is worth the ~60 s connect attempt, which would otherwise burn battery every hour.
if /usr/sbin/ioreg -r -k AppleClamshellState -d 4 2>/dev/null | /usr/bin/grep -q '"AppleClamshellState" = Yes'; then
  exit 0
fi

# --- 1. Wait for the network and the server, up to ~60 s (covers the login-time race) --------
integer ok=0
for i in {1..20}; do
  if { [[ ! -x $TAILSCALE ]] || watchdog 8 "$TAILSCALE" status --peers=false >/dev/null 2>&1; } \
     && /usr/bin/nc -z -G 3 "$SMB_HOST" 445 >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 3
done
if (( ! ok )); then
  log "host $SMB_HOST unreachable; skipping this pass"
  exit 0
fi

# --- 2. Mount or repair each share ------------------------------------------------------------
integer failures=0
for share in $shares; do
  mp="/Volumes/$share"

  if is_mounted "$mp"; then
    probe_ok "$mp" && continue
    log "stale mount at $mp; forcing unmount"
    watchdog 15 /sbin/umount -f "$mp" >/dev/null 2>&1 \
      || watchdog 20 /usr/sbin/diskutil unmount force "$mp" >/dev/null 2>&1
  fi

  # NetFS mount. `try` suppresses the modal error dialog; the watchdog bounds the call itself,
  # which blocks forever when the server cannot authenticate the client.
  url="smb://${SMB_USER:+${SMB_USER}@}${SMB_HOST}/$(urlenc "$share")"
  watchdog 60 /usr/bin/osascript \
    -e 'with timeout of 45 seconds' \
    -e 'try' \
    -e "mount volume \"${url}\"" \
    -e 'end try' \
    -e 'end timeout' >/dev/null 2>&1

  if is_mounted "$mp"; then
    log "mounted $share"
  else
    log "FAILED to mount $share ($url)"
    (( failures++ ))
  fi
done

(( failures )) && exit 1
exit 0
