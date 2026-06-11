#!/usr/bin/env bash
# Apply the two REQUIRED sm_120 / Ubuntu (glibc>=2.41) fixes for serving Kimi-K2.6 with SGLang.
# Idempotent; backs up each file to *.orig.bak. Re-run fix 2 after any flashinfer reinstall.
#
#   VENV=./.venv CUDA_HOME=/usr/local/cuda bash apply_sm120_fixes.sh
set -euo pipefail

VENV="${VENV:-./.venv}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
PY="$VENV/bin/python"

[ -x "$PY" ] || { echo "ERROR: no python at $PY (set VENV=...)" >&2; exit 1; }

echo "== Fix 1: CUDA math_functions.h rsqrt/rsqrtf noexcept (glibc>=2.41 vs CUDA device decls) =="
HDR="$CUDA_HOME/targets/x86_64-linux/include/crt/math_functions.h"
[ -f "$HDR" ] || HDR="$(dirname "$(readlink -f "$CUDA_HOME/bin/nvcc")")/../targets/x86_64-linux/include/crt/math_functions.h"
if [ ! -f "$HDR" ]; then echo "  ! math_functions.h not found under $CUDA_HOME — skipping (set CUDA_HOME)"; else
  if grep -qE 'rsqrt\(double x\) noexcept' "$HDR"; then
    echo "  already patched: $HDR"
  else
    sudo cp -n "$HDR" "$HDR.orig.bak" 2>/dev/null || true
    sudo sed -i -E 's/(double[[:space:]]+rsqrt\(double x\));/\1 noexcept(true);/' "$HDR"
    sudo sed -i -E 's/(float[[:space:]]+rsqrtf\(float x\));/\1 noexcept(true);/' "$HDR"
    grep -qE 'rsqrt\(double x\) noexcept' "$HDR" \
      && echo "  patched: $HDR (backup *.orig.bak)" \
      || { echo "  ! sed did not match — patch math_functions.h manually (add 'noexcept(true)' to rsqrt/rsqrtf decls)"; }
  fi
fi

echo "== Fix 2: flashinfer RMSNorm -> CUDA norm by default (avoids CuTe-DSL MLIR ICE) =="
NORM="$("$PY" - <<'PYEOF'
import os, flashinfer.norm as n
print(os.path.abspath(n.__file__))
PYEOF
)"
if grep -q 'FLASHINFER_USE_CUDA_NORM", "1"' "$NORM"; then
  echo "  already patched: $NORM"
else
  cp -n "$NORM" "$NORM.orig.bak" 2>/dev/null || true
  sed -i 's@get("FLASHINFER_USE_CUDA_NORM", "0") == "1"@get("FLASHINFER_USE_CUDA_NORM", "1") != "0"@' "$NORM"
  echo "  patched: $NORM (backup *.orig.bak)"
fi
echo "  verify:"; "$PY" -c "import flashinfer.norm as n; assert n._USE_CUDA_NORM, 'still False'; print('   _USE_CUDA_NORM =', n._USE_CUDA_NORM)"

echo "== Done. Both fixes applied. =="
