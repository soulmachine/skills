#!/usr/bin/env bash
#
# install.sh — Ubuntu Server on a 2-disk ZFS MIRROR root (rpool->/) + STRIPE (dpool->/data),
#              booted with ZFSBootMenu. Run as root inside a booted Ubuntu Server LIVE env (UEFI).
#
# *** DESTRUCTIVE *** — wipes DISK1 and DISK2 entirely.
#
# Modes:
#   sudo ./install.sh --list                      # enumerate candidate disks (read-only, no changes)
#   DISK1=.. DISK2=.. INSTALL_PASSWORD=.. \
#     [RPOOL_SIZE=+1T ADMIN_USER=developer SSH_AUTHORIZED_KEY=.. HOSTNAME=.. TIMEZONE=..] \
#     sudo -E ./install.sh [--yes]                # do the install (--yes skips the ERASE prompt)
#
# DISK1/DISK2 should be /dev/disk/by-id/ paths (stable). Works for NVMe and SATA/virtio SSDs.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo; echo "=== $* ==="; }

# --- stable by-id path for a whole-disk device ($1=/dev/sdX or /dev/nvmeXnY) ---
byid_for(){
  local dev="$1" link best=""
  for link in /dev/disk/by-id/*; do
    case "$link" in *-part*) continue;; esac
    [ "$(readlink -f "$link" 2>/dev/null)" = "$dev" ] || continue
    case "$link" in */nvme-eui.*|*/wwn-*) [ -z "$best" ] && best="$link";; *) echo "$link"; return;; esac
  done
  [ -n "$best" ] && { echo "$best"; return; }
  echo "$dev"
}

# --- whole disks that currently back the live/USB medium (to exclude) ---
live_disks(){
  local s d
  findmnt -rno SOURCE / /cdrom /run/live/medium /isodevice 2>/dev/null | grep '^/dev/' | while read -r s; do
    d="$(lsblk -npo PKNAME "$s" 2>/dev/null | head -1)"; [ -n "$d" ] && echo "$d"
  done
  # any disk with a mounted partition is in-use → treat as live medium
  for n in $(lsblk -dpno NAME); do
    [ "$(lsblk -dno TYPE "$n" 2>/dev/null)" = "disk" ] || continue
    lsblk -rno MOUNTPOINT "$n" 2>/dev/null | grep -q . && echo "$n"
  done
}

if [ "${1:-}" = "--list" ]; then
  say "Candidate fixed disks — pick TWO (by their by-id path) as DISK1/DISK2"
  LIVE=" $(live_disks | sort -u | tr '\n' ' ') "
  for n in $(lsblk -dpno NAME); do
    [ "$(lsblk -dno TYPE "$n")" = "disk" ] || continue
    [ "$(lsblk -dno RM "$n")" = "1" ] && continue
    tag=""; case "$LIVE" in *" $n "*) tag="   <-- [LIVE MEDIUM, do NOT pick]";; esac
    printf '%-13s %-8s %-5s %s (%s)%s\n        by-id: %s\n' \
      "$n" "$(lsblk -dno SIZE "$n")" "$(lsblk -dno TRAN "$n")" \
      "$(lsblk -dno MODEL "$n")" "$(lsblk -dno SERIAL "$n")" "$tag" "$(byid_for "$n")"
  done
  exit 0
fi

# ===== parameters (env, with defaults) =====
: "${DISK1:?set DISK1 to a /dev/disk/by-id path (run: sudo ./install.sh --list)}"
: "${DISK2:?this ZFS-mirror installer needs TWO equal-size disks; for a single disk OR mismatched sizes use install-ext4.sh}"
RPOOL_SIZE="${RPOOL_SIZE:-+1T}"     # +128G | +256G | +512G | +1T
ESP_SIZE="${ESP_SIZE:-+1G}"
ADMIN_USER="${ADMIN_USER:-developer}"
INSTALL_PASSWORD="${INSTALL_PASSWORD:-passw0rd}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
HOSTNAME_NEW="${HOSTNAME:-ubuntu}"
TIMEZONE="${TIMEZONE:-Etc/UTC}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
ASSUME_YES=0; [ "${1:-}" = "--yes" ] && ASSUME_YES=1

cleanup_secrets(){ rm -f /mnt/root/.install-secrets 2>/dev/null || true; }
trap cleanup_secrets EXIT

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -d /sys/firmware/efi ] || die "NOT booted in UEFI mode — ZFSBootMenu requires UEFI (disable CSM)."
[ -f "$HERE/chroot-setup.sh" ] || die "chroot-setup.sh must sit next to install.sh"
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
SUITE="${SUITE:-${VERSION_CODENAME:-}}"
[ -n "$SUITE" ] || die "could not auto-detect Ubuntu codename; pass SUITE=<codename>"

NVME1="$(readlink -f "$DISK1")" || die "bad DISK1"
NVME2="$(readlink -f "$DISK2")" || die "bad DISK2"
{ [ -b "$NVME1" ] && [ -b "$NVME2" ]; } || die "DISK1/DISK2 must resolve to block devices"
[ "$NVME1" != "$NVME2" ] || die "DISK1 and DISK2 resolve to the same device ($NVME1)"
for d in "$NVME1" "$NVME2"; do
  case "$d" in /dev/nvme*n[0-9]|/dev/sd[a-z]|/dev/vd[a-z]) ;; *) die "$d is not a whole disk";; esac
  lsblk -rno MOUNTPOINT "$d" 2>/dev/null | grep -q . && die "$d has mounted partitions — looks like the live medium; refusing"
done
# ZFS mirror requires equal-size disks; otherwise fall back to the ext4 single-disk installer.
SZ1="$(blockdev --getsize64 "$NVME1")"; SZ2="$(blockdev --getsize64 "$NVME2")"
[ "$SZ1" = "$SZ2" ] || die "disks differ in size ($SZ1 vs $SZ2 bytes) — use install-ext4.sh (plain ext4, single disk) instead"

say "Targets (will be ERASED) — suite=$SUITE  rpool=$RPOOL_SIZE"
echo "DISK1: $DISK1 -> $NVME1"; echo "DISK2: $DISK2 -> $NVME2"
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT "$NVME1" "$NVME2" || true
if [ "$ASSUME_YES" -ne 1 ]; then
  echo; echo "*** These TWO disks will be COMPLETELY ERASED. ***"
  read -r -p "Type ERASE to proceed: " a; [ "$a" = "ERASE" ] || die "aborted by operator"
fi

say "Phase 0: tooling + tear down any existing zfs/LVM/MD/swap on the targets"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y debootstrap gdisk dosfstools zfsutils-linux efibootmgr curl rsync lvm2
swapoff -a 2>/dev/null || true
zpool export -a 2>/dev/null || true
for p in rpool dpool; do zpool destroy -f "$p" 2>/dev/null || true; done
command -v vgchange >/dev/null 2>&1 && vgchange -an 2>/dev/null || true
command -v mdadm    >/dev/null 2>&1 && mdadm --stop --scan 2>/dev/null || true
command -v dmsetup  >/dev/null 2>&1 && dmsetup remove_all 2>/dev/null || true

say "Phase 1: partition both disks (identical GPT: ESP / rpool / dpool)"
for D in "$DISK1" "$DISK2"; do
  R="$(readlink -f "$D")"
  for pp in "$D"-part*; do [ -e "$pp" ] && wipefs -a "$pp" 2>/dev/null || true; done
  wipefs -a "$R" 2>/dev/null || true
  sgdisk --zap-all "$R"
  sgdisk -n1:1m:"$ESP_SIZE"   -t1:EF00 -c1:EFI   "$R"
  sgdisk -n2:0:"$RPOOL_SIZE"  -t2:BF00 -c2:rpool "$R"
  sgdisk -n3:0:0              -t3:BF00 -c3:dpool  "$R"
done
timeout 25 partprobe "$NVME1" 2>/dev/null || true
timeout 25 partprobe "$NVME2" 2>/dev/null || true
timeout 30 udevadm settle 2>/dev/null || true
for x in "$DISK1"-part1 "$DISK1"-part2 "$DISK1"-part3 "$DISK2"-part1 "$DISK2"-part2 "$DISK2"-part3; do
  for _ in $(seq 1 20); do [ -e "$x" ] && break; timeout 10 udevadm settle 2>/dev/null || true; sleep 0.5; done
  [ -e "$x" ] || die "partition symlink $x never appeared"
done

say "Phase 2: create rpool (mirror) + dpool (stripe) + datasets"
zgenhostid -f 2>/dev/null || true
zpool create -f -o ashift=12 -o autotrim=on \
  -O compression=lz4 -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
  -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=none \
  -R /mnt rpool mirror "$DISK1-part2" "$DISK2-part2"
zpool create -f -o ashift=12 -o autotrim=on \
  -O compression=lz4 -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
  -O relatime=on -O mountpoint=/data \
  -R /mnt dpool "$DISK1-part3" "$DISK2-part3"
UUID="$(openssl rand -hex 4)"
zfs create -o canmount=off   -o mountpoint=none rpool/ROOT
zfs create -o canmount=noauto -o mountpoint=/   rpool/ROOT/ubuntu_${UUID}
zfs mount rpool/ROOT/ubuntu_${UUID}
zfs create -o mountpoint=/home rpool/home
zpool set bootfs=rpool/ROOT/ubuntu_${UUID} rpool

say "Phase 3a: format ESPs"
mkfs.vfat -F32 -s1 -n EFI "$DISK1-part1"
mkfs.vfat -F32 -s1 -n EFI "$DISK2-part1"
ESP_UUID="$(blkid -s UUID -o value "$DISK1-part1")"; [ -n "$ESP_UUID" ] || die "could not read ESP UUID"

say "Phase 4: debootstrap base ($SUITE)"
debootstrap "$SUITE" /mnt "$MIRROR"

say "Phase 3b: mount primary ESP + carry hostid/cache/DNS into target"
mkdir -p /mnt/boot/efi; mount "$DISK1-part1" /mnt/boot/efi
mkdir -p /mnt/etc/zfs
cp -a /etc/hostid /mnt/etc/hostid 2>/dev/null || true
zpool set cachefile=/etc/zfs/zpool.cache rpool
zpool set cachefile=/etc/zfs/zpool.cache dpool
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
cp /etc/resolv.conf /mnt/etc/resolv.conf
for m in dev proc sys run; do mount --rbind "/$m" "/mnt/$m"; mount --make-rslave "/mnt/$m"; done

say "Phase 5-6: chroot config + initramfs ZFS gate"
cat > /mnt/root/install-vars.env <<EOF
UUID=${UUID}
SUITE=${SUITE}
ESP_UUID=${ESP_UUID}
HOSTNAME_NEW=${HOSTNAME_NEW}
TIMEZONE=${TIMEZONE}
ADMIN_USER=${ADMIN_USER}
MIRROR=${MIRROR}
EOF
{ echo "INSTALL_PASSWORD_B64=$(printf '%s' "$INSTALL_PASSWORD" | base64 -w0)"
  echo "SSH_AUTHORIZED_KEY_B64=$(printf '%s' "$SSH_AUTHORIZED_KEY" | base64 -w0)"; } > /mnt/root/.install-secrets
chmod 600 /mnt/root/.install-secrets
install -m 0755 "$HERE/chroot-setup.sh" /mnt/root/chroot-setup.sh
chroot /mnt /bin/bash /root/chroot-setup.sh   # set -e aborts here if the ZFS-in-initramfs gate fails

say "Phase 7: ZFSBootMenu on BOTH ESPs (force-import policy) + boot props"
mkdir -p /mnt/boot/efi/EFI/ZBM
curl -fL -o /mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi
[ -s /mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI ] || die "ZFSBootMenu EFI download failed/empty"
# kernel cmdline lives HERE (no GRUB). zfs_force=1 → OS initramfs force-imports root every boot.
zfs set org.zfsbootmenu:commandline="quiet zfs_force=1" rpool/ROOT
zpool set bootfs=rpool/ROOT/ubuntu_${UUID} rpool
for bn in $(efibootmgr 2>/dev/null | awk '/ZFSBootMenu/{print substr($1,5,4)}'); do efibootmgr -b "$bn" -B >/dev/null 2>&1 || true; done
efibootmgr -c -d "$NVME1" -p 1 -L "ZFSBootMenu (disk1)" -l '\EFI\ZBM\VMLINUZ.EFI' -u "zbm.import_policy=force zbm.set_hostid=0"
efibootmgr -c -d "$NVME2" -p 1 -L "ZFSBootMenu (disk2)" -l '\EFI\ZBM\VMLINUZ.EFI' -u "zbm.import_policy=force zbm.set_hostid=0"
mkdir -p /mnt/boot/efi2; mount "$DISK2-part1" /mnt/boot/efi2; rsync -a /mnt/boot/efi/ /mnt/boot/efi2/; umount /mnt/boot/efi2; rmdir /mnt/boot/efi2

say "Phase 8: scrub secrets, unmount, export"
rm -f /mnt/root/chroot-setup.sh /mnt/root/install-vars.env /mnt/root/.install-secrets
sync
umount -R /mnt/boot/efi 2>/dev/null || umount -Rl /mnt/boot/efi 2>/dev/null || true
for m in run sys proc dev; do umount -R "/mnt/$m" 2>/dev/null || umount -Rl "/mnt/$m" 2>/dev/null || true; done
zpool export dpool  || true
zpool export rpool || true

cat <<EOF

============================================================
 DONE.  Boot environment: rpool/ROOT/ubuntu_${UUID}  (suite: $SUITE)
 Host: ${HOSTNAME_NEW}   Login: ${ADMIN_USER} / root (password as set — change it)
 Next: remove install media (or set the NVMe/SSD first in UEFI boot order), reboot.
       It should boot ZFSBootMenu -> Ubuntu hands-free, with / (mirror) and /data (dpool).
       Then run validate.sh on the booted system.
============================================================
EOF
