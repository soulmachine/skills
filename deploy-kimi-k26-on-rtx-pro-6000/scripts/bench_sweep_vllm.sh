#!/usr/bin/env bash
# Same sweep as bench_sweep_sglang.sh, but against a vLLM server on :30000. The bench client
# (sglang.bench_serving) runs from the SGLang image in its own --network host container
# (CPU-only; the vLLM image ships no bench tool). --model = tokenizer path from the mounted
# repo; --served-model-name = the request model field.
#   LOG=./bench.log bash bench_sweep_vllm.sh
BENCH_IMG="${BENCH_IMG:-lmsysorg/sglang:v0.5.12.post1-cu130}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
KIMI_CACHE="$HF_HOME/hub/models--moonshotai--Kimi-K2.6"
SNAP=$(cat "$KIMI_CACHE/refs/main")
MODEL_PATH="/models/repo/snapshots/$SNAP"
LOG="${LOG:-./bench.log}"
: > "$LOG"
run() {
  local c=$1 np=$2 inlen=$3 outlen=$4
  echo "########## max_concurrency=$c num_prompts=$np in=$inlen out=$outlen" | tee -a "$LOG"
  docker run --rm --network host -v "$KIMI_CACHE:/models/repo:ro" \
    -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 --entrypoint python3 "$BENCH_IMG" \
    -m sglang.bench_serving --backend vllm --host 127.0.0.1 --port 30000 \
    --model "$MODEL_PATH" --served-model-name kimi-k2.6 \
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
