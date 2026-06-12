---
name: llm-inference-benchmark
description: Benchmark OpenAI-compatible LLM inference servers (vLLM, SGLang, or anything serving /v1/completions) with sglang.bench_serving run as a standalone dockerized client — one engine-agnostic script (scripts/bench_sweep.sh), a canonical sustained-load methodology (uniform prompts-per-concurrency grid, self-describing PROVENANCE log headers), local or cross-host targets (TARGET_HOST=<peer LAN IP>), and through a TLS+Bearer reverse proxy (--base-url + OPENAI_API_KEY). Includes the verified Kimi-K2.6 baselines on 8× RTX PRO 6000 Blackwell (INT4 SGLang/vLLM, fp8-vs-bf16 KV, NVFP4 marlin-vs-b12x, Caddy proxy overhead). Use when asked to benchmark an LLM server, measure tokens/sec / TTFT / TPOT / ITL, compare engines, quantizations, KV-cache dtypes or MoE backends, quantify proxy overhead, run a cross-host A/B, interpret why high-concurrency numbers look inflated (short-burst trap) or why two sweeps aren't comparable (MAX_SEQS / grid mismatch), or debug a sweep that prints SWEEP_DONE with no metrics.
---

# Benchmark OpenAI-compatible LLM inference servers

One tool, one methodology, engine-agnostic: **`sglang.bench_serving`** as a pure HTTP load
generator, always hitting the **OpenAI `/v1/completions`** endpoint (every serious engine serves
it), always running as a **standalone dockerized client in its own net namespace** — never
`docker exec` into the server, never `--network host`. The server's identity (engine, quant, flags)
is *measured into the log*, not assumed: every run opens with a PROVENANCE header.

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
bash scripts/bench_sweep.sh                          # local server, conc {1,8,64,128}, 1024in/256out
TARGET_HOST=192.168.55.227 SERVED_NAME=kimi-k2.6 \
  MODEL_REPO=nvidia/Kimi-K2.6-NVFP4 bash scripts/bench_sweep.sh    # cross-host (peer LAN IP)
CONC="1 8 16 64 128" PROMPTS_PER=8 LOG=./bench.log bash scripts/bench_sweep.sh
```

| Knob | Default | Meaning |
|---|---|---|
| `TARGET_HOST` | this host's LAN IP | server address (a bridged client can't use the server-host's `127.0.0.1`) |
| `PORT` | `30000` | server port |
| `SERVED_NAME` | `kimi-k2.6` | the request `model` field — MUST match the server's served name |
| `MODEL_REPO` | `moonshotai/Kimi-K2.6` | tokenizer source, resolved offline from the **client host's** `$HF_HOME` |
| `CONC` | `1 8 64 128` | concurrency sweep points |
| `PROMPTS_PER` | `8` | num_prompts = PROMPTS_PER × concurrency (sustained load — see Methodology) |
| `IN` / `OUT` | `1024` / `256` | random-ids input/output lengths |
| `SERVER_NAME` | *(empty)* | LOCAL server container name — stamps its launch flags + KV pool into the header (auto-skipped for remote targets) |
| `LOG` | `./bench.log` | output log (PROVENANCE header + per-point metrics + parsed summary table) |
| `BENCH_IMG` | the SGLang image | client image |

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

## Variants
- **Cross-host**: `TARGET_HOST=<peer-lan-ip>`; `MODEL_REPO` must be cached client-side (it's only the
  tokenizer — an NVFP4 host benching a remote INT4 server uses its local NVFP4 repo).
- **Through a TLS+auth proxy** (measures the proxy, e.g. Caddy): run the client manually with
  `--base-url https://<host>` and `-e OPENAI_API_KEY=<key>` (auto-sent as `Authorization: Bearer`).
  Measured Caddy overhead on the reference host: ~1% throughput, +15 ms TTFT @ c1 — REFERENCE.md.

## Troubleshooting
PROVENANCE header prints but **zero metrics + instant SWEEP_DONE** → a host INPUT firewall is
dropping the bridged client (src `172.17.x`); `"<repo> not in HF cache"` → cache the tokenizer repo
on the **client** host; empty `/v1/models` in the header → wrong `TARGET_HOST`/`PORT` or server not
up; all-`?` summary rows → requests failing, check `SERVED_NAME` matches the server. More in
[REFERENCE.md](REFERENCE.md).
