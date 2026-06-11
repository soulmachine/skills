#!/usr/bin/env bash
# Launch Kimi-K2.6 (INT4/Marlin, MLA, 256K) on 8x RTX PRO 6000 Blackwell via SGLang in a uv venv.
#   VENV=./.venv MODEL_PATH=/data/models/Kimi-K2.6 PORT=30000 bash serve.sh
# Run detached:  setsid nohup bash serve.sh > server.log 2>&1 < /dev/null &
set -euo pipefail

VENV="${VENV:-./.venv}"
MODEL_PATH="${MODEL_PATH:-/data/models/Kimi-K2.6}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-30000}"

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
# Belt-and-suspenders for the flashinfer norm fix (the source patch is the real fix; see apply_sm120_fixes.sh).
export FLASHINFER_USE_CUDA_NORM="${FLASHINFER_USE_CUDA_NORM:-1}"

exec "$VENV/bin/python" -m sglang.launch_server \
  --model-path "$MODEL_PATH" \
  --served-model-name kimi-k2.6 \
  --tp-size 8 \
  --trust-remote-code \
  --context-length 262144 \
  --tool-call-parser kimi_k2 \
  --reasoning-parser kimi_k2 \
  --mem-fraction-static "${MEM_FRACTION_STATIC:-0.85}" \
  --chunked-prefill-size 16384 \
  --host "$HOST" --port "$PORT"

# Phase-4 knobs (benchmark each vs TP=8 baseline): --enable-dp-attention,
#   --kv-cache-dtype fp8_e4m3 (grows KV ~2x for longer context), --max-running-requests N,
#   raise --mem-fraction-static to 0.90. sm_120 attention fallback: --attention-backend triton.
