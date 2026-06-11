#!/usr/bin/env bash
# Pre-warm (build + cache) the INT4 gptq_marlin_repack Marlin JIT kernel BEFORE the real launch.
# Builds in ~7s and validates BOTH that `ninja` is on PATH AND Fix 1 (rsqrt noexcept) — so a
# failure is INSTANT instead of crashing AFTER the ~15-min weight load. The real launch then
# reuses the cached kernel (~/.cache/tvm-ffi).
#   VENV=./.venv CUDA_HOME=/usr/local/cuda bash prewarm.sh
set -euo pipefail
VENV="${VENV:-./.venv}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
PY="$VENV/bin/python"
[ -x "$PY" ] || { echo "ERROR: no python at $PY (set VENV=...)" >&2; exit 1; }

# ninja (venv/bin) + nvcc (CUDA bin) must resolve for the JIT build
export PATH="$VENV/bin:$CUDA_HOME/bin:$PATH"
command -v ninja >/dev/null || { echo "ERROR: 'ninja' not on PATH — run: uv pip install --python $PY ninja" >&2; exit 1; }
echo "ninja : $(command -v ninja) ($(ninja --version))"
echo "nvcc  : $(command -v nvcc || echo MISSING)"

"$PY" - <<'PYEOF'
import time, sglang.jit_kernel.gptq_marlin_repack as m
t = time.time()
mod = m._jit_gptq_marlin_repack_module()
print(f"OK: gptq_marlin_repack JIT built/cached in {time.time()-t:.1f}s -> {mod}")
PYEOF
echo "== Pre-warm done. The real launch will reuse this cached kernel (no rebuild after weight load). =="
