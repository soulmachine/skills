#!/usr/bin/env bash
# Decide whether a vLLM run used a NATIVE FP4 MoE backend or fell back to Marlin/emulation,
# by reading its startup log. Pass a log file, or a running container name (default kimi-k26).
#
#   ./assert-native.sh kimi-k26            # the running prod container
#   ./assert-native.sh /path/to/serve.log  # or a captured startup log
#
# Exit 0 = native FP4; 1 = marlin/emulation fallback; 2 = unknown (no selection line yet).
set -uo pipefail
SRC="${1:-kimi-k26}"
if [ -f "$SRC" ]; then LOG="$(cat "$SRC")"; else LOG="$(docker logs "$SRC" 2>&1 || true)"; fi

# Authoritative line from vllm .../fused_moe/oracle/nvfp4.py:
#   Using '<backend>' NvFp4 MoE backend out of potential backends: [...]
sel="$(echo "$LOG" | grep -oiE "Using '[a-z0-9_]+' NvFp4 MoE backend" | tail -1)"
chosen="$(echo "$sel" | grep -oiE "'[a-z0-9_]+'" | tr -d "'")"

echo "===== backend selection ====="
echo "$LOG" | grep -iE "Using '[a-z0-9_]+' NvFp4 MoE backend|does not support the deployment configuration|does not have native support for FP4" | sort -u | head -20

echo "===== broken-kernel / autotuner warnings ====="
echo "$LOG" | grep -iE "Failed to initialize cutlass|TMA WS grouped|Skipping tactic|invalid PTX|CUDA error|illegal memory|DSLRuntimeError|ICE" | sort -u | head -10

echo "----------------------------------------"
echo "chosen backend: ${chosen:-<none found>}"
case "$(echo "$chosen" | tr 'A-Z' 'a-z')" in
  flashinfer_cutedsl*|flashinfer_b12x|flashinfer_trtllm|flashinfer_cutlass|cutlass|vllm_cutlass)
      echo "VERDICT: NATIVE FP4 ($chosen)"; exit 0 ;;
  marlin|emulation)
      echo "VERDICT: FALLBACK ($chosen)"; exit 1 ;;
  *)  echo "VERDICT: UNKNOWN — server may still be loading; coherence test is the tie-breaker"; exit 2 ;;
esac
