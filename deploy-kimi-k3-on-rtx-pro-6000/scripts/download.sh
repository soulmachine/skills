#!/usr/bin/env bash
# Sizing-gated GGUF quant download into the HF hub cache under $HF_HOME. Unlike kimi-k26's
# download.sh (whole-repo, whole-checkpoint-always-fits-in-VRAM), this fetches ONE quant
# subdirectory of a multi-quant repo (unsloth/Kimi-K3-GGUF ships ~9 of them) plus mmproj, and
# refuses BEFORE downloading if the quant won't fit this host's disk or combined VRAM+RAM — a
# multi-hundred-GB download failing that check after the fact wastes hours, not seconds.
# Also caches a second repo's small non-weight files only (tokenizer/config for the benchmark
# client — see REFERENCE.md "Tokenizer for benchmarking"), since the GGUF repo ships none.
#
#   bash download.sh unsloth/Kimi-K3-GGUF <commit-sha> UD-Q2_K_XL
#   TOKENIZER_REPO=moonshotai/Kimi-K3 TOKENIZER_REV=<sha> bash download.sh ...   # override tokenizer source/pin
set -uo pipefail
REPO="${1:?repo id, e.g. unsloth/Kimi-K3-GGUF}"
REV="${2:?full commit sha to pin (40 hex chars)}"
QUANT="${3:?quant subdirectory, e.g. UD-Q2_K_XL}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
REPO_DIR="$HF_HOME/hub/models--${REPO//\//--}"
DEST="$REPO_DIR/snapshots/$REV"
EXTRA_FILES="${EXTRA_FILES:-mmproj-BF16.gguf}"   # space-separated, relative to repo root

# List (path,size) for every file in $QUANT/ plus EXTRA_FILES, and the whole-repo tree once
# (stdlib-only; follows Link-header pagination — large repos paginate).
tree_list() {
  python3 - "$REPO" "$REV" "$QUANT" "$EXTRA_FILES" <<'PYEOF'
import sys, json, urllib.request
repo, rev, quant, extra = sys.argv[1:5]
url = f"https://huggingface.co/api/models/{repo}/tree/{rev}?recursive=true&expand=true"
wanted_prefix = quant + "/"
extra_set = set(extra.split())
files = {}
while url:
    req = urllib.request.Request(url, headers={"User-Agent": "kimi-k3-download/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        for e in json.load(r):
            if e.get("type") != "file":
                continue
            p = e["path"]
            if p.startswith(wanted_prefix) or p in extra_set:
                files[p] = (e.get("lfs") or {}).get("size") or e.get("size") or 0
        url = next((h[h.find("<")+1:h.find(">")] for h in (r.headers.get("Link") or "").split(",")
                    if 'rel="next"' in h), None)
if not files:
    sys.exit(f"ERROR: no files matched prefix '{wanted_prefix}' or extras {extra_set} in {repo}@{rev} "
              f"(check the quant name — it must match a top-level directory exactly)")
for p, s in sorted(files.items()):
    print(f"{p}\t{s}")
PYEOF
}

echo "== sizing gate: $REPO@$REV/$QUANT =="
MANIFEST="$(mktemp)"; trap 'rm -f "$MANIFEST"' EXIT
tree_list > "$MANIFEST" || exit 1
TOTAL_BYTES=$(awk -F'\t' '{s+=$2} END{print s+0}' "$MANIFEST")
TOTAL_GB=$(python3 -c "print(f'{$TOTAL_BYTES/1e9:.1f}')")
N_FILES=$(wc -l < "$MANIFEST")
echo "   $N_FILES files, ${TOTAL_GB} GB"

# Disk: compare against the HF_HOME filesystem's free space (not /, in case HF_HOME is a
# separate mount — the common case on these hosts, a big-NVMe data pool).
mkdir -p "$HF_HOME"
FREE_BYTES=$(df -B1 --output=avail "$HF_HOME" | tail -1 | tr -d ' ')
FREE_GB=$(python3 -c "print(f'{$FREE_BYTES/1e9:.1f}')")
if [ "$TOTAL_BYTES" -gt "$FREE_BYTES" ]; then
  echo "REFUSING: needs ${TOTAL_GB} GB, only ${FREE_GB} GB free at $HF_HOME" >&2
  exit 1
fi
echo "   disk OK: ${FREE_GB} GB free at $HF_HOME"

# VRAM+RAM: a hybrid deploy can run at any GPU/CPU split, but the model has to fit SOMEWHERE.
# Rough check only (ignores KV cache, activation overhead, OS/other-process headroom) — a
# WARNING, not a hard refusal, since the exact usable RAM depends on what else is running on
# the host at deploy time (see the parent skill's step 1 "check who else is using the GPUs").
if command -v nvidia-smi >/dev/null 2>&1; then
  VRAM_BYTES=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{s+=$1*1024*1024} END{print s+0}')
else
  VRAM_BYTES=0
fi
RAM_BYTES=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)
COMBINED_GB=$(python3 -c "print(f'{($VRAM_BYTES+$RAM_BYTES)/1e9:.0f}')")
if [ "$TOTAL_BYTES" -gt "$((VRAM_BYTES + RAM_BYTES))" ]; then
  echo "WARNING: ${TOTAL_GB} GB exceeds this host's combined VRAM+RAM (~${COMBINED_GB} GB) —" >&2
  echo "         it cannot fit at ANY --n-cpu-moe split. Downloading anyway; it will not serve." >&2
else
  echo "   VRAM+RAM OK: ~${COMBINED_GB} GB combined (exact usable headroom depends on what else is running)"
fi

echo "== downloading into HF hub cache: $DEST =="
mkdir -p "$DEST"
BASE="https://huggingface.co/$REPO/resolve/$REV"
awk -F'\t' '{print $1}' "$MANIFEST" | xargs -P 6 -I {} bash -c '
  f="$1"; out="'"$DEST"'/$f"; mkdir -p "$(dirname "$out")"
  [ -f "$out" ] && [ "$(stat -c%s "$out" 2>/dev/null)" -gt 0 ] && exit 0
  for t in 1 2 3 4 5; do curl -fSL --retry 5 --retry-all-errors -C - -o "$out" "'"$BASE"'/$f" && exit 0; sleep 5; done
  echo "FAIL $f"' _ {}

echo "== verifying sizes =="
MISS=0
while IFS=$'\t' read -r f want; do
  got=$(stat -c%s "$DEST/$f" 2>/dev/null || echo 0)
  [ "$got" -eq "$want" ] || { echo "  MISMATCH: $f (got $got, want $want)" >&2; MISS=$((MISS+1)); }
done < "$MANIFEST"
if [ "$MISS" -gt 0 ]; then
  echo "== INCOMPLETE ($MISS mismatched) — rerun this script to resume ==" >&2
  exit 1
fi
mkdir -p "$REPO_DIR/refs"; printf '%s' "$REV" > "$REPO_DIR/refs/main"
echo "== checkpoint ready: $DEST/$QUANT (refs/main -> $REV) =="

# Tokenizer for the benchmark client — separate repo, small files only (config/tokenizer, NOT
# the multi-hundred-GB safetensors). See REFERENCE.md "Tokenizer for benchmarking".
TOKENIZER_REPO="${TOKENIZER_REPO:-moonshotai/Kimi-K3}"
if [ -n "$TOKENIZER_REPO" ]; then
  echo "== fetching tokenizer-only files from $TOKENIZER_REPO =="
  TREV="${TOKENIZER_REV:-main}"
  TDIR="$HF_HOME/hub/models--${TOKENIZER_REPO//\//--}"
  python3 - "$TOKENIZER_REPO" "$TREV" "$TDIR" <<'PYEOF'
import sys, os, json, urllib.request
repo, rev, tdir = sys.argv[1:4]
url = f"https://huggingface.co/api/models/{repo}"
req = urllib.request.Request(url, headers={"User-Agent": "kimi-k3-download/1.0"})
with urllib.request.urlopen(req, timeout=60) as r:
    d = json.load(r)
rev_resolved = d.get("sha", rev)
skip_ext = (".safetensors", ".bin", ".gguf", ".pt", ".h5")
files = [s["rfilename"] for s in d.get("siblings", []) if not s["rfilename"].endswith(skip_ext)]
dest = os.path.join(tdir, "snapshots", rev_resolved)
os.makedirs(dest, exist_ok=True)
base = f"https://huggingface.co/{repo}/resolve/{rev_resolved}"
for f in files:
    out = os.path.join(dest, f)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out) and os.path.getsize(out) > 0:
        continue
    urllib.request.urlretrieve(f"{base}/{f}", out)
    print("  fetched", f)
refs = os.path.join(tdir, "refs")
os.makedirs(refs, exist_ok=True)
with open(os.path.join(refs, "main"), "w") as fh:
    fh.write(rev_resolved)
print(f"tokenizer cache ready: {dest} ({len(files)} files)")
PYEOF
fi
