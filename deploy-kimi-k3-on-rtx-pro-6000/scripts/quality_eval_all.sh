#!/usr/bin/env bash
# Sequential big quality eval over the three Kimi-K3 quants: for each, start the server (docker, tailnet
# bind, port 30001), wait until it listens, run quality_eval.py, stop it. Resumable: quants whose
# results-<label>-big.json exists are skipped. Log: $EVAL/quality/big-run.log ; marker: BIG_RUN_DONE.
set -uo pipefail
EVAL=/data/kimi-k3-eval; Q=$EVAL/quality; SNAP=/data/huggingface/hub/models--unsloth--Kimi-K3-GGUF/snapshots/a0836360ce58dfec088d966a97f2ddc8a606279b
IMG=kimi-k3-llamacpp:fork-883f2c9ba78f-lip-rsrb
GSM=${GSM:-200}; HE=${HE:-164}; MBPP=${MBPP:-200}; MAXTOK=${MAXTOK:-4096}
COMMON="--alias kimi-k3 --host 100.68.217.84 --port 30001 --split-mode layer --jinja --numa distribute --threads 64 --threads-batch 64 --cache-type-k f16 --cache-type-v f16 --load-mode none --ctx-size 65536"
run_one() { # label model-path parallel conc extra-flags
  local label=$1 model=$2 par=$3 conc=$4 extra=$5
  [ -f "$Q/results-$label.json" ] && { echo "$(date -u +%FT%TZ) skip $label (results exist)"; return; }
  docker rm -f kimi-k3-eval >/dev/null 2>&1
  echo "$(date -u +%FT%TZ) start server $label"
  docker run -d --rm --name kimi-k3-eval --device nvidia.com/gpu=all --ipc=host --network host -v "$SNAP:/models/repo:ro" \
    --entrypoint /usr/local/bin/llama-server "$IMG" --model "$model" $COMMON --parallel "$par" $extra >/dev/null
  for i in $(seq 1 240); do
    docker logs kimi-k3-eval 2>&1 | grep -q 'listening on http' && break
    docker ps --format '{{.Names}}' | grep -q '^kimi-k3-eval$' || { echo "$(date -u +%FT%TZ) SERVER DIED for $label"; docker logs kimi-k3-eval 2>&1 | tail -5; return; }
    sleep 10
  done
  docker logs kimi-k3-eval 2>&1 | grep -q 'listening on http' || { echo "$(date -u +%FT%TZ) SERVER TIMEOUT for $label"; docker rm -f kimi-k3-eval >/dev/null 2>&1; return; }
  echo "$(date -u +%FT%TZ) eval $label (gsm8k $GSM, humaneval $HE, mbpp $MBPP, c$conc, max_tokens $MAXTOK)"
  "$EVAL/venv/bin/python" -u "$EVAL/scripts/quality_eval.py" run --label "$label" --host 100.68.217.84 --port 30001 \
      --gsm8k "$GSM" --humaneval "$HE" --mbpp "$MBPP" --concurrency "$conc" --max-tokens "$MAXTOK" --timeout 10800
  echo "$(date -u +%FT%TZ) done $label"
  docker rm -f kimi-k3-eval >/dev/null 2>&1; sleep 15
}
run_one iq2xxs-big  /models/repo/UD-IQ2_XXS/Kimi-K3-UD-IQ2_XXS-00001-of-00016.gguf              8  8  "--batch-size 2048 --ubatch-size 2048 --fit-target 6144"
run_one reap770-big /models/repo/UD-Q2_K_XL-REAP770/Kimi-K3-UD-Q2_K_XL-REAP770.gguf              8  8  "--batch-size 2048 --ubatch-size 2048 --fit-target 4096"
run_one q2kxl-hybrid-big /models/repo/UD-Q2_K_XL/Kimi-K3-UD-Q2_K_XL-00001-of-00019.gguf         8  8  "--batch-size 4096 --ubatch-size 4096"
echo "$(date -u +%FT%TZ) BIG_RUN_DONE"
