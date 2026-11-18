---
name: llm-inference-benchmark
description: Benchmark OpenAI-compatible LLM inference servers (vLLM, SGLang, or anything serving /v1/completions; local, cross-host via TARGET_HOST=<peer LAN IP>, or behind a TLS+Bearer proxy via --base-url + OPENAI_API_KEY) with sglang.bench_serving run as a standalone dockerized client — one engine-agnostic script (scripts/bench_sweep.sh), default sweep c1→c128 uncapped, sustained-load grid (uniform prompts-per-concurrency), self-describing PROVENANCE log headers — collecting TTFT, TPOT, ITL, and input/output/total token throughput. From those metrics, derive insights: (1) the min and max knee of the saturation curve — min = highest concurrency where TTFT/TPOT is still flat (latency-optimal cap), max = where output throughput goes flat (throughput ceiling) — to pick a production --max-num-seqs / --max-running-requests; (2) whether the box is prefill- or decode-bound (the min-vs-max-knee gap, IN/TTFT vs 1/TPOT, or a prefill-heavy/decode-heavy shape sweep); (3) whether a throughput plateau is a real compute/comm knee or a false one (a binding MAX_SEQS cap or KV exhaustion) — via the flat-throughput+flat-TPOT+rising-TTFT signature, the running-vs-offered gauges (num_running/num_waiting), and a raise-the-cap-and-re-measure check. Speculative decoding mode (SPEC=off|on): A/B on real text (vendored Spec-Bench, chat template, natural EOS) with acceptance from the server's /metrics, a k sweep over draft tokens per step (one run per k), per-category acceptance, and a compare step that prints speedup, TPOT, the best k per concurrency and the crossover concurrency where speculation stops paying; plain sweeps abort when the server drafts. Includes verified Kimi-K2.6 baselines on 8× RTX PRO 6000 Blackwell (INT4 SGLang/vLLM, fp8-vs-bf16 KV, NVFP4 marlin-vs-b12x, Caddy proxy overhead). Use when asked to benchmark or compare LLM servers (tokens/sec, TTFT, TPOT, ITL) across engines, quantizations, KV-cache dtypes or MoE backends, find the saturation knee / pick a concurrency cap, determine prefill- vs decode-boundedness, evaluate speculative decoding (EAGLE, MTP, DFlash, draft model, n-gram), pick k (num_speculative_tokens / draft tokens) or find where speculation stops paying, run a cross-host A/B, quantify reverse-proxy overhead, interpret why high-concurrency numbers look inflated (short-burst trap) or why two sweeps aren't comparable (MAX_SEQS / grid mismatch), or debug a sweep that prints SWEEP_DONE with no metrics.
---

# Benchmark OpenAI-compatible LLM inference servers

One tool, one methodology, engine-agnostic: **`sglang.bench_serving`** as a pure HTTP load
generator, always hitting the **OpenAI `/v1/completions`** endpoint (every serious engine serves
it), always running as a **standalone dockerized client in its own net namespace** — never
`docker exec` into the server, never `--network host`. The server's identity (engine, quant, flags)
is *measured into the log*, not assumed: every run opens with a PROVENANCE header.

**The point of a sweep is the saturation curve's two knees.** Read them off a wide concurrency sweep
on a non-binding server: the **min knee** (highest concurrency where TTFT/TPOT is still flat — the
latency-optimal cap) and the **max knee** (where output throughput goes flat — the throughput
ceiling). A production concurrency cap belongs between them — see **Finding the saturation knees** below.

The reference dataset (Kimi-K2.6 on 8× RTX PRO 6000 Blackwell SE, deployed by
`deploy-kimi-k26-on-rtx-pro-6000`) lives in [REFERENCE.md](REFERENCE.md) — use it as the comparison
anchor when re-benchmarking that hardware after an image bump, config change, or engine swap.

## Prerequisites
- A server exposing `/v1/completions` on `TARGET_HOST:PORT` (local LAN IP or a peer host's).
- The **tokenizer's model repo cached on the client host** under `$HF_HOME` (`random-ids` needs only
  the vocab; any same-tokenizer repo works — see cross-host notes in REFERENCE.md).
- Docker + the SGLang image for the client (`lmsysorg/sglang:v0.5.12.post1-cu130` by default — the
  client is CPU-only; vLLM's image ships no bench tool, so even vLLM servers are benched with this).

## Run

```bash
bash scripts/bench_sweep.sh                          # local server, conc {1,8,16,32,64,128}, 1024in/256out
TARGET_HOST=192.168.55.227 MODEL_NAME=kimi-k2.6 \
  MODEL_REPO=nvidia/Kimi-K2.6-NVFP4 bash scripts/bench_sweep.sh    # cross-host (peer LAN IP)
CONC="1 8 16 64 128" PROMPTS_PER=8 LOG=./bench.log bash scripts/bench_sweep.sh
```

| Knob | Default | Meaning |
|---|---|---|
| `TARGET_HOST` | this host's LAN IP | server address (a bridged client can't use the server-host's `127.0.0.1`) |
| `PORT` | `30000` | server port |
| `MODEL_NAME` | `kimi-k2.6` | the request `model` field — MUST match the server's served name |
| `MODEL_REPO` | `moonshotai/Kimi-K2.6` | tokenizer source, resolved offline from the **client host's** `$HF_HOME` |
| `CONC` | `1 8 16 32 64 128` | concurrency sweep points (dense enough to locate the knee — c16/c32 matter) |
| `PROMPTS_PER` | `8` | num_prompts = PROMPTS_PER × concurrency (sustained load — see Methodology) |
| `IN` / `OUT` | `1024` / `256` | random-ids input/output lengths |
| `SERVER_NAME` | *(empty)* | LOCAL server container name — stamps its launch flags + KV pool into the header (auto-skipped for remote targets) |
| `LOG` | `./bench.log` | output log (PROVENANCE header + per-point metrics + parsed summary table) |
| `BENCH_IMG` | the SGLang image | client image |

Every run first sends one 256-token probe and reads the server's speculative decoding counters. If the
server drafts, a plain `random-ids` sweep **aborts** (random prompts make the drafter accept degenerate
repeats: the fake 26.5 tok/s in REFERENCE.md); use the speculative decoding mode below, or `FORCE=1`. A
server without `/metrics` gets a warning and `spec=unknown` in the header.

## Methodology rules (violating these produced wrong numbers — see REFERENCE.md)
1. **Sustained load**: keep `num_prompts = PROMPTS_PER × concurrency` (uniform `prompts_per=8`).
   Short bursts never reach steady state and **over-report high concurrency** (a 192-prompt c128 run
   read 613 tok/s where the sustained number is 377.7).
2. **Identical grid for any comparison** — same `CONC`, `PROMPTS_PER`, `IN/OUT`, same endpoint.
3. **Server-side `--max-num-seqs` (MAX_SEQS) changes what a concurrency column *means*** (c64 against
   a MAX_SEQS=16 server is 16-wide with a 48-deep queue). Never read across tables with different caps.
4. **One endpoint, one client network path** — the script pins `/v1/completions` (`--backend
   sglang-oai`, byte-identical to the `vllm` backend) and a bridged (own-netns) client. Client
   placement/network mode alone moves c1 readings by up to ~10% (see REFERENCE.md); never mix
   client paths or endpoints within a comparison.
5. Every log opens with a **PROVENANCE header** (date, tool, server `/v1/models`, launch flags + KV
   pool when local, grid) — a number without its header is not a baseline.

## Finding the saturation knees (the point of the sweep)

A wide concurrency sweep on a **non-binding** server (uncapped, or one fixed cap above your top sweep
point with a KV pool that holds it) exists to surface two knees:
- **min knee** — highest concurrency where **TTFT/TPOT is still flat** (whichever lifts first; TTFT
  usually does) → the **latency-optimal** cap.
- **max knee** — where **output throughput goes flat** → the **throughput ceiling** (past it, more
  concurrency buys only TTFT).

They needn't coincide: TTFT (prefill + queue) usually degrades *before* output throughput (decode)
plateaus, so **min knee ≤ max knee** (equal only when decode-bound). Put a production cap
(`--max-num-seqs` / SGLang `--max-running-requests`) in `[min knee, max knee]` — toward min for
latency, max for throughput.

**Keep the cap non-binding, or you measure the cap, not the box.** Throughput/TPOT are set by the
**running** concurrency (the server cap); `--max-concurrency` is only the **offered** concurrency. A
cap below your top sweep point fakes a knee at the cap (every offered ≥ cap runs cap-wide → tput +
TPOT flat, only TTFT climbs). **Never** set cap = per-point concurrency (resizes the server *and its
KV pool* each point, erasing the signal — that measures throughput-vs-batch-width, not saturation).

**Real knee vs false knee — three checks:**
1. **TTFT signature** — flat-tput + flat-TPOT + *linearly rising* TTFT = pure queueing (a cap or KV
   binding running below offered). A *real compute* knee instead has tput flatten while TTFT **and**
   TPOT rise *together, gently* — a genuinely wider batch with the GPU as bottleneck, not a queue.
2. **running vs offered** (engine `num_running_reqs`/`num_waiting_reqs`, or vLLM running/pending):
   running plateaus *at* MAX_SEQS → cap binding (raise it); running plateaus *below* cap and below
   offered → KV pool exhausted (e.g. marlin's 139K pool caps c128 at ~108 → raise fp8/util); running
   keeps tracking offered but tput is flat → **real compute/comm knee.**
3. **Raise-and-re-measure** — bump MAX_SEQS (and/or KV) at the suspected knee and re-run it; if tput
   climbs the knee was an artifact, so keep raising until tput stops responding. The concurrency past
   which a bigger cap buys no throughput is the **real** knee.

**Picking the production cap** — the **running** batch sets throughput + TPOT; **offered** load above
it just queues, surfacing as TTFT (at a cap of 64: c64 = 64 running / 0 queued, c128 = 64 running /
64 queued — *same* throughput + TPOT, far worse TTFT). Choose by goal:
- **Throughput / batch (no tight SLA)** → cap **at the max knee** (or leave uncapped — past it
  throughput is flat anyway; capping there only avoids non-productive running requests and bounds TPOT).
- **Interactive / SLA-bound** → cap where **p95/p99 TTFT (or TPOT) still meets SLA**, usually *below*
  the max knee. (E.g. SGLang INT4's throughput knee is ~c32 at 345 tok/s / ~2.3 s TTFT; by c64
  throughput is flat but TTFT is ~24 s — an SLA of TTFT < 1 s would cap *below* c32.)

**Forced-cap exception**: an engine that can't boot uncapped at the target context is benched through
a fixed cap and its curve is valid only up to it (NVFP4 `flashinfer_b12x` uncapped profiles a 49K
pool < one 131K request → won't start; a `c > cap` point is just cap + queue).

**Prefill- vs decode-bound (read it off the same sweep).** Two tells: **(1) knee gap** — min knee ≪
max knee (TTFT degrades well before throughput plateaus) ⇒ prefill/queue is the first bottleneck at
this shape; min ≈ max ⇒ decode-bound (combo A: min≈max≈c32, decode-bound; combo B: min≈c32 ≪
max > c128, prefill-contended). **(2) c1 rates** — prefill rate ≈ `IN/TTFT`, decode rate ≈ `1/TPOT`;
compare per-request prefill time (`IN/prefill_rate`) vs decode time (`OUT × TPOT`). Boundedness is
**shape-dependent** (the default 1024-in/256-out is input-heavy, 4:1), so to classify the *box*
directly sweep two shapes — prefill-heavy (`IN=4096 OUT=16`) vs decode-heavy (`IN=128 OUT=2048`) —
and see which one saturates first.

## Speculative decoding mode (`SPEC=off|on`)

Method from [Speculative decoding: when it helps and when it doesn't](https://huggingface.co/datasets/inference-engineering-academy/llm-inference-notes/raw/main/articles/speculative-decoding.md):
measure acceptance on real prompts, sweep k (draft tokens per step, 2 to 6 is typical) and concurrency
(1, 8, 32, 64), report inter-token latency and throughput at each point, and find the **crossover
concurrency** where speculation stops paying. Enable speculation only below it.

The script cannot restart the server, so each server config is one run, and `compare` joins them:

```bash
SPEC=off bash scripts/bench_sweep.sh                       # server WITHOUT a drafter -> bench.spec-off.log
for k in 2 3 4 5 6; do
  # restart the server with the drafter at k (see the table below), wait for /v1/models, then:
  SPEC=on K=$k bash scripts/bench_sweep.sh                 # -> bench.spec-k$k.log
done
bash scripts/bench_sweep.sh compare bench.spec-off.log bench.spec-k*.log
```

| Knob | Default | Meaning |
|---|---|---|
| `SPEC` | *(empty)* | `off` = server without a drafter, `on` = with one (the probe checks both) |
| `K` | *(required for `on`)* | the draft tokens per step the server was started with; a label for the log. vLLM's counters give the real value: a mismatch warns and is stamped `K_MISMATCH` |
| `CONC` / `PROMPTS_PER` | `1 8 32 64` / `7` | 7 keeps c64 at 448 of Spec-Bench's 480 prompts (no repeats, so no prefix-cache hits); every point gets at least one prompt per category |
| `OUT` | `1024` | a cap: requests stop at the model's own EOS (`ignore_eos` would make the model repeat itself, which inflates acceptance) |
| `TEMPERATURE` | `0` | greedy: reproducible, and off and on generate the same text. Run your production temperature as a second pass before you pick a config |
| `DATASET` | `data/spec_bench.jsonl` | JSONL rows `{"category", "conversations": [{"role":"user","content":...}, {"role":"assistant","content":""}]}`; use your own captured prompts for the number that predicts production |
| `CAT_N` | `10` | `SPEC=on`: one c1 pass of N prompts per category (13 for Spec-Bench) for the acceptance table; `0` skips them |
| `LOG` | `bench.spec-off.log` / `bench.spec-k<K>.log` | |

Flags that set k: vLLM `--speculative-config '{"method":...,"num_speculative_tokens":K}'`; SGLang
`--speculative-num-draft-tokens` (EAGLE also has `--speculative-num-steps` and `--speculative-eagle-topk`;
vary one, log the others); llama.cpp `--draft-max`. Pass `SERVER_NAME` on a local server and the
header stamps these flags too.

**What the mode does differently:**
- **Prompts**: the vendored Spec-Bench turn 0 (480 prompts, 13 categories, Apache-2.0, see
  `data/NOTICE.md`), wrapped in the model's chat template (`--apply-chat-template`, still sent to
  `/v1/completions`), so `MODEL_REPO` must carry the real chat template. The script writes an exact
  prompt file for each point, so off and on see the same prompts at each concurrency.
- **Acceptance** comes from `/metrics`, read before and after each point: vLLM and llama.cpp counters
  give `accept_len` (tokens per target pass, = 1 + accepted / drafts) and `accept_rate` (accepted /
  draft tokens); SGLang has gauges only, sampled every 2 s. The mode fails without `/metrics`: vLLM
  has it by default, SGLang needs `--enable-metrics`, llama.cpp needs `--metrics`.
- **Numbers**: each point writes a `SPECPOINT` line (category passes: `SPECCAT`). Throughput uses the
  retokenized output, and TPOT is token-weighted (decode time / tokens after the first). Ignore the
  client's own throughput and TPOT lines in this mode: once requests stop at EOS it counts
  `max_tokens` for streams without usage (vLLM). Report TPOT, not ITL: with speculation one SSE chunk
  carries several tokens.
- **`compare`** refuses logs whose grid or model differ. It prints per concurrency the off throughput
  and TPOT, and for each k the speedup (`x1.42` = on / off output tok/s), TPOT and accept length; the
  best k per concurrency; the crossover per k (the lowest concurrency where that k is slower than
  off); and the acceptance table by category. It warns when off and on generated more than 5% different
  token totals at a point (temperature > 0, a lossy drafter, or failed requests).

Expect: speculation wins at low concurrency and on predictable text (code, extraction, summaries that
copy the prompt), and loses once the batch fills the GPU. A larger k pays only when acceptance is high.

## Variants
- **Cross-host**: `TARGET_HOST=<peer-lan-ip>`; `MODEL_REPO` must be cached client-side (it's only the
  tokenizer — an NVFP4 host benching a remote INT4 server uses its local NVFP4 repo).
- **Through a TLS+auth proxy** (measures the proxy, e.g. Caddy): run the client manually with
  `--base-url https://<host>` and `-e OPENAI_API_KEY=<key>` (auto-sent as `Authorization: Bearer`).
  Measured Caddy overhead on the reference host: ~1% throughput, +15 ms TTFT @ c1 — REFERENCE.md.

## Troubleshooting
Plain sweep aborts with "the server runs speculative decoding" → use `SPEC=off/on`, or `FORCE=1` if
you really want random-ids numbers; `SPEC=on` fails with "no drafting" → the server was not restarted
with the drafter; `SPECFAIL` lines → the client produced no result, check the errors above them (a
tokenizer without a chat template fails `--apply-chat-template`).
PROVENANCE header prints but **zero metrics + instant SWEEP_DONE** → a host INPUT firewall is
dropping the bridged client (src `172.17.x`); `"<repo> not in HF cache"` → cache the tokenizer repo
on the **client** host; empty `/v1/models` in the header → wrong `TARGET_HOST`/`PORT` or server not
up; all-`?` summary rows → requests failing, check `MODEL_NAME` matches the server. More in
[REFERENCE.md](REFERENCE.md).
