#!/usr/bin/env bash
# Robust checkpoint download. Tries `hf download`; if the Xet client stalls, finish missing
# files directly with parallel curl (resumable). Verifies file count/sizes against the HF API.
#   bash download.sh moonshotai/Kimi-K2.6 <commit-sha> /data/models/Kimi-K2.6 [VENV]
set -uo pipefail
REPO="${1:?repo id, e.g. moonshotai/Kimi-K2.6}"
REV="${2:?commit sha to pin}"
DEST="${3:?local dir}"
PY="${4:-./.venv}/bin/python"; [ -x "$PY" ] || PY=python3

mkdir -p "$DEST"
echo "== attempt 1: hf download (Xet disabled for stability) =="
HF_HUB_DISABLE_XET=1 timeout 1800 hf download "$REPO" --revision "$REV" --local-dir "$DEST" || \
  echo "  hf download interrupted/stalled — falling back to parallel curl"

echo "== compute missing files vs HF API =="
"$PY" - "$REPO" "$REV" "$DEST" <<'PYEOF' > /tmp/missing.txt
import sys, os
from huggingface_hub import HfApi
repo, rev, dest = sys.argv[1:4]
api = HfApi(); files = api.list_repo_files(repo, revision=rev)
size = {i.path:(i.size or (i.lfs.size if i.lfs else 0)) for i in api.get_paths_info(repo, paths=files, revision=rev)}
miss = [f for f in files if not (os.path.exists(os.path.join(dest,f)) and abs(os.path.getsize(os.path.join(dest,f))-size[f])<=1)]
sys.stderr.write(f"repo files={len(files)} missing={len(miss)} total={sum(size.values())/1e9:.1f}GB\n")
print("\n".join(miss))
PYEOF
N=$(grep -c . /tmp/missing.txt || true)
if [ "${N:-0}" -gt 0 ]; then
  echo "== parallel curl for $N missing files =="
  BASE="https://huggingface.co/$REPO/resolve/$REV"
  xargs -P 6 -I {} bash -c '
    f="$1"; out="'"$DEST"'/$f"; mkdir -p "$(dirname "$out")"
    for t in 1 2 3 4 5; do curl -fSL --retry 5 --retry-all-errors -C - -o "$out" "'"$BASE"'/$f" && exit 0; sleep 5; done
    echo "FAIL $f"' _ {} < /tmp/missing.txt
fi

echo "== final integrity check =="
"$PY" - "$REPO" "$REV" "$DEST" <<'PYEOF'
import sys, os
from huggingface_hub import HfApi
repo, rev, dest = sys.argv[1:4]
api = HfApi(); files = api.list_repo_files(repo, revision=rev)
size = {i.path:(i.size or (i.lfs.size if i.lfs else 0)) for i in api.get_paths_info(repo, paths=files, revision=rev)}
bad = [f for f in files if not (os.path.exists(os.path.join(dest,f)) and abs(os.path.getsize(os.path.join(dest,f))-size[f])<=1)]
print("OK: all", len(files), "files present" if not bad else f"MISSING/BAD: {bad}")
PYEOF
