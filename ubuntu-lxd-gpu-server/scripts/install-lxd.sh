#!/usr/bin/env bash
# Install LXD on an Ubuntu host and grant ALL NVIDIA GPUs to every container via CDI.
# Idempotent: safe to re-run. Run as root (via sudo).
#
# Assumes the host NVIDIA driver + nvidia-container-toolkit (nvidia-ctk) are ALREADY installed
# (see the ubuntu-nvidia-gpu-enablement skill). This only wires LXD -> GPUs, it does NOT install drivers.
#
# Config via environment:
#   LXD_STORAGE   zfs:<pool>/<dataset> | dir | zfs-loop:<size> | btrfs:/dev/sdX   (default: dir)
#   LXD_CHANNEL   snap channel for lxd                                            (default: 5.21/stable)
#   GPU_ID        CDI device to attach to the default profile                     (default: nvidia.com/gpu=all)
#   CDI_REGEN     1 = force regenerate /etc/cdi/nvidia.yaml                        (default: regen only if missing)
#
# Examples:
#   sudo LXD_STORAGE=zfs:rpool/lxd bash install-lxd.sh
#   sudo LXD_STORAGE=dir bash install-lxd.sh
set -euo pipefail

LXD_STORAGE="${LXD_STORAGE:-dir}"
LXD_CHANNEL="${LXD_CHANNEL:-5.21/stable}"
GPU_ID="${GPU_ID:-nvidia.com/gpu=all}"
LXC=/snap/bin/lxc
LXD=/snap/bin/lxd

log(){ printf '\n=== %s ===\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)"

# --- pre-flight: host GPU + host CDI toolkit must already be present ---
command -v nvidia-smi >/dev/null || die "nvidia-smi not found — enable the host GPU first (ubuntu-nvidia-gpu-enablement)"
nvidia-smi -L >/dev/null 2>&1   || die "nvidia-smi can't reach the driver — fix the host GPU before LXD"
command -v nvidia-ctk >/dev/null || die "nvidia-ctk not found — install nvidia-container-toolkit on the host (ubuntu-nvidia-gpu-enablement Step 5)"
log "host sees $(nvidia-smi -L | grep -c '^GPU ') GPU(s)"

# --- snapd (debootstrap/minimal bases ship none) ---
if ! command -v snap >/dev/null; then
  log "installing snapd"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
fi
snap wait system seed.loaded 2>/dev/null || true

# --- lxd snap ---
if ! snap list lxd >/dev/null 2>&1; then
  log "installing lxd snap ($LXD_CHANNEL)"
  snap install lxd --channel="$LXD_CHANNEL"
fi
"$LXD" waitready --timeout=120
log "lxd $("$LXD" --version)"

# --- lxd init (only if not yet initialised) ---
if "$LXC" storage list -f csv 2>/dev/null | grep -q .; then
  log "LXD already has a storage pool — skipping 'lxd init'"
else
  log "initialising LXD (storage: $LXD_STORAGE)"
  case "$LXD_STORAGE" in
    zfs:*)      pool_block=$'- name: default\n  driver: zfs\n  config:\n    source: '"${LXD_STORAGE#zfs:}" ;;
    zfs-loop:*) pool_block=$'- name: default\n  driver: zfs\n  config:\n    size: '"${LXD_STORAGE#zfs-loop:}" ;;
    btrfs:*)    pool_block=$'- name: default\n  driver: btrfs\n  config:\n    source: '"${LXD_STORAGE#btrfs:}" ;;
    dir)        pool_block=$'- name: default\n  driver: dir' ;;
    *) die "bad LXD_STORAGE='$LXD_STORAGE' (use zfs:<pool>/lxd | dir | zfs-loop:50GiB | btrfs:/dev/sdX)" ;;
  esac
  cat <<PRESEED | "$LXD" init --preseed
config: {}
networks:
- name: lxdbr0
  type: bridge
  config:
    ipv4.address: auto
    ipv6.address: none
storage_pools:
$pool_block
profiles:
- name: default
  devices:
    eth0:
      name: eth0
      network: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
PRESEED
fi

# --- add the invoking user to the lxd group (passwordless lxc after re-login) ---
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != root ]; then
  usermod -aG lxd "$SUDO_USER" && log "added '$SUDO_USER' to lxd group (re-login for sudo-less lxc)"
fi

# --- CDI spec from the HOST toolkit ---
# Prefer the toolkit's own auto-refresh units (nvidia-cdi-refresh.{service,path}, shipped by
# nvidia-container-toolkit-base >= 1.17): they regenerate the spec on every driver/toolkit change
# AND at boot, so it never goes stale after an upgrade. They default to the tmpfs /var/run/cdi; we pin
# them to the persistent /etc/cdi so LXD reads one stable location with no boot-time race. Older
# toolkits have no such units -> fall back to generate-once + a boot unit (REFERENCE §5).
CDI_SPEC=/etc/cdi/nvidia.yaml
CDI_ENV=/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env
mkdir -p /etc/cdi
if systemctl cat nvidia-cdi-refresh.service >/dev/null 2>&1; then
  log "using packaged nvidia-cdi-refresh units (auto-regenerate on driver/toolkit upgrade + boot)"
  # pin output to the persistent /etc/cdi via the toolkit's own override file (idempotent)
  mkdir -p "$(dirname "$CDI_ENV")"
  if ! grep -qxF "NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=$CDI_SPEC" "$CDI_ENV" 2>/dev/null; then
    sed -i '/^NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/d' "$CDI_ENV" 2>/dev/null || true
    printf '\n# Pinned by ubuntu-lxd-gpu-server: persistent path LXD reads (survives reboot, no tmpfs race).\nNVIDIA_CTK_CDI_OUTPUT_FILE_PATH=%s\n' "$CDI_SPEC" >> "$CDI_ENV"
  fi
  systemctl enable nvidia-cdi-refresh.path nvidia-cdi-refresh.service >/dev/null 2>&1 || true
  systemctl start nvidia-cdi-refresh.service >/dev/null 2>&1 || true        # regenerate now -> /etc/cdi
  rm -f /var/run/cdi/nvidia.yaml /run/cdi/nvidia.yaml 2>/dev/null || true    # drop stale tmpfs spec (avoids duplicate-device conflict)
  [ -f "$CDI_SPEC" ] || nvidia-ctk cdi generate --output="$CDI_SPEC" >/dev/null
else
  if [ "${CDI_REGEN:-0}" = 1 ] || [ ! -f "$CDI_SPEC" ]; then
    log "generating CDI spec -> $CDI_SPEC (toolkit ships no auto-refresh units)"
    nvidia-ctk cdi generate --output="$CDI_SPEC" >/dev/null
  fi
  # boot-time regen so a driver upgrade can't leave a stale spec. Distinct unit name so a later toolkit
  # upgrade that DOES ship nvidia-cdi-refresh.* never collides with this hand-rolled unit.
  log "installing boot-time CDI refresh unit (lxd-nvidia-cdi-refresh.service)"
  cat >/etc/systemd/system/lxd-nvidia-cdi-refresh.service <<UNIT
[Unit]
Description=Regenerate NVIDIA CDI spec for LXD (fallback; toolkit ships no nvidia-cdi-refresh units)
After=local-fs.target
Before=snap.lxd.daemon.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/mkdir -p /etc/cdi
ExecStart=$(command -v nvidia-ctk) cdi generate --output=$CDI_SPEC

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable lxd-nvidia-cdi-refresh.service >/dev/null 2>&1 || true
fi
nvidia-ctk cdi list 2>/dev/null | sed 's/^/  /' || true

# --- grant all GPUs to all instances via the default profile ---
# remove any stale/broken legacy runtime config first (see REFERENCE §4)
"$LXC" profile unset default nvidia.runtime 2>/dev/null || true
"$LXC" profile unset default nvidia.driver.capabilities 2>/dev/null || true
if "$LXC" profile device get default gpu0 type >/dev/null 2>&1; then
  log "default profile already has a 'gpu0' device — leaving as-is"
else
  log "attaching CDI GPU device ($GPU_ID) to default profile"
  "$LXC" profile device add default gpu0 gpu gputype=physical id="$GPU_ID"
fi

log "default profile"
"$LXC" profile show default
cat <<EOF

Done. Verify with:   bash $(dirname "$0")/verify-gpu.sh
EOF
