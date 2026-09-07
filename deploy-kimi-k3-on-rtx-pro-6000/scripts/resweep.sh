#!/usr/bin/env bash
# Re-sweep the two configurations whose curves were missing/stale: REAP-770 all-GPU (fit 4096, 8 slots)
# and the hybrid Q2_K_XL with -ub 4096 (16 slots). Same grid as every Kimi-K3 sweep: 1024in/256out,
# PROMPTS_PER=4, --cache-ram 0, CONC 1 4 8 16 32. Marker: RESWEEP_DONE. Log: $EVAL/resweep.log
set -uo pipefail
EVAL=/data/kimi-k3-eval; SNAP=/data/huggingface/hub/models--unsloth--Kimi-K3-GGUF/snapshots/a0836360ce58dfec088d966a97f2ddc8a606279b
IMG=kimi-k3-llamacpp:fork-883f2c9ba78f-lip-rsrb; B=/home/nickel/.agents/skills/llm-inference-benchmark/scripts/bench_sweep.sh
COMMON="--alias kimi-k3 --host 100.68.217.84 --port 30001 --split-mode layer --jinja --numa distribute --threads 64 --threads-batch 64 --cache-type-k f16 --cache-type-v f16 --load-mode none --ctx-size 65536 --mmproj /models/repo/mmproj-BF16.gguf --cache-ram 0"
one() { # label model parallel extra
  local label=$1 model=$2 par=$3 extra=$4 log=/data/devops/kimi-k3/bench.log.$1
  [ -f "$log" ] && grep -q SWEEP_DONE "$log" && { echo "$(date -u +%FT%TZ) skip $label"; return; }
  docker rm -f kimi-k3-sweep >/dev/null 2>&1
  echo "$(date -u +%FT%TZ) start server $label"
  docker run -d --rm --name kimi-k3-sweep --device nvidia.com/gpu=all --ipc=host --network host -v "$SNAP:/models/repo:ro" \
    --entrypoint /usr/local/bin/llama-server "$IMG" --model "$model" $COMMON --parallel "$par" $extra >/dev/null
  for i in $(seq 1 240); do docker logs kimi-k3-sweep 2>&1 | grep -q 'listening on http' && break; docker ps --format '{{.Names}}' | grep -q '^kimi-k3-sweep$' || { echo "SERVER DIED $label"; docker logs kimi-k3-sweep 2>&1 | tail -3; return; }; sleep 10; done
  docker logs kimi-k3-sweep 2>&1 | grep -q 'listening on http' || { echo "SERVER TIMEOUT $label"; docker rm -f kimi-k3-sweep >/dev/null 2>&1; return; }
  echo "$(date -u +%FT%TZ) GPU MiB: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | paste -sd+ | bc) total"
  echo "$(date -u +%FT%TZ) sweep $label"
  rm -f "$log"; (cd "$(dirname "$B")" && HF_HOME=/data/huggingface TARGET_HOST=100.68.217.84 PORT=30001 MODEL_NAME=kimi-k3 MODEL_REPO=moonshotai/Kimi-K3 CONC="1 4 8 16 32" PROMPTS_PER=4 IN=1024 OUT=256 LOG="$log" bash "$B" >/dev/null 2>&1)
  grep -E '^##########|Output token throughput|Mean TTFT|Mean TPOT' "$log" | cut -c1-80; chmod 444 "$log"
  echo "$(date -u +%FT%TZ) done $label"; docker rm -f kimi-k3-sweep >/dev/null 2>&1; sleep 15
}
one q2kxl-reap770-allvram-p8-fit4096-ub2048-cacheram0-0906 /models/repo/UD-Q2_K_XL-REAP770/Kimi-K3-UD-Q2_K_XL-REAP770.gguf 8  "--batch-size 2048 --ubatch-size 2048 --fit-target 4096"
one q2kxl-hybrid-p16-ub4096-cacheram0-0906                  /models/repo/UD-Q2_K_XL/Kimi-K3-UD-Q2_K_XL-00001-of-00019.gguf 16 "--batch-size 4096 --ubatch-size 4096"
echo "$(date -u +%FT%TZ) RESWEEP_DONE"
