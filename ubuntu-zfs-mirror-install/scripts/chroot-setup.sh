#!/usr/bin/env bash
#
# chroot-setup.sh — runs INSIDE the chroot (/mnt) via install.sh (ZFS path). Do not run directly.
# Configures the base OS, sets the udev-settle override so ZFS import services don't stall,
# and HARD-GATES on ZFS being in the initramfs before the install is allowed to finish.
#
set -euo pipefail
[ -f /root/install-vars.env ] || { echo "missing /root/install-vars.env" >&2; exit 1; }
# shellcheck disable=SC1091
. /root/install-vars.env
# shellcheck disable=SC1091
[ -f /root/.install-secrets ] && . /root/.install-secrets || true
INSTALL_PASSWORD="$(printf '%s' "${INSTALL_PASSWORD_B64:-}" | base64 -d 2>/dev/null || true)"; [ -n "$INSTALL_PASSWORD" ] || INSTALL_PASSWORD="passw0rd"
SSH_AUTHORIZED_KEY="$(printf '%s' "${SSH_AUTHORIZED_KEY_B64:-}" | base64 -d 2>/dev/null || true)"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
export DEBIAN_FRONTEND=noninteractive
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo; echo "--- $* ---"; }

say "apt sources ($SUITE)"
cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
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
EOF
rm -f /etc/apt/sources.list 2>/dev/null || true
apt-get update -y

say "locale / timezone / hostname"
apt-get install -y --no-install-recommends locales tzdata
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen; locale-gen; update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$HOSTNAME_NEW" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME_NEW}
::1 localhost ip6-localhost ip6-loopback
EOF

say "core packages (NO grub — ZFSBootMenu boots this)"
apt-get install -y --no-install-recommends \
  linux-generic linux-firmware zfs-initramfs zfsutils-linux \
  dosfstools efibootmgr curl ca-certificates \
  openssh-server netplan.io systemd-resolved sudo nvme-cli iproute2 iputils-ping nano less

say "fstab (ESP only; ZFS datasets are mounted by ZFS)"
echo "UUID=${ESP_UUID}  /boot/efi  vfat  umask=0077,nofail  0  1" > /etc/fstab

say "netplan (DHCP on all en* NICs)"
mkdir -p /etc/netplan
cat > /etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
EOF
chmod 600 /etc/netplan/01-netcfg.yaml

say "enable services"
systemctl enable ssh systemd-networkd systemd-resolved \
  zfs-import-cache zfs-import.target zfs-mount zfs.target zfs-zed 2>/dev/null || true

say "credentials (root + ${ADMIN_USER})"
echo "root:${INSTALL_PASSWORD}" | chpasswd
id "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
echo "${ADMIN_USER}:${INSTALL_PASSWORD}" | chpasswd
if [ -n "$SSH_AUTHORIZED_KEY" ]; then
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"
  printf '%s\n' "$SSH_AUTHORIZED_KEY" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "/home/${ADMIN_USER}/.ssh/authorized_keys"; chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/'  /etc/ssh/sshd_config 2>/dev/null || true
else
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
fi
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/'   /etc/ssh/sshd_config 2>/dev/null || true

say "udev-settle override — ZFS import units hard-Requires it; make it succeed instantly so dpool auto-imports"
mkdir -p /etc/systemd/system/systemd-udev-settle.service.d
printf '[Service]\nExecStart=\nExecStart=/bin/true\nTimeoutStartSec=10\n' > /etc/systemd/system/systemd-udev-settle.service.d/override.conf

say "build initramfs, then HARD-GATE on ZFS being inside it"
update-initramfs -u -k all || update-initramfs -c -k all
IMG="$(ls -1 /boot/initrd.img-* 2>/dev/null | head -1)"; [ -n "$IMG" ] || die "no initrd generated"
if lsinitramfs "$IMG" 2>/dev/null | grep -qi 'zfs'; then
  echo "OK: ZFS present in $IMG"
else
  echo "WARN: ZFS missing from initramfs-tools image; trying dracut..."
  apt-get install -y zfs-dracut || true
  dracut --force --kver "$(ls -1 /lib/modules | head -1)" || die "dracut failed"
  IMG="$(ls -1 /boot/initramfs-*.img /boot/initrd.img-* 2>/dev/null | head -1)"
  { command -v lsinitrd >/dev/null 2>&1 && lsinitrd "$IMG" 2>/dev/null | grep -qi 'zfs'; } || die "ZFS STILL MISSING FROM INITRD ($IMG) — DO NOT REBOOT"
  echo "OK: ZFS present in $IMG (dracut)"
fi

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
echo "chroot-setup complete."
