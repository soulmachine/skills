#!/usr/bin/env bash
#
# provision.sh — turn a lume-managed macOS guest into a working cua sandbox.
#
# Acquire (pull or APFS-clone) -> size -> ensure autologin -> install cua-driver
# + LaunchAgent -> grant TCC -> set guest resolution -> verify with a real screen
# capture. Idempotent: re-running is also the health check.
#
# Usage:
#   VM=my-sandbox bash provision.sh
#   VM=my-sandbox SHARED_DIR=~/work/sandbox bash provision.sh
#   VM=my-sandbox GOLDEN=my-sandbox-golden bash provision.sh --recreate
#   VM=my-sandbox IMAGE=macos-tahoe-vanilla:latest bash provision.sh   # expects a manual TCC sitting
#
#   VM                       required — the lume VM name
#   IMAGE                    default macos-tahoe-cua:latest (ignored when GOLDEN is set)
#   GOLDEN                   clone this VM instead of pulling (APFS CoW, ~2s)
#   SHARED_DIR               host dir to share :rw; the flag is omitted when unset
#   CPU / MEMORY             default 8 / 16GB
#   DISK_SIZE                unset = do not resize; increase-only when set
#   DISPLAY_RES              default 1920x1080; applied INSIDE the guest
#   INSTALL_COMPUTER_SERVER  1 also installs the Path B HTTP API
#   INSTALL_TERMINFO         1 (default) export host terminfo into the guest's ~/.terminfo
#   TERMINFO_TERMS           terminfo names to export; default "$TERM"
#
#   --recreate               destroy an existing VM of that name first
#
# Requires: lume 0.5.3+, jq. Apple Silicon only. See REFERENCE.md for every trap
# this script works around.
#
set -Eeuo pipefail

VM="${VM:?set VM=<name> — the lume VM to provision}"
IMAGE="${IMAGE:-macos-tahoe-cua:latest}"
CPU="${CPU:-8}"
MEMORY="${MEMORY:-16GB}"
DISK_SIZE="${DISK_SIZE:-}"
DISPLAY_RES="${DISPLAY_RES:-1920x1080}"
SHARED_DIR="${SHARED_DIR:-}"
GOLDEN="${GOLDEN:-}"
VM_USER="${VM_USER:-lume}"   # do NOT rename; cua hardcodes /Users/lume
VM_PASS="${VM_PASS:-lume}"
INSTALL_COMPUTER_SERVER="${INSTALL_COMPUTER_SERVER:-0}"
INSTALL_TERMINFO="${INSTALL_TERMINFO:-1}"
TERMINFO_TERMS="${TERMINFO_TERMS:-${TERM:-}}"
DRIVER_BIN="/Applications/CuaDriver.app/Contents/MacOS/cua-driver"

RECREATE=0
[ "${1:-}" = "--recreate" ] && RECREATE=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

command -v lume >/dev/null || die "lume not on PATH"
command -v jq   >/dev/null || die "jq not on PATH"
[ -z "$SHARED_DIR" ] || [ -d "$SHARED_DIR" ] || die "SHARED_DIR does not exist: $SHARED_DIR"

vm_exists() { lume ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$VM"; }
vm_json()   { lume get "$VM" --format json 2>/dev/null; }
# lume prints non-JSON when a VM is stopped or unknown; let jq fail quietly so
# pipefail does not abort the script mid-provision.
vm_status() { vm_json | jq -r '.[0].status // empty' 2>/dev/null || true; }
vm_ip()     { vm_json | jq -r '.[0].ipAddress // empty' 2>/dev/null || true; }
in_vm()     { lume ssh "$VM" "$1"; }

# bash 3.2 ships on stock macOS: no ${var^^}
to_bytes() {
  v=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$v" in
    *MB) echo $(( ${v%MB} * 1024 * 1024 )) ;;
    *GB) echo $(( ${v%GB} * 1024 * 1024 * 1024 )) ;;
    *)   echo $(( v * 1024 * 1024 * 1024 )) ;;
  esac
}

start_vm() {
  log "starting $VM (headless, clipboard${SHARED_DIR:+, shared dir})"
  RUN_ARGS=(--display none --clipboard --detach)
  [ -n "$SHARED_DIR" ] && RUN_ARGS+=(--shared-dir "${SHARED_DIR}:rw")
  lume run "$VM" "${RUN_ARGS[@]}"
  log "waiting for IP"
  for _ in $(seq 1 60); do [ -n "$(vm_ip)" ] && break; sleep 5; done
  [ -n "$(vm_ip)" ] || die "$VM never got an IP"
  log "waiting for SSH"
  for _ in $(seq 1 60); do in_vm true >/dev/null 2>&1 && break; sleep 5; done
  in_vm true >/dev/null 2>&1 || die "SSH never came up on $VM"
}

# lume 0.5.3's stop is unreliable: it can return silently leaving the VM running,
# or fail from `stop` itself with "Cannot modify <vm>: the VM is running. Stop it
# first." Fall back to terminating the VM process, which is what stop would do.
# The trailing space in the pkill pattern keeps "foo" from matching "foo-golden".
stop_vm() {
  [ "$(vm_status)" = "running" ] || return 0
  log "stopping $VM"
  lume stop "$VM" >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do [ "$(vm_status)" = "running" ] || return 0; sleep 2; done
  warn "lume stop did not take — terminating the VM process directly"
  pkill -TERM -f "lume run $VM " 2>/dev/null || true
  for _ in $(seq 1 30); do [ "$(vm_status)" = "running" ] || return 0; sleep 2; done
  die "could not stop $VM"
}

# ---------------------------------------------------------------- 0. teardown
if [ "$RECREATE" -eq 1 ] && vm_exists; then
  log "--recreate: destroying existing $VM"
  stop_vm
  lume delete "$VM" --force
fi

# ------------------------------------------------------- 1. acquire the image
if vm_exists; then
  log "$VM already exists — skipping acquisition"
elif [ -n "$GOLDEN" ]; then
  # APFS copy-on-write: ~2 seconds, ~0 bytes. Always prefer this to a re-pull.
  log "cloning $GOLDEN -> $VM"
  lume clone "$GOLDEN" "$VM"
else
  # lume caches under ~/.lume/cache but keeps only the CURRENT manifest per
  # image, so a moved :latest tag means a full ~21 GB download again.
  log "pulling $IMAGE as $VM"
  lume pull "$IMAGE" "$VM"
fi

# ------------------------------------------------------------- 2. size the VM
# Resize requires the VM stopped and is increase-only. Image defaults differ:
# macos-tahoe-vanilla is 100 GB, macos-tahoe-cua is already 150 GB.
stop_vm
SET_ARGS="--cpu $CPU --memory $MEMORY --display $DISPLAY_RES"
if [ -n "$DISK_SIZE" ]; then
  CUR_DISK="$(vm_json | jq -r '.[0].diskSize.total // 0')"
  if [ "$(to_bytes "$DISK_SIZE")" -gt "$CUR_DISK" ]; then
    SET_ARGS="$SET_ARGS --disk-size $DISK_SIZE"
  else
    warn "disk is already $(( CUR_DISK / 1024 / 1024 / 1024 )) GB >= requested $DISK_SIZE; skipping resize (increase-only)"
  fi
fi
log "setting cpu=$CPU memory=$MEMORY display=$DISPLAY_RES${DISK_SIZE:+ disk=$DISK_SIZE}"
# shellcheck disable=SC2086
lume set "$VM" $SET_ARGS

# ---------------------------------------------------------------- 3. boot it
start_vm
IP="$(vm_ip)"
log "$VM is up at $IP"

# ------------------------------- 4. the precondition everything else rests on
# The console owner IS the answer: root = login window, lume = real Aqua session.
# Do NOT infer this from SSH — a vanilla image has working SSH at the login
# window, which is what makes the downstream symptoms look unrelated.
console_owner() { in_vm "stat -f '%Su' /dev/console" | tr -d '\r\n '; }

if [ "$(console_owner)" != "$VM_USER" ]; then
  warn "/dev/console owned by '$(console_owner)' — no GUI session; applying unattended setup"
  stop_vm
  # Offline disk patch: skips Setup Assistant, creates the lume user, enables
  # autologin + SSH, disables the screensaver lock, verifies SSH, stops the VM.
  lume setup "$VM" --unattended tahoe
  start_vm
  [ "$(console_owner)" = "$VM_USER" ] || die "still no Aqua session after lume setup — investigate at the VM screen"
fi
log "Aqua session confirmed (/dev/console owned by $VM_USER)"

# ------------------------------------------------- 4b. SSH key auth for MCP
# The MCP wrapper runs with BatchMode=yes, because a password prompt on stdin
# would corrupt the JSON-RPC stream. Key auth has to work before it will.
PUBKEY=""
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  [ -f "$k" ] && { PUBKEY="$(cat "$k")"; break; }
done
if [ -n "$PUBKEY" ]; then
  log "installing host public key for MCP key auth"
  in_vm "mkdir -p ~/.ssh && chmod 700 ~/.ssh
    grep -qxF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys" || warn "could not install public key"
else
  warn "no ~/.ssh/id_ed25519.pub or id_rsa.pub found — the MCP wrapper needs key auth (ssh-keygen -t ed25519)"
fi

# --------------------------------------- 4c. terminfo for the host's terminal
# Ghostty, kitty and WezTerm ship terminfo entries a stock macOS guest has never
# heard of, so SSHing in gets "unknown terminal type" and loses colors, arrow
# keys and backspace. Export the host's own entry into the guest.
#
# It goes into the guest user's ~/.terminfo, which ncurses already searches
# first on stock macOS (`infocmp -D`) — so no TERMINFO_DIRS, no rc files, no
# sudo. A system-wide install is not really on offer anyway: /usr/share/terminfo
# sits on the sealed read-only system volume and `tic -o` there fails even as
# root with SIP off.
#
# `lume ssh` does not forward stdin, so the usual `infocmp | ssh host tic -`
# pipe hangs and times out. The entry is base64'd into the command instead.
if [ "$INSTALL_TERMINFO" -eq 1 ] && [ -n "$TERMINFO_TERMS" ]; then
  TI_WANTED=""
  for t in $TERMINFO_TERMS; do
    if in_vm "infocmp $t >/dev/null 2>&1" 2>/dev/null; then
      log "terminfo '$t' already resolves in the guest"
    elif infocmp -x "$t" >/dev/null 2>&1; then
      TI_WANTED="$TI_WANTED $t"
    else
      warn "host has no terminfo entry for '$t' — skipping"
    fi
  done

  if [ -n "$TI_WANTED" ]; then
    log "installing terminfo into ~$VM_USER/.terminfo in the guest:$TI_WANTED"
    # shellcheck disable=SC2086
    TI_SRC_B64="$(for t in $TI_WANTED; do infocmp -x "$t"; done | base64 | tr -d '\n')"
    # tic warns "older tic versions may treat the description field as an alias"
    # on these entries and still exits 0; the per-entry check below is the real
    # verdict, so just drop that line from the output.
    in_vm "echo '$TI_SRC_B64' | base64 -D > /tmp/cua-terminfo.src
      mkdir -p ~/.terminfo
      tic -x -o ~/.terminfo /tmp/cua-terminfo.src
      rm -f /tmp/cua-terminfo.src" 2>&1 \
      | grep -v 'older tic versions' | sed 's/^/    /' || true

    for t in $TI_WANTED; do
      in_vm "infocmp $t >/dev/null 2>&1" 2>/dev/null \
        && log "terminfo '$t' now resolves in the guest" \
        || warn "terminfo '$t' still does not resolve in the guest"
    done
  fi
fi

# ---------------------------------------------------------------- 5. the driver
if in_vm "test -x $DRIVER_BIN" 2>/dev/null; then
  log "cua-driver already present: $(in_vm "$DRIVER_BIN --version 2>/dev/null" | tr -d '\r')"
else
  log "installing cua-driver (no sudo: lume is admin, /Applications is admin-writable)"
  in_vm "curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-install.sh && bash /tmp/cua-install.sh"
fi

# The LaunchAgent must invoke the IN-BUNDLE binary, not the ~/.local/bin shim, so
# the process keeps the app's code signature and therefore its TCC identity
# (com.trycua.driver). `cua-driver autostart` is Windows-only today.
if in_vm "launchctl print gui/\$(id -u)/com.trycua.driver >/dev/null 2>&1"; then
  log "LaunchAgent already loaded"
else
  log "installing + loading LaunchAgent"
  in_vm "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/com.trycua.driver.plist <<'PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>com.trycua.driver</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DRIVER_BIN</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/cua-driver.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/cua-driver.err.log</string>
</dict>
</plist>
PLIST
launchctl bootout gui/\$(id -u)/com.trycua.driver 2>/dev/null || true
launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.trycua.driver.plist"
fi

# ------------------------------------------- 5b. TCC grants, without a human
# cua's docs say the grants must be clicked at the VM's screen. That is true with
# SIP ON. macos-tahoe-cua ships SIP *disabled*, which makes TCC.db writable as
# root — so on that image the grants are scriptable and the run stays unattended.
# The image pre-seeds a kTCCServiceAccessibility row with auth_value=0 (denied),
# so INSERT OR REPLACE is required, not INSERT.
if in_vm "csrutil status" 2>/dev/null | grep -qi disabled; then
  log "SIP disabled — writing TCC grants directly (no VM-screen sitting needed)"
  in_vm "echo '$VM_PASS' | sudo -S sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' \"
    INSERT OR REPLACE INTO access
      (service,client,client_type,auth_value,auth_reason,auth_version,
       indirect_object_identifier_type,indirect_object_identifier,flags)
    VALUES
      ('kTCCServiceAccessibility','com.trycua.driver',0,2,3,1,0,'UNUSED',0),
      ('kTCCServiceScreenCapture','com.trycua.driver',0,2,3,1,0,'UNUSED',0),
      ('kTCCServicePostEvent','com.trycua.driver',0,2,3,1,0,'UNUSED',0),
      ('kTCCServiceListenEvent','com.trycua.driver',0,2,3,1,0,'UNUSED',0);\" 2>&1 | grep -v '^Password' || true
    echo '$VM_PASS' | sudo -S killall tccd 2>/dev/null || true"
  sleep 3
  # The driver only picks up a changed grant after a FULL relaunch.
  in_vm "launchctl kickstart -k gui/\$(id -u)/com.trycua.driver" >/dev/null 2>&1 || true
  sleep 8
else
  warn "SIP is enabled — TCC cannot be scripted; expect the MANUAL STEP below"
fi

# --------------------------------------------------- 5c. guest resolution
# `lume set --display` only makes the mode AVAILABLE to the virtual GPU; macOS
# keeps rendering at whatever it used before, and cua-driver screenshots at the
# guest's resolution no matter what `lume ls` claims.
log "enforcing guest resolution $DISPLAY_RES"
in_vm "mkdir -p ~/.local/bin
  [ -x ~/.local/bin/displayplacer ] || curl -fsSL -o ~/.local/bin/displayplacer \
    https://github.com/jakehilborn/displayplacer/releases/download/v1.4.0/displayplacer-apple-v140
  chmod +x ~/.local/bin/displayplacer
  ID=\$(~/.local/bin/displayplacer list | awk '/^Persistent screen id:/ {print \$4; exit}')
  ~/.local/bin/displayplacer \"id:\$ID res:${DISPLAY_RES} hz:60 color_depth:7 enabled:true scaling:off origin:(0,0) degree:0\"" \
  >/dev/null 2>&1 || warn "could not set guest resolution to $DISPLAY_RES"

# --------------------------------------------- 6. optional Path B (HTTP API)
# PyPI's cua-computer-server has NO [driver] extra despite sharing version
# 0.3.42 with git main, so installing from PyPI yields a nonexistent extra and
# --backend cua-driver dies with "invalid choice". Install from main.
if [ "$INSTALL_COMPUTER_SERVER" -eq 1 ]; then
  log "installing cua-computer-server from git main"
  in_vm "python3 -m venv ~/.venvs/cua-main 2>/dev/null || true
    ~/.venvs/cua-main/bin/pip install -q \
      'cua-computer-server[driver] @ git+https://github.com/trycua/cua.git#subdirectory=libs/python/computer-server'"
fi

# ------------------------------------------------------------ 7. verification
log "verifying"
in_vm "csrutil status" 2>/dev/null | sed 's/^/    /' || true
in_vm "$DRIVER_BIN doctor" 2>&1 | sed 's/^/    /' || warn "doctor reported problems"
PERMS="$(in_vm "$DRIVER_BIN permissions status --json" 2>/dev/null | tr -d '\r' || echo '{}')"
echo "    permissions: $PERMS"

# Booleans flipping is not proof the capture path works. In 0.20.0 the capture
# tool is `get_desktop_state`; `take_screenshot` does not exist and fails with
# "no reviewed risk classification", which looks like a permission error but is
# the driver's own tool-manifest gate.
SMOKE="$(in_vm "$DRIVER_BIN call get_desktop_state '{}'" 2>/dev/null | grep -E 'screenshot_png_b64|screen_width|screen_height' | head -3 || true)"
echo "$SMOKE" | sed 's/^/    /' | cut -c1-90

echo
# 0.19.3 reported {"daemon_running":..,"status":..}; 0.20.0 reports these two
# booleans plus a `source` block. Check what 0.20.0 actually emits.
if printf '%s' "$PERMS" | grep -q '"accessibility":[[:space:]]*true' &&
   printf '%s' "$PERMS" | grep -q '"screen_recording":[[:space:]]*true' &&
   printf '%s' "$SMOKE"  | grep -q 'screenshot_png_b64'; then
  log "DONE — $VM is a working cua sandbox at $IP"
  cat <<EOF

Snapshot it so this never has to run again (APFS CoW, ~2s, ~0 bytes):
    lume stop $VM && lume clone $VM ${VM}-golden
    # future rebuilds:  VM=$VM GOLDEN=${VM}-golden bash provision.sh --recreate
EOF
else
  cat <<EOF
================================ MANUAL STEP ==================================
The TCC grants (Accessibility + Screen Recording) are not confirmed. With SIP
ENABLED this cannot be automated — per cua's docs, "SSH access read-only; cannot
raise macOS permission UI remotely." Expected on macos-tahoe-vanilla; if you see
it on macos-tahoe-cua, check that csrutil really reports disabled.

Grant them once at the VM's screen:
    lume stop $VM && lume run $VM --display vnc

Two traps:
  * TOGGLE THE SWITCH in System Settings. Clicking "Open System Settings" from
    the prompt is not enough.
  * When macOS offers to quit and reopen CuaDriver, ACCEPT — the driver only
    picks up a changed grant after a full relaunch.

xcode-select --install and the Homebrew bootstrap also need interactive sudo, so
do all of it in ONE sitting. Then clone the result as ${VM}-golden.
===============================================================================
EOF
fi

cat <<EOF

Register the MCP server with the wrapper, which re-resolves the IP at connect
time (a NAT VM's IP drifts across reboots; a baked-in IP fails silently):
    install -m 755 scripts/cua-mcp-wrapper.sh ~/.local/bin/cua-${VM}-mcp
    claude mcp add --scope user cua-driver-vm -- ~/.local/bin/cua-${VM}-mcp
EOF
