#!/usr/bin/env bash
# Throughput sweep against the running SGLang container (sglang.bench_serving runs INSIDE the
# container via docker exec — no host Python). Compare against the baselines in REFERENCE.md
# (1024in/256out, out-tok/s @ c1/8/64/128: bf16 KV 59.7/206.7/388.7/329.9; fp8 KV .../613.3).
#   NAME=kimi-k26 LOG=./bench.log bash bench_sweep_sglang.sh
NAME="${NAME:-kimi-k26}"
LOG="${LOG:-./bench.log}"
SNAP=$(docker exec "$NAME" sh -c 'cat /models/repo/refs/main')
MODEL_PATH="${MODEL_PATH:-/models/repo/snapshots/$SNAP}"   # container-side path (tokenizer only)
: > "$LOG"
run() {
  local c=$1 np=$2 inlen=$3 outlen=$4
  echo "########## max_concurrency=$c num_prompts=$np in=$inlen out=$outlen" | tee -a "$LOG"
  docker exec -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 "$NAME" \
    python3 -m sglang.bench_serving \
    --backend sglang --host 127.0.0.1 --port 30000 \
    --model "$MODEL_PATH" \
    --dataset-name random-ids --num-prompts "$np" \
    --random-input-len "$inlen" --random-output-len "$outlen" --random-range-ratio 1.0 \
    --max-concurrency "$c" --disable-tqdm 2>&1 \
    | grep -E "Max request concurrency|Successful requests|Benchmark duration|Request throughput|token throughput|Mean TTFT|Median TTFT|Mean TPOT|Median ITL|^Concurrency" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
}
run 1   8   1024 256
run 8   32  1024 256
run 64  128 1024 256
run 128 192 1024 256
echo "SWEEP_DONE" | tee -a "$LOG"
