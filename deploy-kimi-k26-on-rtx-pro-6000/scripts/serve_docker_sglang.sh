#!/usr/bin/env bash
# Launch Kimi-K2.6 (INT4/Marlin, MLA, 256K, vision) on 8x RTX PRO 6000 Blackwell Server Edition
# with the OFFICIAL SGLang Docker image — SGLang engine, Docker-first deployment. No host Python
# or CUDA toolkit needed; the image ships its own toolchain (the gptq_marlin_repack JIT builds
# in-container into the bind-mounted cache, so the glibc>=2.41 rsqrt host fix does not apply).
#
#   bash serve_docker_sglang.sh         # foreground (Ctrl-C stops + removes); checkpoint auto-resolved
#                                       # from $HF_HOME hub cache (default ~/.cache/huggingface)
#   MODEL_PATH=/path/to/ckpt bash serve_docker_sglang.sh           # explicit checkpoint override
#   DETACH=1 bash serve_docker_sglang.sh                           # -d --restart unless-stopped
#                                                                  # (then SKIP the systemd unit)
# Prereq: docker + nvidia-container-toolkit with a CDI spec at /etc/cdi/nvidia.yaml; sanity:
#   docker run --rm --device nvidia.com/gpu=all --entrypoint nvidia-smi "$IMAGE"
set -euo pipefail

# QUANT: int4 (official QAT) is the only SGLang-supported quant on sm_120. NVFP4 on SGLang produces
# NaN on sm_120 (sgl-project #18954, flashinfer #2577) — refuse it and point at the vLLM path.
QUANT="${QUANT:-int4}"
if [ "$QUANT" = "nvfp4" ]; then
  echo "NVFP4 on SGLang is broken on sm_120 (NaN; sgl #18954). Use vLLM: QUANT=nvfp4 bash serve_docker_vllm.sh" >&2
  exit 2
fi
[ "$QUANT" = "int4" ] || { echo "Unknown QUANT='$QUANT' (SGLang supports: int4)" >&2; exit 2; }
MODEL_REPO="${MODEL_REPO:-moonshotai/Kimi-K2.6}"
IMAGE="${IMAGE:-lmsysorg/sglang:v0.5.12.post1-cu130}"  # PIN a release tag (never :latest); bump deliberately
NAME="${NAME:-kimi-k26}"                               # static singleton name (one model fills the 8-GPU pool)
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
if [ -n "${MODEL_PATH:-}" ]; then
  # explicit checkpoint dir — must be self-contained (real files, not hub-cache symlinks)
  MODEL_MOUNT=(-v "$MODEL_PATH:/models/kimi:ro"); MODEL_ARG=/models/kimi
else
  # resolve from the HF hub cache; mount the whole repo dir so snapshot symlinks into ../../blobs resolve
  KIMI_CACHE="$HF_HOME/hub/models--${MODEL_REPO//\//--}"
  [ -f "$KIMI_CACHE/refs/main" ] || { echo "$MODEL_REPO not in HF cache ($KIMI_CACHE). Run: bash scripts/download.sh $MODEL_REPO <commit-sha>" >&2; exit 1; }
  MODEL_MOUNT=(-v "$KIMI_CACHE:/models/repo:ro"); MODEL_ARG="/models/repo/snapshots/$(cat "$KIMI_CACHE/refs/main")"
fi
# Bind address: the LAN IP only (NOT 0.0.0.0) — under --network host this is the structural access
# policy: the raw port listens on the trusted LAN but has NO listener on the tailnet IP or loopback
# (connection refused), so the tailnet must go through the authenticated Caddy :443. Fail-safe to
# loopback if the LAN IP can't be detected (secure + visibly broken; never silently 0.0.0.0).
# Override with HOST=<ip>. Caddy and verify.sh therefore target this LAN IP, not 127.0.0.1.
LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
HOST="${HOST:-${LAN_IP:-127.0.0.1}}"
PORT="${PORT:-30000}"
TP="${TP:-8}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
MODEL_NAME="${MODEL_NAME:-kimi-k2.6}"   # OpenAI `model` id clients must send; keep stable for your fleet
# Optional: KV_CACHE_DTYPE=fp8_e4m3 halves KV bytes/token (~2x pool). Affects numerics — re-verify.
EXTRA_FLAGS=()
[ -n "${KV_CACHE_DTYPE:-}" ] && EXTRA_FLAGS+=(--kv-cache-dtype "$KV_CACHE_DTYPE")
# Persisted JIT cache: gptq_marlin_repack builds once (~7s), restarts reuse it
# (cwd-relative default — the systemd unit's WorkingDirectory anchors it; override via JIT_CACHE)
JIT_CACHE="${JIT_CACHE:-$PWD/tvm-ffi-cache}"
mkdir -p "$JIT_CACHE"
# GPU access: CDI by default (spec at /etc/cdi/nvidia.yaml, kept fresh by nvidia-cdi-refresh.*;
# plain runc, no legacy nvidia runtime hook). Legacy alternative: GPU_ARGS="--gpus all"
GPU_ARGS="${GPU_ARGS:---device nvidia.com/gpu=all}"


RUN_MODE=(--rm)
if [ "${DETACH:-0}" = "1" ]; then RUN_MODE=(-d --restart unless-stopped); fi

# Pre-launch cutover guard: drop any namesake container, then WAIT for the GPU pool to actually free
# (a prior ~595 GB instance's teardown isn't instant; launching too early OOMs the workers at init, and
# a failed init can LEAK GPU memory into a crash-loop). Dedicated box → safe; WAIT_GPU_FREE=0 to skip.
docker rm -f "$NAME" >/dev/null 2>&1 || true
if [ "${WAIT_GPU_FREE:-1}" = "1" ] && command -v nvidia-smi >/dev/null 2>&1; then
  for _ in $(seq 1 60); do                       # up to ~120 s
    busy=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '($1+0)>2000{n++} END{print n+0}')
    [ "${busy:-0}" -eq 0 ] && break
    echo ">> cutover: waiting for $busy GPU(s) to release before launch…"; sleep 2
  done
  [ "${busy:-0}" -ne 0 ] && echo ">> WARN: $busy GPU(s) still busy — launch may OOM (REFERENCE: 'cutover / leaked GPU memory')." >&2
fi

# --ipc=host: NCCL shm for TP=8 (Docker's default 64MB /dev/shm breaks it; alt: --shm-size=32g).
# --network host: performance — NCCL's GPU-to-GPU transport. IB/RoCE GPUDirect RDMA needs the host
#   network stack + direct access to the RDMA NICs, which a Docker bridge breaks/bypasses (and any
#   multi-node TP needs it too). The server binds $HOST (the LAN IP, above), so the tailnet/loopback
#   have no raw listener — that's the structural access policy, no host firewall. (Bench runs isolated.)
# FLASHINFER_USE_CUDA_NORM=1: belt-and-suspenders vs the CuTe-DSL RMSNorm MLIR ICE on sm_120
# shellcheck disable=SC2086  # GPU_ARGS intentionally word-splits
exec docker run "${RUN_MODE[@]}" --name "$NAME" \
  $GPU_ARGS \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 --ulimit nofile=1048576 \
  "${MODEL_MOUNT[@]}" \
  -v "$JIT_CACHE:/root/.cache/tvm-ffi" \
  -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
  -e OMP_NUM_THREADS=8 -e FLASHINFER_USE_CUDA_NORM=1 \
  "$IMAGE" \
  python3 -m sglang.launch_server \
  --model-path "$MODEL_ARG" \
  --served-model-name "$MODEL_NAME" \
  --tp-size "$TP" \
  --trust-remote-code \
  --context-length 262144 \
  --tool-call-parser kimi_k2 \
  --reasoning-parser kimi_k2 \
  --mem-fraction-static "$MEM_FRACTION_STATIC" \
  --chunked-prefill-size 16384 \
  "${EXTRA_FLAGS[@]}" \
  --host "$HOST" --port "$PORT"

# Weight load ~10-15 min from NVMe; ready on "The server is fired up and ready to roll!".
# Watch: docker logs -f "$NAME"   (default container name: kimi-k26)
# Measured 2026-06-11 (1024in/256out, out-tok/s @ c1/8/64/128):
#   bf16 KV (default):        59.7/206.7/388.7/329.9, KV pool 116K tokens
#   KV_CACHE_DTYPE=fp8_e4m3:  59.4/208.2/398.5/613.3, KV pool 232K (verify 5/5 incl. vision)
# Do NOT set MEM_FRACTION_STATIC=0.90: <1GB transient headroom -> OOM kills the server
# (vision tower allocates outside the pool; even text @ c8 needed 804MB transient).
