#!/usr/bin/env bash
# Phase-5: put Caddy in front of the model server (engine-agnostic) with a real Tailscale (Let's Encrypt) TLS cert
# + Bearer API-key auth, and lock the upstream :30000 to loopback. Idempotent. Run as a sudoer.
#
#   bash setup_proxy.sh                                  # auto-detect MagicDNS name + port 30000
#   DOMAIN=host.tailnet.ts.net UPSTREAM_PORT=30000 bash setup_proxy.sh
#
# Prereq: enable "HTTPS Certificates" in the Tailscale admin console (https://login.tailscale.com/admin/dns).
# NB: Tailscale already encrypts transit (WireGuard); this TLS is app-layer for https:// clients.
# No Tailscale? The cert steps here are Tailscale-specific — use a public DNS name and Caddy's
# built-in ACME instead (drop the tls line + cert-renew units); bearer gate + firewall carry over.
set -euo pipefail

UPSTREAM_PORT="${UPSTREAM_PORT:-30000}"
# The model server runs --network host bound to the LAN IP (not loopback), so Caddy's upstream is the
# LAN IP. Auto-detect the default-route source; override with UPSTREAM_HOST=<ip>.
UPSTREAM_HOST="${UPSTREAM_HOST:-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo 127.0.0.1)}"
DOMAIN="${DOMAIN:-$(tailscale status --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')}"
[ -n "$DOMAIN" ] || { echo "ERROR: could not determine Tailscale DNS name; set DOMAIN=" >&2; exit 1; }
echo "domain=$DOMAIN  upstream=$UPSTREAM_HOST:$UPSTREAM_PORT"

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
        reverse_proxy ${UPSTREAM_HOST}:${UPSTREAM_PORT}
    }
}
EOF

# 5) expose KIMI_API_KEY to the caddy process
sudo mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=/etc/caddy/kimi.env\n' | sudo tee /etc/systemd/system/caddy.service.d/override.conf >/dev/null

# 6) access policy for :${UPSTREAM_PORT} is STRUCTURAL — NO host firewall.
#    The serve scripts run the container WITHOUT --network host and publish the port only to
#    127.0.0.1 (Caddy/verify) + the host LAN IP (-p 127.0.0.1:PORT:PORT -p <LAN_IP>:PORT:PORT).
#    The tailnet IP is never published, so raw :${UPSTREAM_PORT} simply has no listener there
#    (connection refused) — the tailnet must use the authenticated Caddy :443. LAN clients hit the
#    LAN-IP listener directly (unauthenticated, trusted LAN). Nothing to install here.
#    Retire any legacy host firewall (the old kimi-fw loopback-lock or the kimi-netguard INPUT
#    allowlist) so it can't interfere with the published-port path (its catch-all DROP blocks
#    container-side bench traffic; see REFERENCE 'Access model').
for legacy in kimi-fw kimi-netguard; do
  if [ -e "/etc/systemd/system/${legacy}.service" ] || [ -e "/usr/local/sbin/${legacy}.sh" ]; then
    sudo systemctl disable --now "${legacy}.service" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${legacy}.service" "/usr/local/sbin/${legacy}.sh"
  fi
done
for r in "-i tailscale0 -p tcp --dport ${UPSTREAM_PORT} -j DROP" \
         "-i lo -p tcp --dport ${UPSTREAM_PORT} -j ACCEPT" \
         "-p tcp --dport ${UPSTREAM_PORT} -j DROP"; do
  while sudo iptables -D INPUT $r 2>/dev/null; do :; done   # delete all copies (idempotent)
done
sudo systemctl daemon-reload

# 7) weekly cert renewal (~90-day cert)
sudo tee /usr/local/sbin/kimi-cert-renew.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
tailscale cert --cert-file /etc/caddy/certs/srv.crt --key-file /etc/caddy/certs/srv.key ${DOMAIN}
chown root:caddy /etc/caddy/certs/srv.crt /etc/caddy/certs/srv.key
chmod 640 /etc/caddy/certs/srv.crt /etc/caddy/certs/srv.key
# the Caddyfile sets `admin off`, so `systemctl reload` (admin-API hot reload) fails — restart instead
systemctl try-reload-or-restart caddy || systemctl restart caddy
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
sudo systemctl enable --now kimi-cert-renew.timer
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
