#!/usr/bin/env bash
#
# install-ext4.sh — plain SINGLE-DISK ext4 Ubuntu Server install (GRUB-EFI).
# Fallback for when you do NOT have two equal-size disks (one disk, or mismatched sizes).
# Run as root in a booted Ubuntu Server LIVE env (UEFI). *** DESTRUCTIVE *** to DISK1.
#
#   DISK1=/dev/disk/by-id/... INSTALL_PASSWORD=.. \
#     [ADMIN_USER=developer SSH_AUTHORIZED_KEY=.. HOSTNAME=ubuntu TIMEZONE=..] \
#     sudo -E ./install-ext4.sh [--yes]
#
# Layout: p1 ESP 1G (FAT32) | p2 ext4 root (rest). Boots via GRUB-EFI (no ZFS).
#
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo; echo "=== $* ==="; }

: "${DISK1:?set DISK1 to a /dev/disk/by-id path (run: sudo ./install.sh --list)}"
ADMIN_USER="${ADMIN_USER:-developer}"
INSTALL_PASSWORD="${INSTALL_PASSWORD:-passw0rd}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
HOSTNAME_NEW="${HOSTNAME:-ubuntu}"
TIMEZONE="${TIMEZONE:-Etc/UTC}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
ESP_SIZE="${ESP_SIZE:-+1G}"
ASSUME_YES=0; [ "${1:-}" = "--yes" ] && ASSUME_YES=1
trap 'rm -f /mnt/root/.ext4-secrets 2>/dev/null || true' EXIT

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -d /sys/firmware/efi ] || die "NOT booted in UEFI mode"
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
SUITE="${SUITE:-${VERSION_CODENAME:-}}"; [ -n "$SUITE" ] || die "pass SUITE=<codename>"
DEV="$(readlink -f "$DISK1")" || die "bad DISK1"; [ -b "$DEV" ] || die "DISK1 not a block device"
case "$DEV" in /dev/nvme*n[0-9]|/dev/sd[a-z]|/dev/vd[a-z]) ;; *) die "$DEV is not a whole disk";; esac
lsblk -rno MOUNTPOINT "$DEV" 2>/dev/null | grep -q . && die "$DEV has mounted partitions — looks like the live medium; refusing"

say "Target (will be ERASED): $DISK1 -> $DEV   suite=$SUITE"
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT "$DEV" || true
if [ "$ASSUME_YES" -ne 1 ]; then
  echo; echo "*** $DEV will be COMPLETELY ERASED. ***"
  read -r -p "Type ERASE to proceed: " a; [ "$a" = "ERASE" ] || die "aborted by operator"
fi

say "tooling + teardown"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y; apt-get install -y debootstrap gdisk dosfstools lvm2
swapoff -a 2>/dev/null || true; zpool export -a 2>/dev/null || true
command -v vgchange >/dev/null 2>&1 && vgchange -an 2>/dev/null || true
command -v mdadm    >/dev/null 2>&1 && mdadm --stop --scan 2>/dev/null || true
command -v dmsetup  >/dev/null 2>&1 && dmsetup remove_all 2>/dev/null || true

say "partition (ESP + ext4 root)"
for pp in "$DISK1"-part*; do [ -e "$pp" ] && wipefs -a "$pp" 2>/dev/null || true; done
wipefs -a "$DEV" 2>/dev/null || true; sgdisk --zap-all "$DEV"
sgdisk -n1:1m:"$ESP_SIZE" -t1:EF00 -c1:EFI  "$DEV"
sgdisk -n2:0:0           -t2:8300 -c2:root "$DEV"
timeout 25 partprobe "$DEV" 2>/dev/null || true; timeout 30 udevadm settle 2>/dev/null || true
for x in "$DISK1"-part1 "$DISK1"-part2; do
  for _ in $(seq 1 20); do [ -e "$x" ] && break; timeout 10 udevadm settle 2>/dev/null || true; sleep 0.5; done
  [ -e "$x" ] || die "partition $x never appeared"
done

say "format + mount"
mkfs.vfat -F32 -s1 -n EFI "$DISK1-part1"
mkfs.ext4 -F -L root "$DISK1-part2"
mount "$DISK1-part2" /mnt
mkdir -p /mnt/boot/efi; mount "$DISK1-part1" /mnt/boot/efi
ESP_UUID="$(blkid -s UUID -o value "$DISK1-part1")"
ROOT_UUID="$(blkid -s UUID -o value "$DISK1-part2")"

say "debootstrap $SUITE"
debootstrap "$SUITE" /mnt "$MIRROR"
cp /etc/resolv.conf /mnt/etc/resolv.conf
for m in dev proc sys run; do mount --rbind "/$m" "/mnt/$m"; mount --make-rslave "/mnt/$m"; done

cat > /mnt/root/install-vars.env <<EOF
SUITE=${SUITE}
MIRROR=${MIRROR}
ESP_UUID=${ESP_UUID}
ROOT_UUID=${ROOT_UUID}
HOSTNAME_NEW=${HOSTNAME_NEW}
TIMEZONE=${TIMEZONE}
ADMIN_USER=${ADMIN_USER}
EOF
{ echo "INSTALL_PASSWORD_B64=$(printf '%s' "$INSTALL_PASSWORD" | base64 -w0)"
  echo "SSH_AUTHORIZED_KEY_B64=$(printf '%s' "$SSH_AUTHORIZED_KEY" | base64 -w0)"; } > /mnt/root/.ext4-secrets
chmod 600 /mnt/root/.ext4-secrets

cat > /mnt/root/ext4-chroot.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
. /root/install-vars.env
[ -f /root/.ext4-secrets ] && . /root/.ext4-secrets || true
INSTALL_PASSWORD="$(printf '%s' "${INSTALL_PASSWORD_B64:-}" | base64 -d 2>/dev/null || true)"; [ -n "$INSTALL_PASSWORD" ] || INSTALL_PASSWORD="passw0rd"
SSH_AUTHORIZED_KEY="$(printf '%s' "${SSH_AUTHORIZED_KEY_B64:-}" | base64 -d 2>/dev/null || true)"
export DEBIAN_FRONTEND=noninteractive
cat > /etc/apt/sources.list.d/ubuntu.sources <<SRC
Types: deb
URIs: ${MIRROR}
Suites: ${SUITE} ${SUITE}-updates ${SUITE}-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: ${SUITE}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
rm -f /etc/apt/sources.list 2>/dev/null || true
apt-get update -y
apt-get install -y --no-install-recommends locales tzdata
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen; locale-gen; update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$HOSTNAME_NEW" > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' "$HOSTNAME_NEW" > /etc/hosts
apt-get install -y --no-install-recommends linux-generic linux-firmware grub-efi-amd64 dosfstools efibootmgr \
  openssh-server netplan.io systemd-resolved sudo nvme-cli iproute2 iputils-ping nano less
cat > /etc/fstab <<FST
UUID=${ROOT_UUID}  /          ext4  defaults        0 1
UUID=${ESP_UUID}   /boot/efi  vfat  umask=0077,nofail 0 1
FST
mkdir -p /etc/netplan
cat > /etc/netplan/01-netcfg.yaml <<NET
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
NET
chmod 600 /etc/netplan/01-netcfg.yaml
systemctl enable ssh systemd-networkd systemd-resolved 2>/dev/null || true
echo "root:${INSTALL_PASSWORD}" | chpasswd
id "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
echo "${ADMIN_USER}:${INSTALL_PASSWORD}" | chpasswd
if [ -n "$SSH_AUTHORIZED_KEY" ]; then
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"
  printf '%s\n' "$SSH_AUTHORIZED_KEY" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "/home/${ADMIN_USER}/.ssh/authorized_keys"; chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
fi
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true
update-initramfs -u -k all || update-initramfs -c -k all
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-grub
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
echo "ext4 chroot complete."
CHROOT
chmod +x /mnt/root/ext4-chroot.sh

say "chroot config + GRUB-EFI install"
chroot /mnt /bin/bash /root/ext4-chroot.sh

say "finalize"
rm -f /mnt/root/ext4-chroot.sh /mnt/root/install-vars.env /mnt/root/.ext4-secrets
sync
umount -R /mnt/boot/efi 2>/dev/null || umount -Rl /mnt/boot/efi 2>/dev/null || true
for m in run sys proc dev; do umount -R "/mnt/$m" 2>/dev/null || umount -Rl "/mnt/$m" 2>/dev/null || true; done
umount -R /mnt 2>/dev/null || umount -Rl /mnt 2>/dev/null || true
cat <<EOF

============================================================
 DONE (ext4 single-disk).  Host: ${HOSTNAME_NEW}   Login: ${ADMIN_USER} / root
 Disk: $DEV  (ESP + ext4 root, GRUB-EFI)   suite: $SUITE
 Remove install media / set this disk first in UEFI boot order, then reboot.
============================================================
EOF
