#!/usr/bin/env bash
# Perplexity / KL-divergence gate for a Kimi-K3 GGUF quant, run inside a kimi-k3-llamacpp image.
#   MODE=base IMAGE=<img> QUANT=UD-Q2_K_XL  bash run_perplexity.sh   # saves reference logits -> logits/<TAG>.kld
#   MODE=test IMAGE=<img> QUANT=UD-IQ2_XXS  bash run_perplexity.sh   # PPL + KLD vs the saved reference
# Knobs: CTX (default 2048), CHUNKS (default 16 -> 32K tokens), TEXT (default wiki.test.raw), TAG (ref name),
#        EXTRA (extra flags, e.g. "--fit off -ngl 999 --n-cpu-moe 16").
set -euo pipefail
. "$(dirname "$0")/eval_common.sh"
MODE="${MODE:?base|test}"; IMAGE="${IMAGE:?}"; QUANT="${QUANT:?}"
CTX="${CTX:-2048}"; CHUNKS="${CHUNKS:-16}"; TEXT="${TEXT:-wiki.test.raw}"; TAG="${TAG:-ref-q2kxl-c${CTX}x${CHUNKS}}"
MODEL="/models/repo/$QUANT/$(basename "$(first_shard "$QUANT")")"
LOG="$EVAL/ppl-${MODE}-${QUANT}-c${CTX}x${CHUNKS}-$(date -u +%Y%m%dT%H%M%SZ).log"
echo ">> $MODE $QUANT ctx=$CTX chunks=$CHUNKS text=$TEXT image=$IMAGE -> $LOG"
case "$MODE" in
  base) KLD=(--kl-divergence-base "/eval/logits/$TAG.kld") ;;
  test) KLD=(--kl-divergence-base "/eval/logits/$TAG.kld" --kl-divergence) ;;
esac
drun "$IMAGE" llama-perplexity -m "$MODEL" -f "/eval/$TEXT" -c "$CTX" --chunks "$CHUNKS" \
  "${COMMON_FLAGS[@]}" "${KLD[@]}" ${EXTRA:-} 2>&1 | tee "$LOG" | grep -E --line-buffered \
  'estimate|Final|KL|Top|PPL|error|Error|GGML_ASSERT|nan|load time|CPU model buffer|CUDA0 model buffer|n_cpu_moe|fit:' 
echo ">> done: $LOG"
