#!/usr/bin/env bash
# Launch Kimi-K2.6 (INT4/Marlin, MLA, 256K, vision) on 8x RTX PRO 6000 Blackwell Server Edition
# with the OFFICIAL vLLM Docker image. No host CUDA toolkit or Python packages needed: the image
# ships precompiled sm_120 kernels — no host-side JIT, glibc, or toolchain concerns.
#
#   bash serve_docker_vllm.sh                # foreground (Ctrl-C stops + removes); checkpoint auto-resolved
#                                       # from $HF_HOME hub cache (default ~/.cache/huggingface)
#   MODEL_PATH=/path/to/ckpt bash serve_docker_vllm.sh                  # explicit checkpoint override
#   DETACH=1 bash serve_docker_vllm.sh                                  # -d --restart unless-stopped
#                                                                  # (then SKIP the systemd unit)
# Prereq: docker + nvidia-container-toolkit with a CDI spec at /etc/cdi/nvidia.yaml; sanity:
#   docker run --rm --device nvidia.com/gpu=all --entrypoint nvidia-smi "$IMAGE"
set -euo pipefail

IMAGE="${IMAGE:-vllm/vllm-openai:v0.22.1}"            # PIN a release tag (never :latest); bump deliberately
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
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.85}"
# GPU access: CDI by default (spec at /etc/cdi/nvidia.yaml via `nvidia-ctk cdi generate`, kept
# fresh by nvidia-cdi-refresh.*; plain runc, no legacy nvidia runtime hook — current best
# practice). Legacy runtime-hook alternative: GPU_ARGS="--gpus all"
GPU_ARGS="${GPU_ARGS:---device nvidia.com/gpu=all}"

RUN_MODE=(--rm)
if [ "${DETACH:-0}" = "1" ]; then RUN_MODE=(-d --restart unless-stopped); fi

# --ipc=host: NCCL shm for TP=8 (Docker's default 64MB /dev/shm breaks it; alt: --shm-size=32g)
# --network host: binds the host stack — loopback firewall + reverse proxy work exactly like native
# shellcheck disable=SC2086  # GPU_ARGS intentionally word-splits
exec docker run "${RUN_MODE[@]}" --name "$NAME" \
  $GPU_ARGS \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 --ulimit nofile=1048576 \
  "${MODEL_MOUNT[@]}" \
  -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
  "$IMAGE" \
  --model "$MODEL_ARG" \
  --served-model-name kimi-k2.6 \
  --trust-remote-code \
  --tensor-parallel-size "$TP" \
  --max-model-len 262144 \
  --gpu-memory-utilization "$GPU_MEM_UTIL" \
  --tool-call-parser kimi_k2 --enable-auto-tool-choice \
  --reasoning-parser kimi_k2 \
  --mm-encoder-tp-mode data \
  --host "$HOST" --port "$PORT"

# Weight load ~10-15 min from NVMe; ready on "Application startup complete".
# Watch: docker logs -f kimi-k26-int4
