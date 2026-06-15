#!/usr/bin/env bash
# Launch Kimi-K2.6 (MLA, 256K, vision) on 8x RTX PRO 6000 Blackwell Server Edition with vLLM in Docker.
# QUANT=int4 (default) = official compressed-tensors INT4 QAT -> Marlin, stock vllm/vllm-openai image,
#   precompiled sm_120 kernels (no host JIT/glibc/toolchain concern).
# QUANT=nvfp4 = nvidia/Kimi-K2.6-NVFP4 (ModelOpt FP4); needs the patched CUDA-13 image from
#   build_nvfp4_image.sh and the offline remote-code de-symlink (prep_remote_code.sh). vLLM only —
#   SGLang NVFP4 produces NaN on sm_120.
#
#   bash serve_docker_vllm.sh                # foreground (Ctrl-C stops + removes); checkpoint auto-resolved
#                                       # from $HF_HOME hub cache (default ~/.cache/huggingface)
#   MODEL_PATH=/path/to/ckpt bash serve_docker_vllm.sh                  # explicit checkpoint override
#   DETACH=1 bash serve_docker_vllm.sh                                  # -d --restart unless-stopped
#                                                                  # (then SKIP the systemd unit)
# Prereq: docker + nvidia-container-toolkit with a CDI spec at /etc/cdi/nvidia.yaml; sanity:
#   docker run --rm --device nvidia.com/gpu=all --entrypoint nvidia-smi "$IMAGE"
set -euo pipefail

# QUANT selects the checkpoint + quant flags (int4 = official QAT default; nvfp4 = ModelOpt FP4).
QUANT="${QUANT:-int4}"
case "$QUANT" in
  int4)
    MODEL_REPO="${MODEL_REPO:-moonshotai/Kimi-K2.6}"
    # stock image; compressed-tensors INT4 auto-detects -> Marlin MoE (NO --quantization flag).
    IMAGE="${IMAGE:-vllm/vllm-openai:v0.22.1}"
    QUANT_FLAGS=() ;;
  nvfp4)
    MODEL_REPO="${MODEL_REPO:-nvidia/Kimi-K2.6-NVFP4}"
    # NVFP4 on sm_120 needs a CUDA-13 vLLM image WITH the TRITON_MLA smem patch (graph-capture OOMs
    # otherwise) — build it: bash scripts/build_nvfp4_image.sh  -> kimi-k26-nvfp4-vllm:cu130-mla.
    # --moe-backend marlin is the throughput pick on sm_120 (A/B: ~12% > native flashinfer_b12x,
    # which is comm-bound here); set MOE_BACKEND=flashinfer_b12x for the native FP4 tensor-core path.
    IMAGE="${IMAGE:-kimi-k26-nvfp4-vllm:cu130-mla}"
    QUANT_FLAGS=(--quantization modelopt_fp4 --disable-custom-all-reduce
                 --moe-backend "${MOE_BACKEND:-marlin}")
    : "${KV_CACHE_DTYPE:=fp8}"   # checkpoint ships FP8 KV scales
    : "${GPU_MEM_UTIL:=0.90}" ;;
  *) echo "Unknown QUANT='$QUANT' (use: int4 | nvfp4)" >&2; exit 2 ;;
esac
# Native FP4 MoE (flashinfer_b12x / cutedsl) wants this enabler env alongside --moe-backend (proven
# config); marlin ignores it (the explicit --moe-backend still forces the choice), so it's a no-op there.
QUANT_ENV=()
case "${MOE_BACKEND:-}" in flashinfer*) QUANT_ENV=(-e VLLM_USE_FLASHINFER_MOE_FP4=1) ;; esac
# (each QUANT branch above pins a default IMAGE; override with IMAGE=… but never :latest.)
NAME="${NAME:-kimi-k26}"                              # static singleton name (one model fills the 8-GPU pool);
                                                      # the active variant shows in the image tag + the env file
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
# Bind address: 0.0.0.0 (all interfaces) under --network host — the fleet access model. The raw port
# answers on loopback, LAN, and tailnet; the auth boundary is Caddy :443 (off-box) + the router (no
# public IP), NOT the bind. Caddy upstreams over LOOPBACK (127.0.0.1, DHCP-proof — see setup_proxy.sh),
# and LAN peers may hit <lan-ip>:PORT directly for cross-host benchmarking. For a locked-down posture
# (only the Caddy proxy reaches the model), set HOST=127.0.0.1. See REFERENCE 'Access model'.
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-30000}"
TP="${TP:-8}"
# NB: vLLM's gpu-memory-utilization caps the TOTAL footprint (weights+activations+KV) — NOT
# equivalent to SGLang's mem-fraction-static (weights+KV pool, transients outside). On 8x96GB,
# weights+overhead ≈ 0.845 of VRAM, so 0.85 leaves ~0.5GB KV (won't start). 0.95 is the working
# default. Full 256K context needs fp8 KV (KV_CACHE_DTYPE=fp8) — bf16 KV at 256K needs >100% VRAM.
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.95}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"
MODEL_NAME="${MODEL_NAME:-kimi-k2.6}"   # the OpenAI `model` id clients must send; keep stable for your fleet
EXTRA_FLAGS=()
[ -n "${KV_CACHE_DTYPE:-}" ] && EXTRA_FLAGS+=(--kv-cache-dtype "$KV_CACHE_DTYPE")
[ -n "${MAX_SEQS:-}" ]       && EXTRA_FLAGS+=(--max-num-seqs "$MAX_SEQS")   # cap concurrent seqs (KV-bound)
# GPU access: CDI by default (spec at /etc/cdi/nvidia.yaml via `nvidia-ctk cdi generate`, kept
# fresh by nvidia-cdi-refresh.*; plain runc, no legacy nvidia runtime hook — current best
# practice). Legacy runtime-hook alternative: GPU_ARGS="--gpus all"
GPU_ARGS="${GPU_ARGS:---device nvidia.com/gpu=all}"


RUN_MODE=(--rm)
if [ "${DETACH:-0}" = "1" ]; then RUN_MODE=(-d --restart unless-stopped); fi

# Pre-launch cutover guard: drop any namesake container, then WAIT for the GPU pool to actually free.
# A prior ~595 GB instance's teardown is NOT instant — launching while a GPU is still held OOMs the
# workers at executor init, and a failed init can LEAK GPU memory that perpetuates a crash-loop (seen
# in practice: a swap done ~5 s after stopping the old service left 45 GB stuck on GPU 0). On a
# dedicated inference box this wait is safe; set WAIT_GPU_FREE=0 if you share the GPUs.
docker rm -f "$NAME" >/dev/null 2>&1 || true
if [ "${WAIT_GPU_FREE:-1}" = "1" ] && command -v nvidia-smi >/dev/null 2>&1; then
  for _ in $(seq 1 60); do                       # up to ~120 s
    busy=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '($1+0)>2000{n++} END{print n+0}')
    [ "${busy:-0}" -eq 0 ] && break
    echo ">> cutover: waiting for $busy GPU(s) to release before launch…"; sleep 2
  done
  [ "${busy:-0}" -ne 0 ] && echo ">> WARN: $busy GPU(s) still busy — launch may OOM; a crashed run may have leaked it (REFERENCE: 'cutover / leaked GPU memory')." >&2
fi

# --ipc=host: NCCL shm for TP=8 (Docker's default 64MB /dev/shm breaks it; alt: --shm-size=32g).
# --network host: performance — NCCL's GPU-to-GPU transport. IB/RoCE GPUDirect RDMA needs the host
#   network stack + direct access to the RDMA NICs, which a Docker bridge breaks/bypasses (and any
#   multi-node TP needs it too). The server binds $HOST (0.0.0.0, above) on the host net stack; off-box
#   auth is Caddy :443 (which upstreams over loopback), not a firewall. (Bench runs isolated.)
# shellcheck disable=SC2086  # GPU_ARGS intentionally word-splits
exec docker run "${RUN_MODE[@]}" --name "$NAME" \
  $GPU_ARGS \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 --ulimit nofile=1048576 \
  "${MODEL_MOUNT[@]}" \
  -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
  -e VLLM_WORKER_MULTIPROC_METHOD=spawn -e NCCL_CUMEM_ENABLE=0 \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  "${QUANT_ENV[@]}" \
  "$IMAGE" \
  --model "$MODEL_ARG" \
  --served-model-name "$MODEL_NAME" \
  --trust-remote-code \
  "${QUANT_FLAGS[@]}" \
  --tensor-parallel-size "$TP" \
  --max-model-len "$MAX_MODEL_LEN" \
  --gpu-memory-utilization "$GPU_MEM_UTIL" \
  --tool-call-parser kimi_k2 --enable-auto-tool-choice \
  --reasoning-parser kimi_k2 \
  --mm-encoder-tp-mode data \
  "${EXTRA_FLAGS[@]}" \
  --host "$HOST" --port "$PORT"

# Weight load ~10-15 min from NVMe; ready on "Application startup complete".
# Watch: docker logs -f "$NAME"   (default container name: kimi-k26)
