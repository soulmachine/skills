#!/usr/bin/env bash
# Launch Kimi-K3 (GGUF, CPU+GPU hybrid) via llama.cpp in Docker. Single script — unlike kimi-k26's
# per-engine scripts, there's only one engine here; BUILD_SOURCE picks the image (and whether
# --mmproj is wired in), QUANT picks the checkpoint.
#
#   QUANT=UD-Q2_K_XL BUILD_SOURCE=fork bash serve_docker.sh   # foreground; DETACH=1 to daemonize
#   N_CPU_MOE=20 bash serve_docker.sh                         # override the CPU/GPU expert split
#   BATCH=4096 UBATCH=4096 bash serve_docker.sh               # bigger ubatch: fewer CPU->GPU expert copies at prefill
#   EXTRA_ARGS="--no-op-offload" DOCKER_ENV="GGML_CUDA_DISABLE_GRAPHS=1" bash serve_docker.sh   # A/B knobs
#   GPU_ARGS="--device nvidia.com/gpu=4 --device nvidia.com/gpu=5 ..." bash serve_docker.sh  # GPU subset
# Prereq: docker + nvidia-container-toolkit with a CDI spec at /etc/cdi/nvidia.yaml; sanity:
#   docker run --rm --device nvidia.com/gpu=all --entrypoint nvidia-smi nvidia/cuda:13.0.1-base-ubuntu24.04
set -euo pipefail

QUANT="${QUANT:?set QUANT, e.g. UD-Q2_K_XL}"
BUILD_SOURCE="${BUILD_SOURCE:-fork}"
MODEL_REPO="${MODEL_REPO:-unsloth/Kimi-K3-GGUF}"
case "$BUILD_SOURCE" in
  fork)     IMAGE="${IMAGE:-$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^kimi-k3-llamacpp:fork-' | head -1)}" ;;
  mainline) IMAGE="${IMAGE:-$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^kimi-k3-llamacpp:mainline-' | head -1)}" ;;
  *) echo "Unknown BUILD_SOURCE='$BUILD_SOURCE' (use: fork | mainline)" >&2; exit 2 ;;
esac
[ -n "${IMAGE:-}" ] || { echo "No kimi-k3-llamacpp:${BUILD_SOURCE}-* image found — run: BUILD_SOURCE=$BUILD_SOURCE bash build_image.sh" >&2; exit 1; }
NAME="${NAME:-kimi-k3}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

KIMI_CACHE="$HF_HOME/hub/models--${MODEL_REPO//\//--}"
[ -f "$KIMI_CACHE/refs/main" ] || { echo "$MODEL_REPO not in HF cache ($KIMI_CACHE). Run: bash scripts/download.sh $MODEL_REPO <commit-sha> $QUANT" >&2; exit 1; }
SNAP="$KIMI_CACHE/snapshots/$(cat "$KIMI_CACHE/refs/main")"
QUANT_DIR="$SNAP/$QUANT"
[ -d "$QUANT_DIR" ] || { echo "quant '$QUANT' not found in snapshot ($QUANT_DIR) — check the QUANT name or re-run download.sh" >&2; exit 1; }
# GGUF split files: any shard's path works, llama.cpp reads split metadata and finds siblings
# in the same directory. Pick shard 1 (or the first shard glob matches) by convention.
FIRST_SHARD="$(find "$QUANT_DIR" -name '*-00001-of-*.gguf' -o -name '*.gguf' ! -name 'mmproj*' | sort | head -1)"
[ -n "$FIRST_SHARD" ] || { echo "no .gguf shard found in $QUANT_DIR" >&2; exit 1; }
MODEL_ARG="/models/repo/$(basename "$QUANT")/$(basename "$FIRST_SHARD")"

# Bind directly to this host's Tailscale IP — matches the settled "tailnet-direct, no Caddy"
# access decision more precisely than a generic -p (which also exposes on the Docker bridge/LAN
# via 0.0.0.0). Falls back to loopback-only if Tailscale isn't up, never a silent 0.0.0.0.
TS_IP="$(tailscale ip -4 2>/dev/null || true)"
HOST="${HOST:-${TS_IP:-127.0.0.1}}"
PORT="${PORT:-30000}"
MODEL_NAME="${MODEL_NAME:-kimi-k3}"

# Physical cores only, not SMT threads — AMX tile registers are shared per physical core, so
# hyperthread siblings contending for them doesn't add throughput (measured: this host is 2x32c/
# 64t Xeon 6730P = 64 physical, 128 with SMT). Override THREADS if the host differs.
PHYS_CORES="$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l || echo 64)"
THREADS="${THREADS:-$PHYS_CORES}"

EXTRA_FLAGS=()
if [ -n "${N_CPU_MOE:-}" ]; then
  # Manual override: pin exactly N layers' routed experts to CPU, everything else to GPU
  # (-ngl left unset/auto so the rest still places normally). Use this once bench_sweep.sh has
  # actually measured a value worth pinning — see REFERENCE.md "Tuning --n-cpu-moe."
  EXTRA_FLAGS+=(-ngl 999 --n-cpu-moe "$N_CPU_MOE")
else
  # Default: let llama.cpp's own --fit mechanism (on by default, this build) choose the GPU/CPU
  # split automatically from actual free VRAM across all attached devices — leave -ngl AND
  # --n-cpu-moe both unset so --fit controls both. This replaced an earlier hardcoded
  # "-ngl 999 --cpu-moe" (force everything, including every routed expert, onto CPU) default:
  # measured 2026-09-03, that config took over 20 minutes to answer a single 32-token request
  # and never finished — --fit auto instead lands a real GPU/CPU split from the first launch.
  :
fi
if [ "$BUILD_SOURCE" = "fork" ]; then
  MMPROJ="$SNAP/mmproj-BF16.gguf"
  [ -f "$MMPROJ" ] && EXTRA_FLAGS+=(--mmproj "/models/repo/mmproj-BF16.gguf") \
    || echo "WARN: mmproj-BF16.gguf not found at $MMPROJ — serving text-only despite BUILD_SOURCE=fork" >&2
fi
[ -n "${JINJA:-1}" ] && [ "${JINJA:-1}" != "0" ] && EXTRA_FLAGS+=(--jinja)   # needed for tool-call parsing

# --numa distribute: NOT a tuning knob here, a requirement. This quant (861GB) exceeds one NUMA
# socket's RAM share (this host: 1TiB / 2 sockets = 512GiB/socket) — weights must span both nodes.
# Expect real cross-socket (UPI) traffic as an unavoidable cost of a model this size, not a bug.
# Pair it with the host's /proc/sys/kernel/numa_balancing=0 (the kernel's automatic page migration
# fights --numa distribute's placement) — this script does NOT set that for you (host-wide sysctl,
# out of scope for a container launcher); see REFERENCE.md "NUMA" for the one-line prerequisite.
EXTRA_FLAGS+=(--numa distribute --threads "$THREADS" --threads-batch "$THREADS")
# --cache-type-k/v f16: NOT a tuning knob either. The quantized KV cache types (q4_0 family, block
# size 32) fail to load on Kimi-K3 — its hybrid KDA/MLA head dim is 74, which doesn't divide
# evenly into a 32-wide block. f16 (unquantized) is the only cache type confirmed to load; do not
# "optimize" this to a quantized type without re-verifying against the actual architecture first.
EXTRA_FLAGS+=(--cache-type-k f16 --cache-type-v f16)
# --load-mode none: the default 'auto' mmaps the model and pages CPU-resident expert tensors in
# lazily, on first access — measured 2026-09-03, this makes a cold first request stall for tens of
# minutes on page faults (worse: fighting numa_balancing above). 'none' reads everything upfront
# during load (slower load, ~proportional to file size / NVMe throughput) so serving is fast from
# the first request. Override LOAD_MODE if you deliberately want lazy mmap back.
EXTRA_FLAGS+=(--load-mode "${LOAD_MODE:-none}")
# ctx-size: default 0 = "loaded from model" — for Kimi-K3 that's the full 1M training context,
# times n_slots (parallel default), which is a huge KV cache commitment for a first real run.
# Explicit default here is deliberately modest; raise CTX_SIZE once you know what you need.
EXTRA_FLAGS+=(--ctx-size "${CTX_SIZE:-65536}" --parallel "${PARALLEL:-1}")
# --cache-ram: prompt cache size in MiB (llama.cpp default 8192; -1 unlimited, 0 disabled). A
# cache entry for this model is ~1363 MiB, so the 8 GiB default holds only ~6 of them — and
# --cache-idle-slots (default on) saves every idle slot into it, so at --parallel 32 the cache
# thrashes, each eviction copying 1.36 GB. Measured 2026-09-03 at c8/32 prompts:
#   default 8192 -> 7.84 out tok/s, TTFT 126.1 s, 317 evictions
#   CACHE_RAM=0  -> 9.07 out tok/s, TTFT  12.3 s,   0 evictions
# Keep the DEFAULT for serving: real traffic shares system prompts and multi-turn history, which
# is exactly what the cache accelerates. Set CACHE_RAM=0 for BENCHMARKING with random-ids
# prompts — they share no prefix, so the cache can never hit and its evictions are pure overhead
# that shows up as inflated TTFT.
if [ -n "${CACHE_RAM:-}" ]; then EXTRA_FLAGS+=(--cache-ram "$CACHE_RAM"); fi
# -b/-ub (BATCH/UBATCH): with experts on CPU, llama.cpp re-copies EVERY CPU-resident expert tensor
# to GPU0 for each micro-batch of >= 32 tokens (scheduler op-offload, no caching) — ~100 GiB per
# ubatch on this deployment. At the default -ub 512 a 1024-token prompt pays that twice, which is
# the measured 7.1 s c1 TTFT (RESEARCH-2026-09-04 §1). Larger ubatches amortise it (community
# guidance for CPU+GPU MoE: 4096). Costs compute-buffer VRAM on GPU0; --fit accounts for it.
[ -n "${BATCH:-}" ]  && EXTRA_FLAGS+=(--batch-size "$BATCH")
[ -n "${UBATCH:-}" ] && EXTRA_FLAGS+=(--ubatch-size "$UBATCH")
# EXTRA_ARGS: free-form extra llama-server flags, word-split (e.g. "--no-op-offload",
# "--spec-type ngram-mod", "--fit off --n-cpu-moe 12"). DOCKER_ENV: extra `docker run -e KEY=VAL`
# entries, space-separated (e.g. "GGML_CUDA_DISABLE_GRAPHS=1 GGML_SCHED_DEBUG=1").
DOCKER_ENV_ARGS=()
for kv in ${DOCKER_ENV:-}; do DOCKER_ENV_ARGS+=(-e "$kv"); done

# (no JIT cache to persist here, unlike kimi-k26's SGLang Marlin-repack cache — llama.cpp has none)
GPU_ARGS="${GPU_ARGS:---device nvidia.com/gpu=all}"
RUN_MODE=(--rm)
if [ "${DETACH:-0}" = "1" ]; then RUN_MODE=(-d --restart unless-stopped); fi

docker rm -f "$NAME" >/dev/null 2>&1 || true

# --ipc=host: llama.cpp's own multi-GPU worker IPC (much lighter than kimi-k26's NCCL/TP=8
# dependency — no all-reduce, just layer/tensor-split coordination). --network host (not a plain
# -p publish): matches the Tailscale-IP bind above — binding a specific address only works
# predictably from inside the container's own netns with the host's network stack, and this isn't
# NCCL/RDMA-sensitive traffic so there's no downside on this PCIe-only box.
# shellcheck disable=SC2086  # GPU_ARGS intentionally word-splits
exec docker run "${RUN_MODE[@]}" --name "$NAME" \
  $GPU_ARGS \
  "${DOCKER_ENV_ARGS[@]}" \
  --network host \
  --ipc=host \
  -v "$SNAP:/models/repo:ro" \
  "$IMAGE" \
  --model "$MODEL_ARG" \
  --alias "$MODEL_NAME" \
  --host "$HOST" --port "$PORT" \
  --split-mode layer \
  "${EXTRA_FLAGS[@]}" \
  ${EXTRA_ARGS:-}

# Cold load reads ~$TOTAL_GB from NVMe + places tensors — CPU-bound, can take a while at this
# size. Ready on "server is listening on http://...". Watch: docker logs -f "$NAME"
