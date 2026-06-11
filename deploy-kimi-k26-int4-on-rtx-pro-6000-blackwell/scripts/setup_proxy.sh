#!/usr/bin/env bash
# Phase-5: put Caddy in front of the SGLang server with a real Tailscale (Let's Encrypt) TLS cert
# + Bearer API-key auth, and lock the upstream :30000 to loopback. Idempotent. Run as a sudoer.
#
#   bash setup_proxy.sh                                  # auto-detect MagicDNS name + port 30000
#   DOMAIN=host.tailnet.ts.net UPSTREAM_PORT=30000 bash setup_proxy.sh
#
# Prereq: enable "HTTPS Certificates" in the Tailscale admin console (https://login.tailscale.com/admin/dns).
# NB: Tailscale already encrypts transit (WireGuard); this TLS is app-layer for https:// clients.
set -euo pipefail

UPSTREAM_PORT="${UPSTREAM_PORT:-30000}"
DOMAIN="${DOMAIN:-$(tailscale status --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')}"
[ -n "$DOMAIN" ] || { echo "ERROR: could not determine Tailscale DNS name; set DOMAIN=" >&2; exit 1; }
echo "domain=$DOMAIN  upstream=127.0.0.1:$UPSTREAM_PORT"

# 0) require Tailscale HTTPS certs to be enabled
if ! tailscale status --json | python3 -c 'import sys,json;sys.exit(0 if (json.load(sys.stdin).get("CertDomains") or []) else 1)'; then
  echo "ERROR: Tailscale HTTPS certs not enabled. Enable 'HTTPS Certificates' at" >&2
  echo "       https://login.tailscale.com/admin/dns , then re-run." >&2
  exit 1
fi

# 1) install caddy
command -v caddy >/dev/null || { sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y caddy; }

# 2) API key (generate once; keep existing)
sudo mkdir -p /etc/caddy/certs
if [ ! -f /etc/caddy/kimi.env ]; then
  KEY=$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(32))')
  printf 'KIMI_API_KEY=%s\n' "$KEY" | sudo tee /etc/caddy/kimi.env >/dev/null
fi
sudo chown root:caddy /etc/caddy/kimi.env; sudo chmod 640 /etc/caddy/kimi.env

# 3) issue/refresh the Tailscale cert
sudo tailscale cert --cert-file /etc/caddy/certs/srv.crt --key-file /etc/caddy/certs/srv.key "$DOMAIN"
sudo chown root:caddy /etc/caddy/certs/srv.crt /etc/caddy/certs/srv.key; sudo chmod 640 /etc/caddy/certs/srv.crt /etc/caddy/certs/srv.key
sudo chown root:caddy /etc/caddy/certs; sudo chmod 750 /etc/caddy/certs

# 4) Caddyfile: TLS + bearer gate (everything incl. /health) -> upstream
sudo tee /etc/caddy/Caddyfile >/dev/null <<EOF
{
    admin off
}

${DOMAIN}:443 {
    tls /etc/caddy/certs/srv.crt /etc/caddy/certs/srv.key
    @noauth not header Authorization "Bearer {\$KIMI_API_KEY}"
    route {
        respond @noauth "Unauthorized" 401
        reverse_proxy 127.0.0.1:${UPSTREAM_PORT}
    }
}
EOF

# 5) expose KIMI_API_KEY to the caddy process
sudo mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=/etc/caddy/kimi.env\n' | sudo tee /etc/systemd/system/caddy.service.d/override.conf >/dev/null

# 6) firewall: lock upstream to loopback (IPv4; server binds 0.0.0.0). INPUT chain, Docker-safe.
sudo tee /usr/local/sbin/kimi-fw.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
iptables -C INPUT -p tcp --dport ${UPSTREAM_PORT} -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport ${UPSTREAM_PORT} -i lo -j ACCEPT
iptables -C INPUT -p tcp --dport ${UPSTREAM_PORT} -j DROP 2>/dev/null || iptables -I INPUT 2 -p tcp --dport ${UPSTREAM_PORT} -j DROP
EOF
sudo chmod 755 /usr/local/sbin/kimi-fw.sh
sudo tee /etc/systemd/system/kimi-fw.service >/dev/null <<EOF
[Unit]
Description=Lock SGLang upstream :${UPSTREAM_PORT} to loopback only
After=network-online.target tailscaled.service docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kimi-fw.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

# 7) weekly cert renewal (~90-day cert)
sudo tee /usr/local/sbin/kimi-cert-renew.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
tailscale cert --cert-file /etc/caddy/certs/srv.crt --key-file /etc/caddy/certs/srv.key ${DOMAIN}
chown root:caddy /etc/caddy/certs/srv.crt /etc/caddy/certs/srv.key
chmod 640 /etc/caddy/certs/srv.crt /etc/caddy/certs/srv.key
systemctl reload caddy
EOF
sudo chmod 755 /usr/local/sbin/kimi-cert-renew.sh
sudo tee /etc/systemd/system/kimi-cert-renew.service >/dev/null <<EOF
[Unit]
Description=Renew Tailscale TLS cert for the Caddy proxy
After=network-online.target tailscaled.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kimi-cert-renew.sh
EOF
sudo tee /etc/systemd/system/kimi-cert-renew.timer >/dev/null <<EOF
[Unit]
Description=Weekly Tailscale cert renewal for the Caddy proxy
[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
EOF

# 8) enable + (re)start
sudo systemctl daemon-reload
sudo systemctl enable --now kimi-fw.service kimi-cert-renew.timer
sudo bash -c 'set -a; . /etc/caddy/kimi.env; caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile'
sudo systemctl restart caddy
sleep 2

# 9) verify
KEY=$(sudo sed -n 's/^KIMI_API_KEY=//p' /etc/caddy/kimi.env)
echo "== no key  -> expect 401 =="; curl -sS --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/health"   -o /dev/null -w '  HTTP %{http_code}\n'
echo "== with key-> expect 200 =="; curl -sS --resolve "$DOMAIN:443:127.0.0.1" -H "Authorization: Bearer $KEY" "https://$DOMAIN/v1/models" -o /dev/null -w '  HTTP %{http_code}\n'
echo
echo "Done.  Base URL: https://$DOMAIN/v1   (header: Authorization: Bearer \$KIMI_API_KEY)"
echo "Key file: /etc/caddy/kimi.env   |   rotate: edit it + 'sudo systemctl restart caddy'"
