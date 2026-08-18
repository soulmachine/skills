#!/usr/bin/env bash
#
# cua-mcp-wrapper.sh — stdio MCP transport to cua-driver inside a lume VM.
#
# cua's docs bake the VM's IP into the MCP registration, but a NAT guest's IP
# drifts across reboots and the MCP server then fails silently. This wrapper
# re-resolves the IP at connect time instead.
#
# Install one per VM; the VM name is taken from the installed filename:
#   install -m 755 cua-mcp-wrapper.sh ~/.local/bin/cua-<vm>-mcp
#   claude mcp add --scope user cua-driver-vm -- ~/.local/bin/cua-<vm>-mcp
#
# Overrides: CUA_VM (else derived from the filename), CUA_VM_USER,
#            CUA_VM_DRIVER, LUME_BIN, JQ_BIN.
#
# Requires SSH key auth into the guest — BatchMode=yes disables password prompts,
# because a prompt on stdin would corrupt the JSON-RPC stream. provision.sh
# installs your public key; otherwise append it to the guest's authorized_keys.
#
# STDOUT IS THE JSON-RPC CHANNEL. Every diagnostic must go to stderr, or the
# transport breaks in ways that surface as an unhelpful client-side error.
#
set -euo pipefail

self="$(basename "$0")"
derived="${self#cua-}"
derived="${derived%-mcp}"

VM="${CUA_VM:-$derived}"
VM_USER="${CUA_VM_USER:-lume}"
VM_DRIVER="${CUA_VM_DRIVER:-/Users/lume/.local/bin/cua-driver}"

# An MCP client spawns this with a MINIMAL PATH — often without ~/.local/bin or
# /opt/homebrew/bin — so bare `lume`/`jq` are not resolvable. Take an explicit
# override first, then PATH, then the usual install locations.
resolve_bin() {
  _name="$1"; _override="$2"
  if [ -n "$_override" ]; then printf '%s' "$_override"; return; fi
  _p="$(command -v "$_name" 2>/dev/null || true)"
  if [ -n "$_p" ]; then printf '%s' "$_p"; return; fi
  for _c in "$HOME/.local/bin/$_name" "/opt/homebrew/bin/$_name" "/usr/local/bin/$_name"; do
    [ -x "$_c" ] && { printf '%s' "$_c"; return; }
  done
}

LUME="$(resolve_bin lume "${LUME_BIN:-}")"
JQ="$(resolve_bin jq "${JQ_BIN:-}")"
[ -x "$LUME" ] || { echo "cua-mcp: lume not found (set LUME_BIN)" >&2; exit 1; }
[ -x "$JQ" ]   || { echo "cua-mcp: jq not found (set JQ_BIN)" >&2; exit 1; }

# lume prints non-JSON when the VM is stopped or unknown, so jq must be allowed
# to fail quietly — otherwise pipefail kills us before the message below.
VM_IP="$("$LUME" get "$VM" --format json 2>/dev/null | "$JQ" -r '.[0].ipAddress // empty' 2>/dev/null || true)"

if [ -z "$VM_IP" ] || [ "$VM_IP" = "null" ]; then
  echo "cua-mcp: VM '$VM' has no IP — is it running? Try: lume run $VM" >&2
  exit 1
fi

# Host-key checking is off deliberately: a rebuilt guest reusing a NAT IP
# otherwise trips REMOTE HOST IDENTIFICATION HAS CHANGED and breaks the
# transport with no visible error. Sound only for a local NAT-only sandbox —
# never a pattern for anything routable.
exec ssh -T \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o ConnectTimeout=10 \
  -o ServerAliveInterval=30 \
  "${VM_USER}@${VM_IP}" \
  "$VM_DRIVER" mcp
