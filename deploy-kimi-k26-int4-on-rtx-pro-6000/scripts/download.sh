#!/usr/bin/env bash
# Robust checkpoint download into the HF hub cache under $HF_HOME (default ~/.cache/huggingface).
# Tries `hf download` if available; if the Xet client stalls (or hf is absent), fetches missing
# files directly with parallel curl (resumable). Verifies file count/sizes against the HF tree API
# (paginated — large repos return >1 page), then writes refs/main -> <commit-sha> so the serve
# scripts can resolve the snapshot. Needs only curl + python3 stdlib — no host pip packages.
#   bash download.sh moonshotai/Kimi-K2.6 <commit-sha>
set -uo pipefail
REPO="${1:?repo id, e.g. moonshotai/Kimi-K2.6}"
REV="${2:?full commit sha to pin (40 hex chars)}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
REPO_DIR="$HF_HOME/hub/models--${REPO//\//--}"
DEST="$REPO_DIR/snapshots/$REV"

# Compare the local snapshot against the HF tree API (stdlib-only; follows Link-header pagination).
#   mode=list   -> print missing/size-mismatched paths to stdout
#   mode=verify -> exit 1 if anything is missing
tree_check() {
  python3 - "$REPO" "$REV" "$DEST" "$1" <<'PYEOF'
import sys, os, json, urllib.request
repo, rev, dest, mode = sys.argv[1:5]
url = f"https://huggingface.co/api/models/{repo}/tree/{rev}?recursive=true&expand=true"
files = {}
while url:
    req = urllib.request.Request(url, headers={"User-Agent": "kimi-download/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        for e in json.load(r):
            if e.get("type") == "file":
                files[e["path"]] = (e.get("lfs") or {}).get("size") or e.get("size") or 0
        url = next((p[p.find("<")+1:p.find(">")] for p in (r.headers.get("Link") or "").split(",")
                    if 'rel="next"' in p), None)
if not files:
    sys.exit(f"ERROR: tree API returned no files for {repo}@{rev}")
miss = [f for f, s in files.items()
        if not (os.path.exists(os.path.join(dest, f)) and abs(os.path.getsize(os.path.join(dest, f)) - s) <= 1)]
sys.stderr.write(f"repo files={len(files)} missing={len(miss)} total={sum(files.values())/1e9:.1f}GB\n")
if mode == "list":
    print("\n".join(miss))
else:
    print(f"OK: all {len(files)} files present" if not miss else f"MISSING/BAD ({len(miss)}): {miss[:5]}...")
    sys.exit(1 if miss else 0)
PYEOF
}

mkdir -p "$DEST"
echo "== downloading into HF hub cache: $DEST =="
if command -v hf >/dev/null; then
  echo "== attempt 1: hf download (Xet disabled for stability) =="
  HF_HUB_DISABLE_XET=1 timeout 1800 hf download "$REPO" --revision "$REV" || \
    echo "  hf download interrupted/stalled — falling back to parallel curl"
else
  echo "== hf CLI not found — using parallel curl directly =="
fi

echo "== compute missing files vs HF tree API =="
tree_check list > /tmp/missing.txt || exit 1
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
if tree_check verify; then
  mkdir -p "$REPO_DIR/refs"
  printf '%s' "$REV" > "$REPO_DIR/refs/main"
  echo "== checkpoint ready: $DEST (refs/main -> $REV) =="
else
  echo "== INCOMPLETE — rerun this script to resume ==" >&2
  exit 1
fi
