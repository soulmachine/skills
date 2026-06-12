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
  `prompts_per=8` ⇒ 8/64/512/1024 prompts at c1/8/64/128). **Case study**: the 2026-06-11
  short-burst sweeps (num_prompts 8/32/128/192) reported SGLang fp8 c128 = **613 tok/s**; the
  sustained grid measures **377.7** — 192 prompts at c128 never reached steady state, so the burst
  over-reported by +62%. High-concurrency numbers from short runs are not baselines.
- **`MAX_SEQS` (server `--max-num-seqs`) changes column meaning.** Against a `MAX_SEQS=16` server,
  a "c64" point is *16 concurrent with a 48-deep queue* — throughput saturates and queueing latency
  explodes, by design. Valid for A/Bs at a fixed operating point (that's why the NVFP4 A/B used it),
  invalid to compare against uncapped tables.
- **PROVENANCE header** (the script stamps it): UTC date, client host + target, tool + backend +
  client image, server `/v1/models` (id + max_model_len), the *server's* launch flags + KV pool
  (`docker inspect`/`docker logs`, local targets only via `SERVER_NAME`), and the grid. The header
  is what makes a log self-describing and a number citable.
- **Same grid or no comparison** — CONC, PROMPTS_PER, IN/OUT, endpoint, and server caps all match,
  or the comparison is invalid.

## Kimi-K2.6 baselines (8× RTX PRO 6000 Blackwell SE, sm_120, PCIe-only TP=8)

Server deploys per the `deploy-kimi-k26-on-rtx-pro-6000` skill; serving config details live there.

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
- **NVFP4 marlin-vs-b12x A/B** (vLLM-only; `MAX_SEQS=16`, grid c1/8/16/32/64 — **NOT comparable to
  the INT4 rows above**, different host + different grid + capped). out-tok/s @ c1/8/16/32/64
  (TP=8, 1024 in / 256 out, re-run 2026-06-12):
  - `--moe-backend marlin` (default): **54 / 173 / 238 / 242 / 201** — KV pool 309K.
  - `--moe-backend flashinfer_b12x`:  **38 / 145 / 169 / 195 / 194** — KV pool 211K.
  **Marlin wins every level** (+3…+43%, peak +24% @ c32) and gets more KV (b12x reserves more
  workspace): the box is PCIe-comm-bound at TP=8 (no NVLink), so the native-FP4 GEMM speedup never
  reaches end-to-end. Reproduce with:
  `MODEL_REPO=nvidia/Kimi-K2.6-NVFP4 SERVED_NAME=kimi-k2.6 CONC="1 8 16 32 64" SERVER_NAME=kimi-k26 bash scripts/bench_sweep.sh`.
- **Cross-host (3ed=INT4 ↔ 3ee=NVFP4, same LAN, identical hardware), verified 2026-06-12**:
  3ed→3ee NVFP4 **43 tok/s** @ c1; 3ee→3ed INT4 **65 tok/s** @ c1 — ≈ local numbers; the LAN adds
  ~nothing at low concurrency. Method: `TARGET_HOST=<peer-lan-ip>`; `MODEL_REPO` is the *client-side*
  tokenizer source (same Kimi vocab in both repos, so either works).
- **Historical logs** (3ed, `/data/devops/kimi/`): `bench.log.native-0611` (retired native venv),
  `bench.log.docker-085-0611`, `bench.log.docker-085fp8-0611`, `bench.log.docker-090fp8-crashed-0611`
  (the mem-fraction-0.90 OOM), `bench.log.docker-vllm-095-131k-0611`, `bench.log.prod-085fp8-0612`
  (short-burst era) and the canonical trio `bench.log.{sglang-int4-fp8-085,sglang-int4-bf16-085,vllm-int4-095-131k}-0612`.

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
  reference deploy uses a structural LAN-IP bind with **no** firewall), don't host-net the client.
- **`<repo> not in HF cache`** → the tokenizer repo must be cached on the **client** host
  (`$HF_HOME/hub/models--<org>--<name>` with `refs/main`); any same-tokenizer repo works.
- **`/v1/models` shows `?` in the header** → server down / wrong `TARGET_HOST`/`PORT` (the header
  curl runs host-side and is also a reachability probe).
- **Summary rows all `?`** → requests erroring: `SERVED_NAME` must equal the server's served model
  id; check the per-point grep lines for `error`/`Traceback`.
- **Numbers look too good at high concurrency** → short-burst run (see Methodology) or a stale
  comparison across different endpoints / `MAX_SEQS`.
