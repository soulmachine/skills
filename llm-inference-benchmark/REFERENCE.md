# Reference — LLM inference benchmarking (tool, methodology, Kimi-K2.6 baselines)

## The tool: `sglang.bench_serving` as a decoupled HTTP load generator

- **Why this tool**: ships in the SGLang image (no install), supports OpenAI-compatible servers,
  reports the full metric set (request/token throughput, TTFT, TPOT, ITL, duration), and takes
  `--max-concurrency` + `--num-prompts` for controlled sweeps. The vLLM image ships **no** bench
  tool, so vLLM servers are benched with this client too.
- **Backend → endpoint map** (from `bench_serving.py`): `sglang`/`sglang-native` → SGLang's native
  `/generate`; **`sglang-oai` / `vllm` / `lmdeploy` → OpenAI `/v1/completions` (identical code
  path)**; `*-chat` variants → `/v1/chat/completions`. The script pins **`--backend sglang-oai`** so
  one wire protocol covers every engine — it genuinely doesn't care what's serving.
- **The client's network path shifts c1 readings — keep it constant (measured confound).** Against
  the *same* SGLang INT4 fp8 server at c1, runs differing only in client placement/network mode
  spread **59.1–65.2 tok/s and TTFT ~110–535 ms** (local bridged client ≈ 59.5/535; local host-net
  client ≈ 64.6–65.2/104–140; remote bridged client has read both ~64.6/110 and ~59.1 across server
  network configs). The deltas are client/path-side (docker SNAT, hairpin vs real LAN, connection
  setup), not server throughput — and dwarf any `/generate`-vs-`/v1/completions` endpoint effect.
  Rules: this script's standalone bridged client is the canon (isolation; consistent everywhere);
  never mix client placements, network modes, or endpoints within one comparison; treat c1 absolutes
  as path-specific — ratios between configs measured identically remain valid, and c≥8 points are
  far less path-sensitive.
- **Standalone client doctrine**: the client always runs as its own container
  (`docker run --rm`, **own net namespace** — not `--network host`, never `docker exec` into the
  server). It reaches the server at `TARGET_HOST:PORT` (the server host's LAN IP). This decouples
  client from server (works for any engine, local or remote) and keeps the load generator out of
  the server's namespace. Auth/TLS proxies are reachable the same way via `--base-url` +
  `OPENAI_API_KEY` (the client auto-sends `Authorization: Bearer $OPENAI_API_KEY`).
- Deployed operational copies of `scripts/bench_sweep.sh` on the reference hosts
  (`/data/devops/kimi/bench_sweep.sh` on 3ed, `/usr/local/bin/bench_sweep.sh` on 3ee) track this
  skill's copy — re-sync them when the script changes.

## Methodology (each rule bought with a wrong number)

- **Sustained load, not bursts.** `num_prompts = PROMPTS_PER × concurrency` (canonical
  `prompts_per=8` ⇒ 8/64/128/256/512/1024 prompts at c1/8/16/32/64/128). **Case study**: the 2026-06-11
  short-burst sweeps (num_prompts 8/32/128/192) reported SGLang fp8 c128 = **613 tok/s**; the
  sustained grid measures **377.7** — 192 prompts at c128 never reached steady state, so the burst
  over-reported by +62%. High-concurrency numbers from short runs are not baselines.
- **`MAX_SEQS` (server `--max-num-seqs`) changes column meaning.** Against a `MAX_SEQS=16` server,
  a "c64" point is *16 concurrent with a 48-deep queue* — throughput saturates and queueing latency
  explodes, by design. Valid for A/Bs at a fixed operating point (that's why the NVFP4 A/B used it),
  invalid to compare against uncapped tables.
- **Finding the saturation knee — keep the cap non-binding (offered = running).** Throughput, input
  tput, and TPOT are set by the **running** concurrency (server `--max-num-seqs` / SGLang
  `--max-running-requests`); the bench's `--max-concurrency` sets only the **offered** concurrency.
  They're equal only when the cap ≥ offered *and* the KV pool holds it (≥ conc × context). To find a
  real knee, sweep **uncapped** (or one fixed cap ≥ the top sweep point + a pool that holds it) so
  running = offered everywhere — the plateau is then the box's. **A cap below your top concurrency
  fakes a knee at the cap**: every offered ≥ cap runs cap-wide, so output/input tput and TPOT go flat
  across those points and only TTFT grows (queue depth = offered − cap). That flat-tput + flat-TPOT +
  rising-TTFT pattern *is* "the cap is binding," not hardware saturation. Diagnose: running ≈ offered
  at the plateau (`num_running`/`num_waiting`), or raise the cap and re-run the point — if tput
  climbs, the knee was the cap; if running plateaus *below* the cap, it's the KV pool (e.g.
  NVFP4-marlin's 139K pool caps c128 at ~108 running, 295 tok/s). **Never re-cap per point** (cap = c
  at each c): that changes the server — and its KV pool — at every point and erases the queueing
  signal; it measures throughput-vs-batch-width, not a deployment saturation curve. **Deploy
  corollary**: production cap = min(measured knee, the concurrency where p95 TTFT/TPOT still meets
  SLA) — above the knee buys no throughput, only TPOT, and the SLA point is usually ≤ the knee.
  **Forced-cap exception**: an engine that can't boot uncapped at the target context is taken through
  a fixed cap and its curve is valid only up to it (NVFP4 `flashinfer_b12x` uncapped profiles a 49K
  pool < one 131K request and refuses to start; a `c > cap` point is just cap + queue).
- **PROVENANCE header** (the script stamps it): UTC date, client host + target, tool + backend +
  client image, server `/v1/models` (id + max_model_len), the *server's* launch flags + KV pool
  (`docker inspect`/`docker logs`, local targets only via `SERVER_NAME`), and the grid. The header
  is what makes a log self-describing and a number citable.
- **Same grid or no comparison** — CONC, PROMPTS_PER, IN/OUT, endpoint, and server caps all match,
  or the comparison is invalid.

## Kimi-K2.6 baselines (8× RTX PRO 6000 Blackwell SE, sm_120, PCIe-only TP=8)

Server deploys per the `deploy-kimi-k26-on-rtx-pro-6000` skill; serving config details live there.

### Master table — every recorded benchmark, both hosts (out-tok/s; 1024 in / 256 out, TP=8)

| # | Host | Engine / quant | Config (KV · mem · cap) | Method① | c1 | c8 | c16 | c32 | c64 | c128 | KV pool | Log (`bench.log.*`) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 3ed | SGLang **native venv** INT4 | bf16 · 0.85 · — | burst | 59.5 | 209.9 | — | — | 390.0⚠ | 330.3⚠ | 116K | `native-0611` |
| 2 | 3ed | SGLang-Docker INT4 | bf16 · 0.85 · — | burst | 59.7 | 206.7 | — | — | 388.7⚠ | 329.9⚠ | 116K | `docker-085-0611` |
| 3 | 3ed | SGLang-Docker INT4 | fp8 · 0.85 · — | burst | 59.4 | 208.2 | — | — | 398.5⚠ | 613.3⚠ | 232K | `docker-085fp8-0611` |
| 4 | 3ed | SGLang-Docker INT4 | fp8 · **0.90** · — | burst | 57.2 | **OOM-crash** | — | — | — | — | 376K | `docker-090fp8-crashed-0611` |
| 5 | 3ed | vLLM-Docker INT4 | bf16 · 0.95/131K · — | burst | 44.5 | 183.1 | — | — | 332.9⚠ | 474.2⚠ | 167K | `docker-vllm-095-131k-0611` |
| 6 | 3ed | SGLang-Docker INT4 (prod) | fp8 · 0.85 · — | burst | 59.3 | 207.1 | — | — | 396.1⚠ | 610.7⚠ | 232K | `prod-085fp8-0612` |
| 7 | 3ed | SGLang-Docker INT4 | fp8 · 0.85 · — | sustained② | 59.5 | 196.9 | — | — | 368.0 | 377.7 | 232K | `sglang-int4-fp8-085-0612` |
| 8 | 3ed | SGLang-Docker INT4 | bf16 · 0.85 · — | sustained② | 59.7 | 197.2 | — | — | 362.1 | 332.6③ | 116K | `sglang-int4-bf16-085-0612` |
| 9 | 3ed | vLLM-Docker INT4 | bf16 · 0.95/131K · — | sustained② | 44.4 | 177.3 | — | — | 313.2 | 326.6 | 170K | `vllm-int4-095-131k-0612` |
| 10 | 3ed | SGLang-Docker INT4 (prod) | fp8 · 0.85 · — | **canon** | 59.6 | 201.1 | 295.3 | **344.6** | 345.1 | 381.9 | 232K | `sglang-int4-fp8-085-satcurve-0612` (c1/c128 `…-c1c128-0612`) |
| 11 | 3ee | vLLM NVFP4 **marlin** | fp8 · 0.90/131K · **cap 16** | sustained④ | 54 | 173 | 238 | 242④ | 201④ | — | 309K | (in REFERENCE, A/B re-run) |
| 12 | 3ee | vLLM NVFP4 **b12x** | fp8 · 0.90/131K · **cap 16** | sustained④ | 38 | 145 | 169 | 195④ | 194④ | — | 211K | (in REFERENCE, A/B re-run) |
| 13 | 3ee | vLLM NVFP4 **marlin** | fp8 · 0.90/131K · uncapped | **canon** | 43.7 | 160.1 | 235.8 | 213.5/214.3⑤ | **291.1** | 294.9⑥ | 139K | `vllm-nvfp4-marlin-090-uncapped-satcurve-0612` (c1 `…-c1-0612`, c128 `…-c128-throttled-0613`) |
| 14 | 3ee | vLLM NVFP4 **b12x** | fp8 · 0.90/131K · cap 64⑦ | **canon** | 38.3 | 156.6 | 228.5 | 208.9⑤ | 279.0 | 278.0⑧ | 176K | `vllm-nvfp4-b12x-090-maxseqs64-satcurve-0612` (c1 `…-c1-0612`, c128 `…-c128-0613`) |
| 15 | 3ed | vLLM-Docker INT4 | **fp8** · 0.95/131K · — | **canon** | 44.0 | 175.8 | 238.3 | 258.4 | 292⑨ | 324.0 | 339K | `vllm-int4-fp8-095-131k-satcurve-0613` (+rerun, variance) |
| 16 | 3ee | vLLM NVFP4 **b12x** | fp8 · 0.90/131K · **cap 128** | **canon** | — | — | — | — | 273.9 | **310.3** | 166K | `vllm-nvfp4-b12x-090-maxseqs128-c64c128-0613` |

① **burst** = num_prompts 8/32/128/192 (2026-06-11 era) — high-concurrency cells ⚠ over-report
(never reached steady state; see the 613→377.7 case study). **sustained** = uniform `prompts_per=8`.
**canon** = sustained + `sglang-oai` endpoint + bridged client (the current script's defaults).
② sustained grid but native-`/generate` endpoint + `docker exec` client (pre-canon era).
③ bf16 c128 dip = KV pressure (164K needed > 116K pool), not compute.
④ `MAX_SEQS=16`: c32/c64 columns are 16-wide + queue, **not** true concurrency — compare only within
the capped pair.  ⑤ the reproducible c32 dip (both backends — vLLM scheduler regime, avoid ~c32).
⑥ marlin uncapped c128 = **294.9 @ ~108-wide** (139K pool holds ~108 of the 1280-tok reqs →
preemption; *not* a true 128-wide point — the earlier "not runnable" was a pre-measurement guess).
⑦ cap 64 is non-binding for a c≤64 grid (truly-uncapped b12x can't start: 49K pool < one 131K request).
⑧ cap-64 c128 = offered 128 / running 64 + 64-queue ⇒ **≡ its own c64** (278.0 ≈ 279.0) at a 64.5 s
median TTFT — the cap binds. **Row 16 (cap 128) is the genuine 128-wide b12x point: 310.3, +11% over
c64**; c64@cap-128 = 273.9 ≈ cap-64's 279 ⇒ c≤64 is cap-independent, so rows 14 + 16 are one curve.
⑨ vLLM INT4 **fp8 KV** needs the TRITON_MLA-patched image `vllm-openai-mla:v0.22.1`; stock
`vllm/vllm-openai:v0.22.1` OOMs at CUDA-graph capture (triton smem 102400 > 101376 — the same patch
NVFP4 needs). c64 is **regime-sensitive** (292 over 3 samples; one run hit 384 in a low-queue
regime), c128 = 324 reproduced exactly.
Cross-host c1 spot-checks (canon client): 3ed→3ee NVFP4 43.2–43.7; 3ee→3ed INT4 59.1–64.6 (path-
sensitive — see the client-path confound). Caddy-proxy A/B (host-net client): direct 64.6/347.4 vs
proxied 63.8/342.7 @ c1/c64.

- **INT4 QAT — canonical sweep** (uniform `prompts_per=8`, 1024 in / 256 out, measured 2026-06-12).
  out-tok/s @ c1/8/64/128:
  ⚠ the SGLang rows were measured on SGLang's **native `/generate`** (the script then used
  `--backend sglang`); the current script hits `/v1/completions` for cross-engine parity, so a
  refresh may shift them slightly (pending — folds into the next unified-grid re-run).
  - **SGLang INT4 fp8 KV 0.85 (production):** **59.5 / 196.9 / 368.0 / 377.7** — KV pool 232K.
  - SGLang INT4 bf16 KV 0.85:                **59.7 / 197.2 / 362.1 / 332.6** — KV pool 116K.
  - vLLM 0.22.1 INT4 0.95 util / 131K / bf16: **44.4 / 177.3 / 313.2 / 326.6** — KV pool 170K.
  Reading: fp8 ≈ bf16 through c64; fp8's doubled pool gives **+13.5% at c128** (377.7 vs 332.6 —
  bf16 dips below its own c64 under KV pressure). SGLang leads vLLM on throughput at every point,
  but vLLM's median TTFT at c128 is far lower (~13.5 s vs ~40 s) — a throughput-vs-latency trade.
- **vLLM INT4 fp8 KV — canonical sweep (3ed, measured 2026-06-13)**, out-tok/s @ c1/8/16/32/64/128:
  **44.0 / 175.8 / 238.3 / 258.4 / 292 / 324.0** — KV pool **339K**. Two operational facts: (1) **fp8
  KV needs the TRITON_MLA-patched image** `vllm-openai-mla:v0.22.1`; stock `vllm/vllm-openai:v0.22.1`
  dies at CUDA-graph capture with `triton OutOfResources: shared memory 102400 > 101376` (the *same*
  num_stages patch NVFP4 needs — vLLM INT4 only ever worked stock because the earlier baseline used
  **bf16** KV). (2) **c64 is regime-sensitive** — 3 samples cluster at ~292 (TTFT ~9.7 s) but one
  in-sweep run hit **384** (TTFT 1.1 s, a low-queue regime); c128 = 324 reproduced exactly. The curve
  is **still climbing at c128** (292→324, +11%), so vLLM-fp8's max knee is **> c128** for this shape
  (unlike SGLang INT4, which plateaus at ~c32). fp8 ~doubles the KV pool (339K vs bf16's 170K); a
  clean fp8-vs-bf16 *throughput* delta isn't available — the bf16 vLLM row is pre-canon path.
- **NVFP4 marlin-vs-b12x A/B** (vLLM-only; `MAX_SEQS=16`, grid c1/8/16/32/64 — **NOT comparable to
  the INT4 rows above**, different host + different grid + capped). out-tok/s @ c1/8/16/32/64
  (TP=8, 1024 in / 256 out, re-run 2026-06-12):
  - `--moe-backend marlin` (default): **54 / 173 / 238 / 242 / 201** — KV pool 309K.
  - `--moe-backend flashinfer_b12x`:  **38 / 145 / 169 / 195 / 194** — KV pool 211K.
  **Marlin wins every level** (+3…+43%, peak +24% @ c32) and gets more KV (b12x reserves more
  workspace): the box is PCIe-comm-bound at TP=8 (no NVLink), so the native-FP4 GEMM speedup never
  reaches end-to-end. Reproduce with:
  `MODEL_REPO=nvidia/Kimi-K2.6-NVFP4 MODEL_NAME=kimi-k2.6 CONC="1 8 16 32 64" SERVER_NAME=kimi-k26 bash scripts/bench_sweep.sh`.
- **Saturation curve (SGLang INT4 fp8 0.85, measured 2026-06-12 — current canon path: `sglang-oai`
  endpoint + bridged client)**, out-tok/s @ c8/16/32/64: **201 / 295 / 345 / 345** (median TTFT
  3.7 s / 2.0 s / 2.3 s / **24 s**). The machine saturates at **~c32** for this 1024/256 shape:
  c16→c32 still gains **+17%**, c32→c64 gains +0.2% while TTFT explodes 10× (pure queueing). So a
  server-side `MAX_SEQS=16` cap *under-utilizes* this box (~17% left on the table) — cap to bound
  KV, not for throughput; and offering >c32 only buys latency. (First data set on the refreshed
  canon path — its c8 ≈ 201 vs the old native-endpoint 196.9 confirms path effects shrink at c≥8.)
- **NVFP4-marlin UNCAPPED saturation curve (3ee, `MAX_SEQS` removed, measured 2026-06-12, canon
  path)**, out-tok/s @ c8/16/32/64: **160 / 236 / 213 / 291** — **non-monotonic, and the c32 dip
  REPRODUCES** (213.5 then 214.3 on an immediate re-run; TTFT ~8.6–9.7 s at c32 vs 0.9 s at c16 —
  a scheduler/batching regime effect, not noise). c128 (added 2026-06-13) = **294.9 @ ~108-wide** —
  the uncapped 139K pool holds only ~108 of the 1280-tok reqs, so vLLM preempts and c128 ≈ c64
  (294.9 vs 291.1); **marlin is saturated by ~c64** (its max knee) and 294.9 is *not* a true 128-wide
  point. Two conclusions: (1) **INT4 still wins outright** — NVFP4's best (291 @
  c64) is below INT4's c32 plateau (345); (2) avoid operating NVFP4-marlin near c32 (use ≤c16 or
  ~c64).
- **NVFP4-b12x curve (3ee, `MAX_SEQS=64` — non-binding for the c≤64 grid, measured 2026-06-12,
  canon path)**, out-tok/s @ c8/16/32/64: **157 / 229 / 209 / 279**. Two findings: (1) **the c32
  dip is backend-independent** — same shape as marlin's (213/214), so it's a vLLM
  scheduler/chunked-prefill regime effect on this NVFP4 config, not a MoE-kernel artifact;
  (2) **marlin > b12x at every point even at unbound operating points** (160/236/214/291 vs
  157/229/209/279 — +2…4%), confirming the capped A/B's verdict with a narrower margin. Provenance
  caveat: truly-uncapped b12x **cannot start** at 131K max-model-len (see next bullet), so this
  curve ran `MAX_SEQS=64` while marlin's ran uncapped — both schedulers unbound at every tested
  concurrency, so the per-point comparison stands. **c128 (added 2026-06-13):** at the curve's own
  `MAX_SEQS=64`, c128 = **278.0 ≈ c64** (the cap binds — 64 running + 64 queued, 64.5 s median TTFT;
  no new throughput, a textbook offered-vs-running demo). Re-run at **`MAX_SEQS=128`** (cap raised to
  the top of the sweep; the 166K pool ≥ the 164K c128 needs, so it boots and runs **true 128-wide**)
  gives **310.3 — +11% over c64** (c64 reproduces at 273.9 ≈ 279 ⇒ c≤64 is cap-independent, so the
  two configs form one curve). So b12x's **max knee is > c64** (like vLLM-INT4-fp8), and cap-64 *hid*
  that gain behind the queue — see SKILL "Finding the saturation knees."
- **`--max-num-seqs` changes the KV pool, not just scheduling** (vLLM): its memory profiling
  reserves activation workspace per max-seqs. Measured on the same NVFP4 config: marlin capped-16 →
  **309K**-token pool; b12x capped-16 → **211K**; b12x capped-64 → **175K**; marlin uncapped →
  **139K**; **b12x uncapped → 49K, below one 131K-token request, so vLLM refuses to start**
  (`ValueError: … larger than the available KV cache memory`). A cap is a KV-capacity *increaser*
  and a concurrency *limiter* at once — account for both when comparing pools, and expect
  uncapped+b12x+long-context to be unservable on 96 GB GPUs at util 0.90.
- **Cross-host (3ed=INT4 ↔ 3ee=NVFP4, same LAN, identical hardware), verified 2026-06-12**:
  3ed→3ee NVFP4 **43 tok/s** @ c1; 3ee→3ed INT4 **65 tok/s** @ c1 — ≈ local numbers; the LAN adds
  ~nothing at low concurrency. Method: `TARGET_HOST=<peer-lan-ip>`; `MODEL_REPO` is the *client-side*
  tokenizer source (same Kimi vocab in both repos, so either works).
- **Historical logs** (3ed, `/data/devops/kimi/`): `bench.log.native-0611` (retired native venv),
  `bench.log.docker-085-0611`, `bench.log.docker-085fp8-0611`, `bench.log.docker-090fp8-crashed-0611`
  (the mem-fraction-0.90 OOM), `bench.log.docker-vllm-095-131k-0611`, `bench.log.prod-085fp8-0612`
  (short-burst era), the canonical trio `bench.log.{sglang-int4-fp8-085,sglang-int4-bf16-085,vllm-int4-095-131k}-0612`,
  `bench.log.sglang-int4-fp8-085-satcurve-0612` (INT4 c8–c64 saturation curve, canon path),
  `bench.log.vllm-nvfp4-marlin-090-uncapped-satcurve-0612` (NVFP4 marlin uncapped curve + c32-dip
  rerun), and `bench.log.vllm-nvfp4-b12x-090-maxseqs64-satcurve-0612` (NVFP4 b12x curve).
  **Gap-fills + 2026-06-13 runs:** `bench.log.sglang-int4-fp8-085-c1c128-0612`,
  `bench.log.vllm-nvfp4-{marlin-090-uncapped,b12x-090-maxseqs64}-c1-0612` (c1 points);
  `bench.log.vllm-nvfp4-marlin-090-c128-throttled-0613` (marlin c128, ~108-wide);
  `bench.log.vllm-int4-fp8-095-131k-{satcurve,c64c128-rerun,c64-variance}-0613` (vLLM INT4 **fp8 KV**
  curve + c64 variance, **patched image** `vllm-openai-mla:v0.22.1`);
  `bench.log.vllm-nvfp4-b12x-090-maxseqs64-c128-0613` (b12x cap-64 c128 ≡ c64) and
  `bench.log.vllm-nvfp4-b12x-090-maxseqs128-c64c128-0613` (b12x cap-128, true 128-wide).

## Kimi-K3 baselines (llama.cpp, CPU+GPU hybrid, single 8x RTX PRO 6000 Blackwell SE host)

> Read "The SSE keep-alive trap" below before benchmarking any **slow** server, with any engine —
> unpatched, the client silently reports a saturation curve that is really its own parse failures.

### The SSE keep-alive trap (client bug — affects ANY slow server, not just Kimi-K3)

`sglang.bench_serving`'s streaming parsers do this per line: skip blanks, strip a `data: ` prefix,
special-case `[DONE]`, then `json.loads()` whatever is left. An **SSE comment line — a bare `:` —
passes every one of those guards** and reaches `json.loads`, raising

```
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
```

which the client records as a **failed request** and which drops the connection (the server then
logs `W srv stop: cancel task`, its client-disconnect path — which is why this looked like a server
problem). SSE comments are spec-legal keep-alives (W3C SSE: a line starting with `:` is ignored),
and **llama.cpp emits them while a request waits during slow prefill**. Confirmed by capturing the
raw stream under load: `cat -A` shows `:$` lines interleaved with the `data: {...}` lines.

Why it hid for so long: keep-alives are only emitted when there is a *gap* between tokens. A fast,
GPU-resident server never sends one, so the bug is invisible against Kimi-K2.6 and against a small
model (verified: Qwen2.5-0.5B on the same image, same `--parallel 32 --ctx-size 65536` shape, same
bridged client — 32/32, zero drops; and still 16/16 when deliberately slowed with `-ngl 0
--threads 1`). It appears only on slow/contended servers, and **scales with concurrency**, because
longer waits mean more keep-alives — which is exactly what makes it masquerade as a saturation limit.

Isolate it the same way if you ever suspect it: hold the server and the sweep point fixed and change
only the client (stock vs patched). Unpatched, most requests are recorded as failures and throughput
collapses; patched, the same point returns N/N.

**The fix is now automatic**: `scripts/sse_keepalive_patch.py` (idempotent) is mounted and applied
inside the client container by `bench_sweep.sh` before every run. If it ever prints
`WARNING: no stream loop matched`, the client version changed — **stop and re-anchor the patch**,
because unpatched results against a slow server are silently wrong rather than obviously broken.

Two explanations that look strong when you hit this, and are **wrong** — don't spend time on them:
- *Prompt-cache thrashing.* The server does log `making room for prompt cache entry, removing oldest
  entry (size = 1364 MiB)` continuously (478 evictions in one c8 run — entries are ~1.36 GB against
  llama.cpp's `--cache-ram` default of 8192 MiB, so only ~6 fit). Real, but unrelated: with the
  client fixed, **both `--cache-ram 0` and the default give 32/32**.
- *Client timeout / request cancellation cascade.* `BENCH_AIOHTTP_TIMEOUT_SECONDS` is 6 h with no
  sub-timeouts, and with `return_exceptions=True` instrumentation no `CancelledError` ever appeared —
  each request fails independently on its own parse error.

### Valid measurements (fixed client)

Server: `unsloth/Kimi-K3-GGUF` UD-Q2_K_XL (802 GB, 19 shards) + `mmproj-BF16.gguf`,
`BUILD_SOURCE=fork` (`unslothai/llama.cpp` PR #70 @ `883f2c9b`), `--load-mode none`,
`--cache-type-k/v f16`, `--numa distribute` (host `numa_balancing=0`), `--ctx-size 65536
--parallel 32`, `--threads 64`. `--fit` places ~92-94 GB on each of the 8 GPUs. Cold load ~18.7 min.
Grid `IN=1024 OUT=256`, `PROMPTS_PER=4`, `sglang-oai`, `MODEL_REPO=moonshotai/Kimi-K3`.

**The saturation curve** (`--cache-ram 0`, log `bench.log.q2kxl-fit-p32-cacheram0-0904`, 2026-09-04).
Every point is **N/N successful** — that is the gate for trusting any row here, and the reason the
`out tok/s` column is meaningful again (abandoned requests still count their wall time into
`Benchmark duration`, so partial-success points silently deflate throughput):

| Conc | Successful | Duration (s) | out tok/s | Mean TTFT (ms) | Mean TPOT (ms) | Median ITL (ms) |
|---|---|---|---|---|---|---|
| c1  | **4/4**     | 188.4  | 5.43      | 7,109   | 156.8   | 150.4   |
| c4  | **16/16**   | 408.5  | 10.03     | 29,547  | 284.7   | 277.3   |
| c8  | **32/32**   | 602.9  | 13.59     | 37,560  | 443.5   | 419.0   |
| c16 | **64/64**   | 1117.2 | **14.67** | 50,019  | 897.4   | 765.9   |
| c32 | **128/128** | 2725.4 | 12.02     | 157,956 | 2,042.8 | 1,173.8 |

**Min knee = c1. Max knee = c16.** Throughput scales 5.43 → 10.03 → 13.59 → 14.67 (gains 1.85x →
1.35x → 1.08x), then **falls to 12.02 at c32** — an 18% regression, not a plateau. That distinction
matters: the curve is emphatically *not* still climbing at c32, so c16 is a real ceiling rather than
a `--parallel 32` cap misread as one. TPOT degrades from the very first step (156.8 → 284.7 ms at
c4), so there is no flat-latency region beyond c1 and the latency-optimal cap is c1.

**Put a production cap in [c1, c16] and never above c16** — past it you lose throughput *and*
latency simultaneously (c32 costs 18% throughput, 3.2x TTFT and 2.3x TPOT versus c16).

**Recommended `--parallel 16`, not 32** (deployment conclusion): 32 slots measurably hurt, and at a
fixed `--ctx-size 65536` dropping to 16 also doubles per-slot context (2048 → 4096 tokens), which
this 1024-in/256-out shape was already close to. Caveat: these points were all measured *on* a
32-slot server, so c16-on-a-16-slot-server may differ slightly; the direction is solid, the exact
peak is worth re-measuring if it matters.

**Prefill vs decode — decode-bound at this shape.** At c1, prefill ≈ 1024 tok / 7.11 s ≈ **144 tok/s**
and decode ≈ 1/156.8 ms ≈ **6.4 tok/s**; per request that is ~7 s of prefill against ~40 s of decode,
about **1:5.6**. Server `prompt eval` lines agree (~120-138 tok/s at low concurrency, degrading to
~35 tok/s per slot at c32). Boundedness is shape-dependent — sweep `IN=4096 OUT=16` vs `IN=128
OUT=2048` to classify the box rather than this grid.

**Prompt-cache A/B at c8** (both 32/32, so the setting never affected drops — the cleanest
confirmation that the client bug was the entire story):

| Conc | Successful | Duration (s) | out tok/s | Mean TTFT (ms) | Mean TPOT (ms) | server config |
|---|---|---|---|---|---|---|
| c8 | 32/32 | 1044.8 | 7.84 | 126,134 | 529.1 | default `--cache-ram 8192` |
| c8 | 32/32 | 903.2  | 9.07 | 12,328  | 836.1 | `--cache-ram 0` |

On *this* grid `--cache-ram 0` wins (+16% out tok/s, TTFT 12 s vs 126 s) because `random-ids`
prompts share no prefix: the cache can never hit, so its 317 evictions of ~1.36 GB each are pure
overhead. **Do not generalise that to production** — a real workload with shared system prompts or
multi-turn history is exactly what the cache exists for. Benchmark with the cache off to measure the
box; leave it on (default) to serve users, and re-measure with a prefix-sharing dataset for the real
answer.

⚠ **`--ctx-size` is the TOTAL across slots, not per-slot** — `--ctx-size 65536 --parallel 32` gives
2048 tokens/slot. Raising `--parallel` at fixed `--ctx-size` costs **no extra KV memory** (it only
re-partitions), but it does cap per-request context; a long-context workload needs `--ctx-size`
raised proportionally.

**Single-stream decode is CPU-offload-bound, not GPU-bound** — ~6.5 tok/s is far below what 8x RTX
PRO 6000 Blackwell does with a fully GPU-resident model (compare Kimi-K2.6's TP=8 numbers above,
hundreds of tok/s). The CPU-resident routed-expert compute (AMX/AVX-512, cross-NUMA) is the
bottleneck at c1, before concurrency is a factor. Prefill runs ~120-138 tok/s (server `prompt eval`
lines), so at this 1024-in/256-out shape decode dominates prefill roughly 5:1.

### 2026-09-05 follow-ups: micro-batch size, all-VRAM quants (same grid, `--cache-ram 0`)

All on the same 3ee box, same client, IN=1024 OUT=256, PROMPTS_PER=4, every point N/N successful.
Logs in `/data/devops/kimi-k3/bench.log.*-0905*`. Server details and the quant gates behind each
row: the `deploy-kimi-k3-on-rtx-pro-6000` skill's REFERENCE.md ("Where the time goes", "All-VRAM
quants", "Quant gate").

**E1 — hybrid UD-Q2_K_XL with `-b 4096 -ub 4096`** (baseline above used the default `-ub 512`;
`--parallel 16` instead of 32 — irrelevant at c ≤ 8):

| Conc | out tok/s | Mean TTFT (ms) | Mean TPOT (ms) | vs baseline |
|---|---|---|---|---|
| c1 | 5.82 | 4,668 | 154.1 | TTFT −34 % |
| c4 | 10.16 | 15,011 | 336.4 | TTFT −49 %, TPOT +18 % |
| c8 | 12.77 | 22,353 | 540.8 | TTFT −40 %, TPOT +22 %, tput −6 % |

Prefill in hybrid mode is bound by the per-micro-batch copy of every CPU-resident expert tensor to
GPU0 (~100 GiB, ~4.4 s), so one micro-batch per prompt instead of two is the whole effect; bigger
prefill chunks stall decode a little longer, hence the TPOT rise under load.

**E4 — UD-IQ2_XXS, all weights on GPU** (fork-lip image, `-b/-ub 2048 --fit-target 6144`, `--parallel 16`):

| Conc | Successful | Duration (s) | out tok/s | Mean TTFT (ms) | Mean TPOT (ms) | Median ITL (ms) |
|---|---|---|---|---|---|---|
| c1  | 4/4     | —      | 10.77     | 5,560   | 71.4  | 70.9  |
| c4  | 16/16   | —      | 24.26     | 7,874   | 134.6 | —     |
| c8  | 32/32   | —      | **25.33** | 25,080  | 218.5 | —     |
| c16 | 64/64   | 932.2  | 17.58     | 56,807  | 690.4 | 435.5 |
| c32 | 128/128 | 1854.6 | 17.67     | 243,027 | 775.2 | 445.7 |

**Max knee c4–c8 (≈25 tok/s), then a regression** — the mirror image of the hybrid's c16 peak. With
every expert GPU-resident, decode is 2.2x faster (71 vs 157 ms/token) but the box becomes
**prefill-queue-bound**: llama.cpp's K3 prefill path runs ~185 tok/s plus ~1.4 s fixed per prompt,
so at c16+ prompts queue for minutes. Production cap for this config: **c4–c8**. Quality cost of
this quant: KLD 0.370 vs Q2_K_XL, 84.6 % same-top-token (the skill's "Quant gate").

**E5 — `UD-Q2_K_XL-REAP770` (Q2_K_XL with the 14 % least-used experts sliced off, 697 GiB), all
weights on GPU** (fork-lip image, `-b/-ub 2048 --fit-target 6144`, `--parallel 16`; log
`bench.log.q2kxl-reap770-allvram-p16-ub2048-cacheram0-0905`):

| Conc | Successful | Duration (s) | out tok/s | Mean TTFT (ms) | Mean TPOT (ms) | Median ITL (ms) |
|---|---|---|---|---|---|---|
| c1  | 4/4     | —      | 7.44      | 3,640   | 120.7 | —     |
| c4  | 16/16   | —      | 12.64     | 14,116  | 262.2 | —     |
| c8  | 32/32   | —      | 15.79     | 18,293  | 436.4 | —     |
| c16 | 64/64   | —      | 17.87     | 37,978  | 748.8 | —     |
| c32 | 128/128 | 1802.8 | **18.18** | 225,207 | 788.7 | 561.1 |

Same shape as the hybrid (still climbing at c32) but 1.2–1.5x its throughput and half its TTFT at
c1–c4; slower per token than IQ2_XXS (IQ2_XS expert kernels: 121 vs 71 ms at c1) yet it batches
better and keeps near-reference quality (KLD 0.047, 95.4 % same-top-token). Practical cap:
**c8 (latency) to c16 (throughput)**; TTFT past c8 is prompt queueing.

**E5b — REAP-770 re-swept all-GPU (2026-09-06, `--fit-target 4096`, **8 slots** = the deployed
throughput profile; log `bench.log.q2kxl-reap770-allvram-p8-fit4096-ub2048-cacheram0-0906`; GPUs held
735,528 MiB, i.e. every weight on GPU — the E5 curve above had ~20 GiB of experts spilled to CPU):**

| Conc | Successful | out tok/s | Mean TTFT (ms) | Mean TPOT (ms) |
|---|---|---|---|---|
| c1  | 4/4     | 10.45     | 3,224   | 83.4  |
| c4  | 16/16   | 19.55     | 13,213  | 153.5 |
| c8  | 32/32   | **21.93** | 23,685  | 272.9 |
| c16 | 64/64   | 21.75     | 97,659  | 316.2 |
| c32 | 128/128 | 21.99     | 257,893 | 322.8 |

c16 and c32 run 8-wide behind the slot cap (flat throughput, TTFT climbing linearly — the queueing
signature), so the curve's real knee is at the cap: **c8 ≈ 22 tok/s**, 1.4x the spilled E5 numbers and
now level with IQ2_XXS (25.3 at c8, 10.8 at c1). Use this table for REAP-770, not E5.

**Three configs side by side (out tok/s / mean TTFT s / mean TPOT ms):**

| Conc | hybrid UD-Q2_K_XL (09-04) | all-VRAM UD-IQ2_XXS | all-VRAM REAP-770 |
|---|---|---|---|
| c1  | 5.43 / 7.1 / 157 | **10.77** / 5.6 / **71** | 10.45 / **3.2** / 83 |
| c4  | 10.03 / 29.5 / 285 | **24.26** / **7.9** / **135** | 19.55 / 13.2 / 154 |
| c8  | 13.59 / 37.6 / 444 | **25.33** / 25.1 / **219** | 21.93 / **23.7** / 273 |
| c16 | 14.67 / 50.0 / 897 | 17.58 / 56.8 / 690 | 21.75 / 97.7 / 316 (8-slot cap) |
| c32 | 12.02 / 158 / 2043 | 17.67 / 243 / 775 | 21.99 / 258 / 323 (8-slot cap) |

(REAP-770 column = the all-GPU re-sweep at 8 slots; the hybrid column is the 09-04 `-ub 512` curve —
its `-ub 4096` re-sweep is below.)

**E1b — hybrid UD-Q2_K_XL re-swept with `-b/-ub 4096` (2026-09-06, 16 slots, `--fit` placement,
log `bench.log.q2kxl-hybrid-p16-ub4096-cacheram0-0906`):**

| Conc | Successful | out tok/s | Mean TTFT (ms) | Mean TPOT (ms) | vs `-ub 512` (09-04) |
|---|---|---|---|---|---|
| c1  | 4/4     | 5.82      | 4,645   | 154.4 | TTFT −35 % |
| c4  | 16/16   | 11.80     | 14,436  | 283.7 | TTFT −51 %, tput +18 % |
| c8  | 32/32   | **15.96** | 22,172  | 416.0 | TTFT −41 %, tput +17 % |
| c16 | 64/64   | 15.22     | 49,965  | 858.7 | tput +4 %, TTFT ≈ |
| c32 | 128/128 | 15.69     | 263,305 | 904.0 | tput +31 %, TTFT +67 % |

With the larger micro-batch the hybrid's throughput knee moves from c16 to **c8 (16.0 tok/s)**, and
c16/c32 flatten at ~15.5 instead of regressing — fewer expert copies per prompt also means less decode
stall per served token. TTFT beyond c8 is still prompt queueing. Production cap for the hybrid: c8.
This supersedes the 09-04 curve as the hybrid's reference.

**Speculative decoding (E6, on REAP-770, all at `--parallel 4`):** `--spec-type ngram-mod` gave
+5 % single-stream on a prompt that copies its own input (rewrite task: 9.93 → 10.48 tok/s, 36 % of
drafted tokens accepted, identical greedy output) and −2–3 % on free-form prompts (verification
overhead, no drafts). The larger effect was the slot count: no-spec c1 went from 7.44 tok/s / TPOT
121 ms at `--parallel 16` to **8.99 tok/s / TPOT 98 ms at `--parallel 4`** (log
`bench.log.q2kxl-reap770-p4-nospec-c1-0905`) — size the slot count to the real concurrency. **Never benchmark ngram
speculation with `random-ids` prompts**: the model's output on random tokens degenerates into
repetition, the drafter accepts 100 % of it and the client reports 26.5 tok/s / TPOT 24 ms / ITL 0.03 ms
(log `bench.log.q2kxl-reap770-p4-ngram-mod-c1-0905`) — a measurement of the degenerate output, not of
serving. DSpark (RadixArk draft, converted) needs two fixes to pay: the draft on the GPU holding the target's
`output.weight` (`--spec-draft-device CUDA7`) and the deploy skill's `kimi-k3-rs-rollback.patch`
(bounded recurrent-state rollback for KIMI_K3). With both, on the IQ2_XXS target at 4 slots: probes
12.8 → 15.7 tok/s on free-form prompts (+23 %), 12.9 → 22.2 on a copy-heavy prompt (+72 %); bench c1
13.98 tok/s / TPOT 49 ms (`bench.log.iq2xxs-p4-dspark-rsrollback-c1c4-0905`) vs 10.14 tok/s / TPOT 78 ms
without speculation (`bench.log.iq2xxs-p4-nospec-c1c4-0905`); at c4 it loses (14.9 tok/s vs
18.30 tok/s, TPOT 221 vs 135 ms). Without the rollback patch the same draft was −5 to −15 % on free-form
text. Root cause, memory math and caveats in the deploy skill's REFERENCE.md.


**Prefill knob A/Bs (IQ2_XXS, 4 slots, no draft, same binary; 2026-09-05 evening):**

| config | c1 tok/s / TTFT / TPOT | c4 tok/s / TTFT / TPOT |
|---|---|---|
| defaults (CUDA graphs on) | 10.14 / 5.44 s / 77.7 ms | 18.30 / 21.6 s / 134.5 ms |
| `GGML_CUDA_DISABLE_GRAPHS=1` | 8.63 / 5.83 s / 93.5 ms | 18.05 / 17.4 s / 154.0 ms |
| `GGML_CUDA_GRAPH_OPT=1` | 10.03 / 5.50 s / 78.5 ms | 18.31 / 17.4 s / 151.0 ms |

Graphs are worth ~17 % of decode; neither knob moves prefill. Logs `bench.log.iq2xxs-p4-nospec-*-c1c4-0905`.

**Interactive profile (REAP-770, 2 slots x 8192, DSpark + rollback, draft on GPU 7, fork `…-lip-rsrb`):**
c1 **12.96 tok/s, TTFT 3.95 s, TPOT 61.9 ms**; c2 14.01 tok/s, TTFT 5.9 s, TPOT 113 ms
(`bench.log.reap770-p2-dspark-rsrollback-c1c2-0905`). Versus the no-draft REAP-770 at 4 slots
(8.99 tok/s, TPOT 98 ms): +44 % / −37 %.

**Why REAP-770 looked slower than IQ2_XXS in the E5 sweep (121 vs 71 ms TPOT at c1):** placement,
not kernels. The 6 GiB fit margin left ~20 GiB of REAP-770's experts on the CPU (nvidia-smi total
693.6 GiB < 697 GiB of weights); with `--fit-target 4096` everything is on GPU and decode is ~86
ms/token at 8 slots. A K3-shaped `test-backend-ops perf -o MUL_MAT_ID` (896 experts, 16 used,
3584x3072) puts IQ2_XS and IQ2_XXS within 5 % at batch 1 (30.5 vs 29.1 µs) and shows the expert
matmul scaling linearly with batch up to n=16 (no batching gain) — the structural reason aggregate
throughput saturates near 18–25 tok/s on this model. Re-sweep REAP-770 with the 4096 margin before
quoting its curve.

## Proxy overhead (Caddy TLS + Bearer), measured 2026-06-12

Same 3ed INT4 server, same client, two paths — raw LAN IP vs `--base-url https://3ed.<tailnet>` +
`OPENAI_API_KEY` (full TLS + bearer gate; Caddy upstreams to the LAN IP, which the kernel
short-circuits — no wire hop):

| Metric | Direct (LAN IP) | Through Caddy | Δ |
|---|---|---|---|
| c1 out-tok/s | 64.64 | 63.84 | −1.2% |
| c1 median TTFT | 123.7 ms | 140.3 ms | **+16.6 ms** |
| c1 median TPOT | 14.94 ms | 15.07 ms | +0.9% |
| c64 out-tok/s | 347.4 | 342.7 | −1.3% |
| c64 median TPOT | 90.4 ms | 96.4 ms | +6.6% |

**Conclusion**: ~1% throughput, ~15 ms added TTFT at c1 (TLS handshake + bearer check + proxy hop —
per-connection, amortized by keep-alive; invisible inside c64's ~23 s queueing). The authenticated
proxy path is fine for throughput work; the raw LAN IP is marginally lower-latency.

## Troubleshooting

- **Header prints, zero metrics, instant SWEEP_DONE** → a host INPUT firewall (e.g. a legacy
  loopback-lock) is dropping the bridged client — its packets source from the docker bridge
  (`172.17.x`), not the LAN CIDR, so LAN-allowlist/catch-all-DROP rules kill it. Fix the policy (the
  reference deploy has **no** host firewall — it binds `0.0.0.0` (formerly LAN-IP-only)), don't host-net the client.
- **`<repo> not in HF cache`** → the tokenizer repo must be cached on the **client** host
  (`$HF_HOME/hub/models--<org>--<name>` with `refs/main`); any same-tokenizer repo works.
- **`/v1/models` shows `?` in the header** → server down / wrong `TARGET_HOST`/`PORT` (the header
  curl runs host-side and is also a reachability probe).
- **Summary rows all `?`** → requests erroring: `MODEL_NAME` must equal the server's served model
  id; check the per-point grep lines for `error`/`Traceback`.
- **Numbers look too good at high concurrency** → short-burst run (see Methodology) or a stale
  comparison across different endpoints / `MAX_SEQS`.
