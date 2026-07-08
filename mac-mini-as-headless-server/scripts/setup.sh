#!/usr/bin/env bash
# Configure macOS (15+) for unattended 24/7 headless server operation.
# Documentation: ../SKILL.md
set -euo pipefail

# Require root
if [[ $EUID -ne 0 ]]; then
  echo "Error: run with sudo."
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
if [[ "$REAL_USER" == "root" ]]; then
  echo "Error: run via sudo from the target user's account, not from a root shell —"
  echo "per-user defaults (screen saver, App Nap) must land in that user's domain."
  exit 1
fi

# 1. Disable screen saver
sudo -u "$REAL_USER" defaults -currentHost write com.apple.screensaver idleTime -int 0

# 2. Prevent all sleep (charger profile — the only profile on a desktop Mac)
pmset -c sleep 0
pmset -c displaysleep 0
pmset -c disksleep 0
pmset -c halfdim 0

# 3. Wake-on-LAN
pmset -c womp 1

# 4. Auto-restart after power failure
pmset -c autorestart 1

# 5. Disable App Nap globally
sudo -u "$REAL_USER" defaults write NSGlobalDomain NSAppSleepDisabled -bool YES

# 6. Enable SSH. systemsetup needs Full Disk Access (per its man page) and
#    historically exits 0 even when it fails, so this line is not trusted —
#    the verify block below prints -getremotelogin; if it says Off, grant the
#    terminal Full Disk Access and re-run.
systemsetup -setremotelogin on 2>/dev/null || {
  launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
}

# 7. Apple Silicon: keep the physical display awake.
#    pmset displaysleep 0 does NOT stop the headless "display park" — with no
#    local keyboard/mouse the panel DPMS-off's ~30s after each wake, which also
#    makes RealVNC / screen-capture go black (they capture the physical panel).
#    A persistent `caffeinate -d` assertion (PreventUserIdleDisplaySleep) fixes
#    it — verified on a headless Mac Studio M3: the assertion holds the panel
#    indefinitely, and it re-parks ~1s after the assertion drops. Installed as
#    a LaunchDaemon so it runs at boot and survives reboots. Harmless on Intel.
KEEPAWAKE_LABEL="com.local.keepdisplayawake"
KEEPAWAKE_PLIST="/Library/LaunchDaemons/${KEEPAWAKE_LABEL}.plist"
cat > "$KEEPAWAKE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${KEEPAWAKE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-d</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST
chown root:wheel "$KEEPAWAKE_PLIST"
chmod 644 "$KEEPAWAKE_PLIST"
launchctl bootout   system "$KEEPAWAKE_PLIST" 2>/dev/null || true  # unload if already present
launchctl enable    system/"$KEEPAWAKE_LABEL"                      # clear a disabled flag BEFORE bootstrap, or bootstrap fails
launchctl bootstrap system "$KEEPAWAKE_PLIST"                      # load + start (RunAtLoad)
caffeinate -u -t 2 || true   # wake the panel once now (-d prevents sleep but won't wake an already-parked display)

# Verify
pmset -g
echo "--- keep-awake daemon (should show PID, not '-') ---"
launchctl print "system/${KEEPAWAKE_LABEL}" 2>/dev/null | grep -iE "state|pid =" | head || true
echo "--- display assertion (should list caffeinate) ---"
pmset -g assertions | grep -i "PreventUserIdleDisplaySleep " || true
echo "--- remote login (should be On) ---"
systemsetup -getremotelogin 2>/dev/null || true

# 8. Verify the screen lock (password after screensaver / display-off) and, on
#    an interactive run, turn it off in place. The setting lives in the user
#    keybag (MobileKeyBag): changing it requires the USER'S account password —
#    root/sudo alone can't flip it. (Don't bother with the com.apple.screensaver
#    askForPassword defaults keys old blog posts recommend; they've been ignored
#    since macOS 10.13.) Reading the status needs no sudo. "screenLock is off"
#    is the CLI equivalent of the GUI's "Never".
SCREENLOCK_STATUS="$(sysadminctl -screenLock status 2>&1)"
echo "--- screen lock status: $SCREENLOCK_STATUS"
if ! printf '%s' "$SCREENLOCK_STATUS" | grep -qi "is off"; then
  if [[ -t 0 ]]; then
    # Interactive: sysadminctl prompts for the password itself ('-password -').
    # Wrong password or Ctrl-D (skip) falls through to the instructions below.
    # Its exit code is not trusted (sysadminctl can exit 0 on failure) — the
    # re-checked status decides whether the manual instructions still print.
    echo ""
    echo ">>> Screen lock is ON. Turning it off now — enter ${REAL_USER}'s account"
    echo ">>> password at the prompt (Ctrl-D to skip)."
    sudo -u "$REAL_USER" sysadminctl -screenLock off -password - || true
    SCREENLOCK_STATUS="$(sysadminctl -screenLock status 2>&1)"
    echo "--- screen lock status now: $SCREENLOCK_STATUS"
  fi
fi
if ! printf '%s' "$SCREENLOCK_STATUS" | grep -qi "is off"; then
  cat <<'MSG'

  ⚠️  SCREEN LOCK IS STILL ON — the Mac will demand a password after the display
      turns off. Turning it off needs the user's account password (root/sudo
      alone can't). Pick one:

      GUI:  System Settings → Lock Screen →
            "Require password after screen saver begins or display is turned off"
            → Never

      CLI, interactive (run as the user, no sudo; prompts for the password):
            sysadminctl -screenLock off -password -

      CLI, scriptable (e.g. over SSH; the password is exposed to ps and shell
      history — prefer the interactive form when a human is at the keyboard):
            sysadminctl -screenLock off -password 'account-password'

      Re-check:  sysadminctl -screenLock status   → want "screenLock is off"

MSG
fi
