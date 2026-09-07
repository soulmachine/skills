#!/usr/bin/env bash
# Collect per-(layer,expert) routing counts + activation energy with llama-imatrix (GGUF output).
#   IMAGE=<img> QUANT=UD-IQ2_XXS bash run_imatrix.sh          # -> imatrix-<QUANT>.gguf
# Knobs: TEXT (default calib.txt), CTX (2048), CHUNKS (all), EXTRA.
set -euo pipefail
. "$(dirname "$0")/eval_common.sh"
IMAGE="${IMAGE:?}"; QUANT="${QUANT:?}"; TEXT="${TEXT:-calib.txt}"; CTX="${CTX:-2048}"
MODEL="/models/repo/$QUANT/$(basename "$(first_shard "$QUANT")")"
OUT="imatrix-${QUANT}.gguf"; LOG="$EVAL/imatrix-${QUANT}-$(date -u +%Y%m%dT%H%M%SZ).log"
CH=(); [ -n "${CHUNKS:-}" ] && CH=(--chunks "$CHUNKS")
echo ">> imatrix $QUANT text=$TEXT ctx=$CTX -> $EVAL/$OUT ($LOG)"
drun "$IMAGE" llama-imatrix -m "$MODEL" -f "/eval/$TEXT" -o "/eval/$OUT" --output-format gguf -c "$CTX" "${CH[@]}" \
  "${COMMON_FLAGS[@]}" ${EXTRA:-} 2>&1 | tee "$LOG" | grep -E --line-buffered 'save|chunk|error|Error|GGML_ASSERT|nan|load time|\[[0-9]+\]' | tail -c 4000
echo ">> done: $EVAL/$OUT"
