#!/usr/bin/env bash
# Launch a throwaway LXD container and assert it sees EVERY host GPU via nvidia-smi.
# Exits 0 (PASS) only if container GPU count == host GPU count.
#
# Config via environment:
#   IMAGE   container image      (default: ubuntu:24.04)
#   NAME    container name       (default: lxd-gpu-verify)
#   KEEP    1 = don't delete the container afterwards (default: delete)
#
# Example:  bash verify-gpu.sh        |        KEEP=1 IMAGE=ubuntu:22.04 bash verify-gpu.sh
set -euo pipefail

IMAGE="${IMAGE:-ubuntu:24.04}"
NAME="${NAME:-lxd-gpu-verify}"

LXC=/snap/bin/lxc
[ -x "$LXC" ] || LXC="$(command -v lxc)" || { echo "ERROR: lxc not found"; exit 1; }
# use sudo only if the current user can't reach the LXD socket (lxd group not active yet)
SUDO=""; "$LXC" list >/dev/null 2>&1 || SUDO="sudo"
run(){ $SUDO "$LXC" "$@"; }

host_gpus=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ') || true
[ "${host_gpus:-0}" -gt 0 ] || { echo "ERROR: host nvidia-smi lists 0 GPUs"; exit 1; }
echo "host GPUs: $host_gpus"

cleanup(){ [ "${KEEP:-0}" = 1 ] || run delete -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

run info "$NAME" >/dev/null 2>&1 && run delete -f "$NAME" >/dev/null 2>&1 || true
echo "launching $NAME ($IMAGE) ..."
run launch "$IMAGE" "$NAME" >/dev/null
for _ in $(seq 1 30); do run exec "$NAME" -- true 2>/dev/null && break; sleep 1; done

cont_gpus=$(run exec "$NAME" -- nvidia-smi -L 2>/dev/null | grep -c '^GPU ') || true
echo "container GPUs: ${cont_gpus:-0}"
run exec "$NAME" -- nvidia-smi -L 2>/dev/null || true

if [ "${cont_gpus:-0}" = "$host_gpus" ]; then
  echo "PASS: container sees all $host_gpus GPU(s)"
else
  echo "FAIL: container sees ${cont_gpus:-0}/$host_gpus GPU(s)"
  echo "  diagnose: $SUDO $LXC info --show-log $NAME | grep -iE 'nvidia|driver rpc|hook'"
  echo "  (if you see 'driver rpc error: timed out', a legacy nvidia.runtime device is set — use CDI; see REFERENCE §4)"
  exit 1
fi
