#!/usr/bin/env bash
#
# Fix the Docker <-> LXD firewall conflict.
#
# When Docker and LXD share a host, Docker sets the iptables FORWARD chain
# policy to DROP and only ACCEPTs traffic for its own bridges. Forwarded packets
# from the LXD bridge (lxdbr0) match nothing and hit the DROP policy, so LXD
# containers/VMs lose outbound internet (the host itself is unaffected).
#
# Docker provides the DOCKER-USER chain -- evaluated first in FORWARD and never
# flushed by Docker -- precisely so you can allow such traffic. We insert ACCEPT
# rules for every managed LXD bridge there, then persist them with a systemd
# unit ordered after docker.service so they survive reboots and daemon restarts.
#
# Idempotent: safe to re-run. Override the bridge list with:
#     BRIDGES="lxdbr0 lxdbr1" bash fix-lxd-docker-forward.sh
set -euo pipefail

IPT=/usr/sbin/iptables
UNIT=/etc/systemd/system/lxd-docker-forward.service
LXC="$(command -v lxc || echo /snap/bin/lxc)"

# 1. Determine which LXD bridges to protect (managed, type=bridge); default lxdbr0.
if [ -n "${BRIDGES:-}" ]; then
  bridges="$BRIDGES"
else
  # Default `lxc network list --format=csv` columns: NAME,TYPE,MANAGED,...
  bridges="$("$LXC" network list --format=csv 2>/dev/null \
    | awk -F, '$2=="bridge" && $3=="YES" {print $1}' || true)"
  [ -n "$bridges" ] || bridges="lxdbr0"
fi
echo "==> LXD bridges to allow through DOCKER-USER: $bridges"

# 2. Report the FORWARD policy (informational; the fix is idempotent regardless).
if sudo "$IPT" -S FORWARD 2>/dev/null | grep -q -- '-P FORWARD DROP'; then
  echo "==> iptables FORWARD policy is DROP (set by Docker) -- applying fix"
else
  echo "==> iptables FORWARD policy is not DROP -- applying rules anyway (harmless)"
fi

# 3. Insert ACCEPT rules into DOCKER-USER, idempotently (-C check before -I insert).
sudo "$IPT" -N DOCKER-USER 2>/dev/null || true   # Docker normally created it already
for br in $bridges; do
  for dir in -i -o; do
    sudo "$IPT" -C DOCKER-USER "$dir" "$br" -j ACCEPT 2>/dev/null \
      || sudo "$IPT" -I DOCKER-USER "$dir" "$br" -j ACCEPT
  done
done
echo "==> DOCKER-USER chain now:"
sudo "$IPT" -S DOCKER-USER | sed 's/^/    /'

# 4. Build the per-bridge ExecStart lines for the persistence unit.
execlines=""
for br in $bridges; do
  for dir in -i -o; do
    execlines+="ExecStart=/bin/sh -c '${IPT} -C DOCKER-USER ${dir} ${br} -j ACCEPT 2>/dev/null || ${IPT} -I DOCKER-USER ${dir} ${br} -j ACCEPT'"$'\n'
  done
done

# 5. Install + enable the systemd unit so the rules persist across reboots.
sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Persist LXD bridge ACCEPT rules in Docker's DOCKER-USER chain
Documentation=https://documentation.ubuntu.com/lxd/en/latest/howto/network_bridge_firewalld/
# Docker creates DOCKER-USER and sets FORWARD policy DROP at startup; run after
# it so the chain exists, then (re)insert our rules. Idempotent on every boot.
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-${IPT} -N DOCKER-USER
${execlines}
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now lxd-docker-forward.service
echo "==> Installed and enabled $UNIT"
echo "==> Done. Verify from inside a container, e.g.:"
echo "    $LXC launch ubuntu:24.04 nettest && $LXC exec nettest -- curl -4 -sI http://archive.ubuntu.com | head -1 && $LXC delete -f nettest"
