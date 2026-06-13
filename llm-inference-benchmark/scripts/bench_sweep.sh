#!/usr/bin/env bash
# Throughput sweep against the model server on :PORT, using sglang.bench_serving (the standard bench
# tool) purely as an HTTP load generator. It's ENGINE-AGNOSTIC: it always hits the OpenAI-compatible
# /v1/completions endpoint (via --backend sglang-oai, which is the identical code path to the `vllm`
# backend), so it doesn't care whether the server is SGLang or vLLM — both expose /v1/completions.
# The client runs in its own standalone SGLang-image container in its OWN net namespace (the vLLM
# image ships no bench tool; the client is just a load generator hitting the server's published
# TARGET_HOST:PORT — so it works local (host LAN IP) or cross-host (peer LAN IP), fully isolated).
#
#   bash bench_sweep.sh                                                  # conc {1,8,16,32,64,128}
#   MODEL_REPO=nvidia/Kimi-K2.6-NVFP4 CONC="1 8 16 64 128" SERVER_NAME=kimi-k26 \
#     LOG=./bench.log bash bench_sweep.sh
#
# --model = tokenizer path (mounted :ro from the host HF cache for MODEL_REPO; random-ids needs the
# vocab size). --served-model-name = the request `model` field; MUST match the server's served name.
# SERVER_NAME (optional) = the server container, to stamp its launch flags + KV pool into the header.
set -uo pipefail

BENCH_IMG="${BENCH_IMG:-lmsysorg/sglang:v0.5.12.post1-cu130}"   # the standalone bench-client image
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
MODEL_REPO="${MODEL_REPO:-moonshotai/Kimi-K2.6}"   # tokenizer source, resolved offline from the HF cache
MODEL_NAME="${MODEL_NAME:-kimi-k2.6}"            # request `model` id — MUST match the server
CONC="${CONC:-1 8 16 32 64 128}"                   # concurrency sweep (dense: locates the knee, incl. c16/c32)
PROMPTS_PER="${PROMPTS_PER:-8}"                    # num-prompts = PROMPTS_PER * concurrency
IN="${IN:-1024}"; OUT="${OUT:-256}"
PORT="${PORT:-30000}"
LOG="${LOG:-./bench.log}"
# The bench client runs in its OWN net namespace (no --network host), so it can't reach the server via
# 127.0.0.1 — it must hit a PUBLISHED host IP. Default TARGET_HOST = this host's LAN IP (the server
# publishes there); for a cross-host sweep, set TARGET_HOST=<peer LAN IP>.
LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
TARGET_HOST="${TARGET_HOST:-${LAN_IP:-127.0.0.1}}"
SERVER_NAME="${SERVER_NAME:-}"                     # optional: LOCAL container to read launch flags / KV from
# SERVER_NAME container-inspection only works when the server runs on THIS host. Skip it for a remote
# target (loopback or this host's own LAN IP = local; anything else = remote).
case "$TARGET_HOST" in 127.0.0.1|localhost|::1|"$LAN_IP") ;; *) SERVER_NAME="" ;; esac

KIMI_CACHE="$HF_HOME/hub/models--${MODEL_REPO//\//--}"
[ -f "$KIMI_CACHE/refs/main" ] || { echo "$MODEL_REPO not in HF cache ($KIMI_CACHE) — run download.sh" >&2; exit 1; }
MODEL_PATH="/models/repo/snapshots/$(cat "$KIMI_CACHE/refs/main")"   # container-side tokenizer path
: > "$LOG"

# Provenance: stamp HOW this sweep was produced into the log so the numbers are self-describing.
# '#'-prefixed lines never match the '^##########' / metric regexes, so the summary parser is unaffected.
# SERVER_NAME (optional) captures the server's launch flags + KV pool (engine-agnostic greps).
header() {
  { echo "# PROVENANCE $(date -u +%FT%TZ)  host=$(hostname)  target=$TARGET_HOST:$PORT  server=${SERVER_NAME:-?}"
    echo "# tool: sglang.bench_serving --backend sglang-oai (OpenAI /v1/completions, engine-agnostic; client image $BENCH_IMG, own netns)"
    echo "# server /v1/models: $(curl -s "http://$TARGET_HOST:$PORT/v1/models" 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"][0];print(d["id"],"max_model_len="+str(d.get("max_model_len")))' 2>/dev/null || echo '?')"
    if [ -n "$SERVER_NAME" ]; then
      echo "# launch: $(docker inspect --format '{{join .Args " "}}' "$SERVER_NAME" 2>/dev/null | grep -oE '[-][-](mem-fraction-static|kv-cache-dtype|context-length|max-model-len|gpu-memory-utilization|tp-size|tensor-parallel-size|chunked-prefill-size|max-num-seqs|quantization|moe-backend)[ =][^ ]+' | tr '\n' ' ')"
      echo "# kvpool: $(docker logs "$SERVER_NAME" 2>&1 | grep -oiE '#tokens: [0-9]+|GPU KV cache size: [0-9,]+ tokens' | tail -1)"
    fi
    echo "# grid: CONC=[$CONC] in=$IN out=$OUT prompts_per=$PROMPTS_PER"
  } | tee -a "$LOG"; echo "" | tee -a "$LOG"
}
header

run() {
  local c=$1 np=$2
  echo "########## max_concurrency=$c num_prompts=$np in=$IN out=$OUT model=$MODEL_NAME" | tee -a "$LOG"
  # Kimi tokenizer is a custom TikTokenTokenizer; sglang.bench_serving loads it with trust_remote_code
  # internally (no flag). random-ids needs only the tokenizer (vocab size) + the OpenAI /v1 endpoint.
  # own net namespace (no --network host) — reaches the server's PUBLISHED $TARGET_HOST:$PORT
  docker run --rm -v "$KIMI_CACHE:/models/repo:ro" \
    -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 --entrypoint python3 "$BENCH_IMG" \
    -m sglang.bench_serving --backend sglang-oai --host "$TARGET_HOST" --port "$PORT" \
    --model "$MODEL_PATH" --served-model-name "$MODEL_NAME" \
    --dataset-name random-ids --num-prompts "$np" \
    --random-input-len "$IN" --random-output-len "$OUT" --random-range-ratio 1.0 \
    --max-concurrency "$c" --disable-tqdm 2>&1 \
    | grep -E "Max request concurrency|Successful requests|Benchmark duration|Request throughput|Output token throughput|Total token throughput|Mean TTFT|Median TTFT|Mean TPOT|Median TPOT|Median ITL|error|Error|Traceback" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
}

for c in $CONC; do np=$(( c * PROMPTS_PER )); [ "$np" -ge 1 ] || np=1; run "$c" "$np"; done
echo "SWEEP_DONE" | tee -a "$LOG"

# ---- summary table parsed from $LOG ----
echo; echo "== summary: $MODEL_NAME via sglang.bench_serving (OpenAI /v1/completions, in=$IN out=$OUT) =="
printf '%-6s %-13s %-9s %-13s %-13s\n' conc out_tok/s req/s med_TTFT_ms med_TPOT_ms
awk '
  /^########## max_concurrency=/ { for(i=1;i<=NF;i++) if($i ~ /^max_concurrency=/){split($i,a,"="); c=a[2]} ; ot=rs=tt="?" }
  /Request throughput/            { rs=$NF }
  /Output token throughput/       { ot=$NF }
  /Median TTFT/                   { tt=$NF }
  /Median TPOT/                   { printf "%-6s %-13s %-9s %-13s %-13s\n", c, ot, rs, tt, $NF }
' "$LOG"
