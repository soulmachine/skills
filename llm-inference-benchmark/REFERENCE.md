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
