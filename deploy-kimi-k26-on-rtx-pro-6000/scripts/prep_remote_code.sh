#!/usr/bin/env bash
# Offline trust_remote_code fix — required for NVFP4 (the CUDA-13 image ships transformers >=5.10).
# With HF_HUB_OFFLINE=1, vLLM passes the snapshot DIR path; transformers >=5.10
# dynamic_module_utils does Path(module_file).resolve(), following the snapshot symlink INTO blobs/
# (hash-named), then resolves the custom module's relative imports (e.g. tokenization_kimi.py ->
# `from .tool_declaration_ts import ...`) as siblings in blobs/ — which don't exist by name:
#   FileNotFoundError: .../blobs/tool_declaration_ts.py   (dies before any GPU work).
# Fix: de-reference the small *.py files in the snapshot into real files (weights stay symlinked, no
# copy, stays inside $HF_HOME). Idempotent. Run as the CACHE OWNER, not root/systemd (root would
# chown the cache files). Re-run after any fresh `download.sh` (it re-creates the symlinks).
#
#   bash prep_remote_code.sh nvidia/Kimi-K2.6-NVFP4
set -euo pipefail
REPO="${1:?repo id, e.g. nvidia/Kimi-K2.6-NVFP4}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
D="$HF_HOME/hub/models--${REPO//\//--}"
[ -f "$D/refs/main" ] || { echo "no HF cache for $REPO at $D — run download.sh first" >&2; exit 1; }
SNAP="$D/snapshots/$(cat "$D/refs/main")"
[ -d "$SNAP" ] || { echo "snapshot dir missing: $SNAP" >&2; exit 1; }

shopt -s nullglob
n=0; skip=0
for f in "$SNAP"/*.py; do
  if [ -L "$f" ]; then
    real="$(readlink -f "$f")"; [ -f "$real" ] || { echo "missing blob for $(basename "$f")" >&2; exit 1; }
    cp --remove-destination "$real" "$f"; n=$((n+1))
  else
    skip=$((skip+1))
  fi
done
echo "de-symlinked $n .py file(s) in $SNAP ($skip already real). Weights remain symlinked."
