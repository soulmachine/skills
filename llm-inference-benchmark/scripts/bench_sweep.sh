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
#
# Speculative decoding mode (SPEC=off|on): real text (vendored Spec-Bench, turn 0, chat template),
# natural EOS capped at OUT=1024, greedy unless TEMPERATURE; acceptance read from the server's /metrics.
# The script cannot restart the server, so an A/B (and a k sweep) is one run per server config:
#   SPEC=off bash bench_sweep.sh                       # server WITHOUT a drafter -> bench.spec-off.log
#   SPEC=on K=4 bash bench_sweep.sh                    # restart WITH a drafter at k=4 -> bench.spec-k4.log
#   bash bench_sweep.sh compare bench.spec-off.log bench.spec-k*.log    # speedup, best k, crossover
set -uo pipefail

BENCH_IMG="${BENCH_IMG:-lmsysorg/sglang:v0.5.12.post1-cu130}"   # the standalone bench-client image
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # for sse_keepalive_patch.py (see run())
SPECPY="$SCRIPT_DIR/spec.py"
[ "${1:-}" = compare ] && { shift; exec python3 "$SPECPY" compare "$@"; }

SPEC="${SPEC:-}"                                   # empty = plain random-ids sweep; off|on = speculative mode
case "$SPEC" in ""|off|on) ;; *) echo "SPEC must be empty, off or on" >&2; exit 1 ;; esac
if [ -n "$SPEC" ]; then                            # spec-mode defaults (set before the plain ones below)
  CONC="${CONC:-1 8 32 64}"                        # idle -> busy; the crossover lives in here
  PROMPTS_PER="${PROMPTS_PER:-7}"                  # c64 x 7 = 448 <= Spec-Bench's 480: no repeated prompts
  OUT="${OUT:-1024}"                               # a cap: requests stop at the model's own EOS
  DATASET="${DATASET:-$SCRIPT_DIR/../data/spec_bench.jsonl}"
  TEMPERATURE="${TEMPERATURE:-0}"
  CAT_N="${CAT_N:-10}"                             # SPEC=on: prompts per c1 category pass; 0 skips them
  K="${K:-}"                                       # SPEC=on: draft tokens per step the server runs with
  [ "$SPEC" = on ] && [ -z "$K" ] && { echo "SPEC=on needs K=<draft tokens per step the server was started with>" >&2; exit 1; }
  [ -f "$DATASET" ] || { echo "DATASET not found: $DATASET" >&2; exit 1; }
  LOG="${LOG:-./bench.spec-$([ "$SPEC" = on ] && echo "k$K" || echo off).log}"
  NCAT=$(python3 "$SPECPY" categories "$DATASET" | grep -c .); [ "$NCAT" -ge 1 ] || NCAT=1
fi
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
MODEL_REPO="${MODEL_REPO:-moonshotai/Kimi-K2.6}"   # tokenizer source, resolved offline from the HF cache
MODEL_NAME="${MODEL_NAME:-kimi-k2.6}"            # request `model` id — MUST match the server
CONC="${CONC:-1 8 16 32 64 128}"                   # concurrency sweep (dense: locates the knee, incl. c16/c32)
PROMPTS_PER="${PROMPTS_PER:-8}"                    # num-prompts = PROMPTS_PER * concurrency
IN="${IN:-1024}"; OUT="${OUT:-256}"
INLBL=$([ -n "$SPEC" ] && echo text || echo "$IN")   # spec mode: real prompts, no fixed input length
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

# Speculative-decoding probe: one greedy 256-token request between two /metrics snapshots. A plain
# random-ids sweep against a drafter reports fake tok/s (REFERENCE.md: 26.5 tok/s), so it aborts;
# SPEC=off must see no drafting, SPEC=on must see it (acceptance is a required result of that mode).
MURL="http://$TARGET_HOST:$PORT/metrics"
probe() {
  local b a; b=$(python3 "$SPECPY" snap "$MURL")
  curl -s -m 600 "http://$TARGET_HOST:$PORT/v1/completions" -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL_NAME\",\"prompt\":\"Write a Python function that returns the first 50 Fibonacci numbers, with a docstring and three tests.\",\"max_tokens\":256,\"temperature\":0}" >/dev/null
  a=$(python3 "$SPECPY" snap "$MURL")
  python3 "$SPECPY" moved "$b" "$a" ${K:+"$K"}
}
SPEC_STATE=$(probe); rc=$?
die() { echo "$*" >&2; exit 1; }
case "$SPEC:$rc" in
  :0)    [ "${FORCE:-0}" = 1 ] || die "the server runs speculative decoding ($SPEC_STATE): random-ids prompts inflate tok/s. Use SPEC=off/on, or FORCE=1." ;;
  :2)    echo "warning: cannot read speculative metrics: $SPEC_STATE — stamping spec=unknown" >&2; SPEC_STATE=unknown ;;
  off:0) [ "${FORCE:-0}" = 1 ] || die "SPEC=off but the server drafts ($SPEC_STATE): restart it without a drafter, or FORCE=1." ;;
  *:2)   die "SPEC=$SPEC needs the server's /metrics (vLLM: on by default; SGLang: --enable-metrics; llama.cpp: --metrics): $SPEC_STATE" ;;
  on:1)  die "SPEC=on but the probe saw no drafting: is the server running with a drafter?" ;;
esac
if [ -n "$SPEC" ]; then
  WORK=$(mktemp -d); POLLPID=""
  trap '[ -n "$POLLPID" ] && kill "$POLLPID" 2>/dev/null; rm -rf "$WORK"' EXIT
fi
: > "$LOG"

# Provenance: stamp HOW this sweep was produced into the log so the numbers are self-describing.
# '#'-prefixed lines never match the '^##########' / metric regexes, so the summary parser is unaffected.
# SERVER_NAME (optional) captures the server's launch flags + KV pool (engine-agnostic greps).
header() {
  { echo "# PROVENANCE $(date -u +%FT%TZ)  host=$(hostname)  target=$TARGET_HOST:$PORT  server=${SERVER_NAME:-?}"
    echo "# tool: sglang.bench_serving --backend sglang-oai (OpenAI /v1/completions, engine-agnostic; client image $BENCH_IMG, own netns)"
    echo "# server /v1/models: $(curl -s "http://$TARGET_HOST:$PORT/v1/models" 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"][0];print(d["id"],"max_model_len="+str(d.get("max_model_len")))' 2>/dev/null || echo '?')"
    if [ -n "$SERVER_NAME" ]; then
      echo "# launch: $(docker inspect --format '{{join .Args " "}}' "$SERVER_NAME" 2>/dev/null | grep -oE '[-][-](mem-fraction-static|kv-cache-dtype|context-length|max-model-len|gpu-memory-utilization|tp-size|tensor-parallel-size|chunked-prefill-size|max-num-seqs|quantization|moe-backend|speculative[-a-z]*|spec-type|draft-max|draft-min|model-draft)[ =][^ ]+' | tr '\n' ' ')"
      echo "# kvpool: $(docker logs "$SERVER_NAME" 2>&1 | grep -oiE '#tokens: [0-9]+|GPU KV cache size: [0-9,]+ tokens' | tail -1)"
    fi
    if [ -n "$SPEC" ]; then
      echo "# grid: CONC=[$CONC] dataset=$(basename "$DATASET") sha256=$(sha256sum "$DATASET" | cut -c1-16) out=$OUT prompts_per=$PROMPTS_PER min_prompts=$NCAT temperature=$TEMPERATURE eos=natural chat_template=on"
      echo "# spec: SPEC=$SPEC K=${K:--} probe=${SPEC_STATE// /_} cat_n=$CAT_N"
      echo "# metrics: SPECPOINT/SPECCAT lines (retokenized tokens, token-weighted TPOT) — the client's own throughput/TPOT lines miscount tokens once requests stop at EOS"
    else
      echo "# grid: CONC=[$CONC] in=$IN out=$OUT prompts_per=$PROMPTS_PER"
      echo "# spec: probe=${SPEC_STATE// /_}"
    fi
  } | tee -a "$LOG"; echo "" | tee -a "$LOG"
}
header

run() {
  local c=$1 np=$2 cat=${3:-} before after
  local ds=(--dataset-name random-ids --random-input-len "$IN" --random-output-len "$OUT" --random-range-ratio 1.0) mnt=()
  if [ -n "$SPEC" ]; then
    # An exact prompt file per point: the client's custom loader shuffles and silently returns fewer
    # rows than asked when the file is short, so off and on would not see the same prompts.
    python3 "$SPECPY" sample "$DATASET" "$np" ${cat:+"$cat"} > "$WORK/prompts.jsonl" || exit 1
    rm -f "$WORK/result.jsonl"; : > "$WORK/poll.jsonl"
    ds=(--dataset-name custom --dataset-path /work/prompts.jsonl --sharegpt-output-len "$OUT"
        --apply-chat-template --disable-ignore-eos --extra-request-body "{\"temperature\":$TEMPERATURE}"
        --output-file /work/result.jsonl --output-details)
    mnt=(-v "$WORK:/work")
    before=$(python3 "$SPECPY" snap "$MURL")
    python3 "$SPECPY" poll "$MURL" "$WORK/poll.jsonl" & POLLPID=$!   # SGLang: gauges only, sample them
  fi
  echo "########## max_concurrency=$c num_prompts=$np ${cat:+category=$cat }in=$INLBL out=$OUT model=$MODEL_NAME" | tee -a "$LOG"
  # Kimi tokenizer is a custom TikTokenTokenizer; sglang.bench_serving loads it with trust_remote_code
  # internally (no flag). random-ids needs only the tokenizer (vocab size) + the OpenAI /v1 endpoint.
  # own net namespace (no --network host) — reaches the server's PUBLISHED $TARGET_HOST:$PORT
  # sse_keepalive_patch.py runs first, inside the client container: sglang.bench_serving
  # feeds SSE comment/keep-alive lines (a bare ":") to json.loads and counts the resulting
  # JSONDecodeError as a FAILED request. llama.cpp emits those keep-alives during slow
  # prefill, so on a slow/contended server this silently voids the run — most requests are
  # recorded as failures and the curve reads as premature saturation. Idempotent.
  # The client runs as root; hand /work back to this user so the trap can remove it.
  docker run --rm -v "$KIMI_CACHE:/models/repo:ro" "${mnt[@]}" \
    -v "$SCRIPT_DIR/sse_keepalive_patch.py:/sse_keepalive_patch.py:ro" \
    -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 --entrypoint bash "$BENCH_IMG" \
    -lc 'python3 /sse_keepalive_patch.py >&2 && python3 "$@"; rc=$?; [ -d /work ] && chown -R '"$(id -u):$(id -g)"' /work; exit $rc' _ \
    -m sglang.bench_serving --backend sglang-oai --host "$TARGET_HOST" --port "$PORT" \
    --model "$MODEL_PATH" --served-model-name "$MODEL_NAME" \
    "${ds[@]}" --num-prompts "$np" \
    --max-concurrency "$c" --disable-tqdm 2>&1 \
    | grep -E "Max request concurrency|Successful requests|Benchmark duration|Total generated tokens|Request throughput|Output token throughput|Total token throughput|Mean TTFT|Median TTFT|Mean TPOT|Median TPOT|Median ITL|error|Error|Traceback" | tee -a "$LOG"
  if [ -n "$SPEC" ]; then
    kill "$POLLPID" 2>/dev/null; wait "$POLLPID" 2>/dev/null; POLLPID=""
    after=$(python3 "$SPECPY" snap "$MURL")
    if [ -s "$WORK/result.jsonl" ]; then
      python3 "$SPECPY" point "$WORK/result.jsonl" "$before" "$after" "$WORK/poll.jsonl" ${cat:+"$cat"} | tee -a "$LOG"
    else
      echo "SPECFAIL c=$c ${cat:+cat=$cat }no client result (see errors above)" | tee -a "$LOG"
    fi
  fi
  echo "" | tee -a "$LOG"
}

for c in $CONC; do
  np=$(( c * PROMPTS_PER )); [ "$np" -ge 1 ] || np=1
  [ -n "$SPEC" ] && [ "$np" -lt "$NCAT" ] && np=$NCAT   # every point covers every category
  run "$c" "$np"
done
# Acceptance depends on content, not concurrency: one c1 pass per category, mixed sweep above.
if [ "$SPEC" = on ] && [ "$CAT_N" -gt 0 ]; then
  for cat in $(python3 "$SPECPY" categories "$DATASET"); do run 1 "$CAT_N" "$cat"; done
fi
echo "SWEEP_DONE" | tee -a "$LOG"
[ -n "$SPEC" ] && { echo; python3 "$SPECPY" compare "$LOG"; exit 0; }

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
