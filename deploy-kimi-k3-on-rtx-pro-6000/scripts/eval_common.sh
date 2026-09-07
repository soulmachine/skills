# Shared bits for the Kimi-K3 eval helpers (run_perplexity.sh, run_imatrix.sh) — `source` me.
# EVAL: working dir for corpora / logits / imatrix / logs (NOT under /data/devops — outputs are GBs).
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
MODEL_REPO="${MODEL_REPO:-unsloth/Kimi-K3-GGUF}"
KIMI_CACHE="$HF_HOME/hub/models--${MODEL_REPO//\//--}"
SNAP="$KIMI_CACHE/snapshots/$(cat "$KIMI_CACHE/refs/main")"
EVAL="${EVAL:-/data/kimi-k3-eval}"
# first shard of a quant dir; a single-file quant (e.g. a REAP slice) has no -00001-of- name
first_shard() { local f; f=$(find "$SNAP/$1" -name '*-00001-of-*.gguf' | head -1); [ -n "$f" ] || f=$(find "$SNAP/$1" -name '*.gguf' ! -name 'mmproj*' | sort | head -1); echo "$f"; }
PHYS_CORES="$(lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l)"
# Same placement/runtime flags serve_docker.sh uses, minus server-only ones. -b/-ub 4096 amortise the
# per-ubatch CPU->GPU expert copy in hybrid mode; for an ALL-GPU quant pass EXTRA="--batch-size 2048
# --ubatch-size 2048 --fit-target 6144" (measured 2026-09-05: -ub 4096 + the 1 GiB default fit margin
# OOMs in the CUDA scratch pool once every expert is GPU-resident).
COMMON_FLAGS=(--numa distribute --threads "$PHYS_CORES" --threads-batch "$PHYS_CORES"
              --cache-type-k f16 --cache-type-v f16 --load-mode none --split-mode layer
              --batch-size 4096 --ubatch-size 4096)
drun() { # drun <image> <entrypoint-binary> <args...>  — runs as the calling uid so outputs are writable
  local img="$1" bin="$2"; shift 2
  docker run --rm --name "kimi-k3-eval-$bin" --user "$(id -u):$(id -g)" --device nvidia.com/gpu=all --ipc=host \
    -v "$SNAP:/models/repo:ro" -v "$EVAL:/eval" --entrypoint "/usr/local/bin/$bin" "$img" "$@"
}
