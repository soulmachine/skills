#!/usr/bin/env bash
# validate.sh — run on the freshly-booted INSTALLED system. Read-only. Works for ZFS or ext4 installs.
set -uo pipefail
say(){ echo; echo "=== $* ==="; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

say "host / os / kernel"; hostname; (. /etc/os-release; echo "$PRETTY_NAME"); uname -r

say "root filesystem"; findmnt -no SOURCE,FSTYPE,TARGET /

if $SUDO zpool list rpool >/dev/null 2>&1; then
  say "ZFS install detected — pool health (expect rpool mirror-0 with both legs ONLINE)"
  $SUDO zpool status
  echo; say "datasets / mounts"; $SUDO zfs list -o name,used,avail,mountpoint 2>/dev/null
  echo; df -h / /data 2>/dev/null
  echo; say "ZFSBootMenu entries (expect two)"; $SUDO efibootmgr 2>/dev/null | grep -i ZFSBootMenu || echo "none found"
else
  say "ext4 install detected"
  df -h / /boot/efi 2>/dev/null
  echo; say "GRUB EFI boot entry"; $SUDO efibootmgr 2>/dev/null | grep -iE "ubuntu|grub" || echo "none found"
fi

say "system state (want: running)"; systemctl is-system-running 2>/dev/null
echo "failed units:"; systemctl --failed --no-legend 2>/dev/null || true
say "hostid"; hostid
echo
echo "Tip: confirm a SECOND unattended reboot also comes up clean (hands-free)."
