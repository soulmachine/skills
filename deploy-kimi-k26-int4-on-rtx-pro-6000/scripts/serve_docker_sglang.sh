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

IMAGE="${IMAGE:-lmsysorg/sglang:v0.5.12.post1-cu130}"  # PIN a release tag (never :latest); bump deliberately
NAME="${NAME:-kimi-k26-int4}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
if [ -n "${MODEL_PATH:-}" ]; then
  # explicit checkpoint dir — must be self-contained (real files, not hub-cache symlinks)
  MODEL_MOUNT=(-v "$MODEL_PATH:/models/kimi:ro"); MODEL_ARG=/models/kimi
else
  # resolve from the HF hub cache; mount the whole repo dir so snapshot symlinks into ../../blobs resolve
  KIMI_CACHE="$HF_HOME/hub/models--moonshotai--Kimi-K2.6"
  [ -f "$KIMI_CACHE/refs/main" ] || { echo "Kimi-K2.6 not in HF cache ($KIMI_CACHE). Run: bash scripts/download.sh moonshotai/Kimi-K2.6 <commit-sha>" >&2; exit 1; }
  MODEL_MOUNT=(-v "$KIMI_CACHE:/models/repo:ro"); MODEL_ARG="/models/repo/snapshots/$(cat "$KIMI_CACHE/refs/main")"
fi
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-30000}"
TP="${TP:-8}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
# Persisted JIT cache: gptq_marlin_repack builds once (~7s), restarts reuse it
# (cwd-relative default — the systemd unit's WorkingDirectory anchors it; override via JIT_CACHE)
JIT_CACHE="${JIT_CACHE:-$PWD/tvm-ffi-cache}"
mkdir -p "$JIT_CACHE"
# GPU access: CDI by default (spec at /etc/cdi/nvidia.yaml, kept fresh by nvidia-cdi-refresh.*;
# plain runc, no legacy nvidia runtime hook). Legacy alternative: GPU_ARGS="--gpus all"
GPU_ARGS="${GPU_ARGS:---device nvidia.com/gpu=all}"

RUN_MODE=(--rm)
if [ "${DETACH:-0}" = "1" ]; then RUN_MODE=(-d --restart unless-stopped); fi

# --ipc=host: NCCL shm for TP=8 (Docker's default 64MB /dev/shm breaks it; alt: --shm-size=32g)
# --network host: binds the host stack — loopback firewall + reverse proxy work exactly like native
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
  --served-model-name kimi-k2.6 \
  --tp-size "$TP" \
  --trust-remote-code \
  --context-length 262144 \
  --tool-call-parser kimi_k2 \
  --reasoning-parser kimi_k2 \
  --mem-fraction-static "$MEM_FRACTION_STATIC" \
  --chunked-prefill-size 16384 \
  --host "$HOST" --port "$PORT"

# Weight load ~10-15 min from NVMe; ready on "The server is fired up and ready to roll!".
# Watch: docker logs -f kimi-k26-int4
# Tuning knobs (benchmark vs native baseline 59/210/390/330 out-tok/s @ c1/8/64/128):
#   MEM_FRACTION_STATIC=0.90, --kv-cache-dtype fp8_e4m3 (KV pool ~116K tokens at 0.85)
