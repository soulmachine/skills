# Reference — Kimi-K3 (GGUF, llama.cpp) on RTX PRO 6000 Blackwell

## Model facts
- Repo [`unsloth/Kimi-K3-GGUF`](https://huggingface.co/unsloth/Kimi-K3-GGUF) (public, not gated).
  171 files: pure GGUF shards + README + `.gitattributes` — **no HF-format tokenizer** (see
  "Tokenizer for benchmarking" below). Nine quant subdirectories as of 2026-09: `UD-IQ1_S`,
  `UD-IQ1_M`, `UD-IQ2_XXS`, `UD-Q1_0`, `UD-TQ1_0`, `UD-TQ2_0`, `UD-Q2_K_XL` (19 shards, ~861 GB —
  the only one this skill has run end-to-end), `UD-Q4_K_XL` (32 shards), `UD-Q8_K_XL` (34 shards,
  largest — almost certainly exceeds any single 8x96GB-VRAM-plus-1TB-RAM host's combined
  VRAM+RAM; the sizing gate in `download.sh` will say so before wasting a download attempt).
- Original repo [`moonshotai/Kimi-K3`](https://huggingface.co/moonshotai/Kimi-K3) (public, not
  gated, confirmed 2026-09-03) — 2.8T-parameter MoE, hybrid Kimi Delta Attention (linear) + MLA
  (full) per-layer, 896 experts (16 active), native MoonViT-3d vision tower, 1M context. Custom
  tiktoken-based tokenizer (`tiktoken.model` + `tokenization_kimi.py`, `trust_remote_code`), same
  pattern as Kimi-K2/K2.6.

## Build

### The two `BUILD_SOURCE` repos
- **`fork`** (default, vision): `unslothai/llama.cpp`, branch `kimi-k3-vision-only`, PR
  [#70](https://github.com/unslothai/llama.cpp/pull/70) "kimi-k3 : the MoonViT-3d vision tower and
  full-size loading fixes." **Open, unmerged** as of 2026-09-03 (`mergeable_state: unstable` —
  expect rebase conflicts against upstream as mainline moves). Pinned in `build_image.sh` to head
  commit `883f2c9ba78f3847148454adf025da29385fff3e`. This is PR #70's *second* attempt — an earlier
  PR #48 was closed/superseded by it, so treat this pin as similarly liable to be superseded again;
  re-check the PR before bumping.
- **`mainline`** (text-only): `ggml-org/llama.cpp`, Kimi-K3 text model merged in
  [#26185](https://github.com/ggml-org/llama.cpp/pull/26185) "model: add Kimi-K3 text model",
  commit `ad1de39e0708e3ced9c71bb3c82d93a2c046a73f` (2026-08-15). Reuses/extends the existing
  `KIMI_LINEAR` graph infra but needed real new code, not just an arch-tag reuse (K2's
  `KIMI_LINEAR` graph "cannot safely represent K3 unchanged" — ggml-org/llama.cpp#26041); bumped
  `LLAMA_MAX_EXPERTS` 512->1024 for K3's 896. Vision tracking issue:
  [ggml-org/llama.cpp#28264](https://github.com/ggml-org/llama.cpp/issues/28264), open, unmerged
  — **switch `BUILD_SOURCE` to `mainline` once this lands** to drop the fork dependency.
- One K3-specific op, `ggml_dsv4_hc_pre`, is CPU+CUDA only as of the fork's current state — no
  Metal/Vulkan backend. Not relevant on this hardware target (CUDA), noted here in case this skill
  is ever adapted for a different backend.

### Build flags (`build_image.sh`)
- `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120` — sm_120 = compute capability 12.0 (RTX PRO 6000
  Blackwell / GB202). Same convention kimi-k26's stock images target, but here it's a source build
  flag, not an image tag choice.
- `-DGGML_NATIVE=OFF` plus explicit `-DGGML_AVX512=ON -DGGML_AVX512_VBMI=ON -DGGML_AVX512_VNNI=ON
  -DGGML_AVX512_BF16=ON -DGGML_AMX_TILE=ON -DGGML_AMX_INT8=ON -DGGML_AMX_BF16=ON` — deliberately
  not `-march=native`. **The AMX flags do nothing for the routed experts** (verified in ggml source
  2026-09-04, master `38521ec`): `ggml-cpu/amx/amx.cpp` rejects every op except `GGML_OP_MUL_MAT`,
  so AMX never runs `MUL_MAT_ID` (the MoE expert matmul), and it has no kernels for IQ types anyway.
  The UD quants' experts are IQ2_XS/IQ3_XXS (UD-Q2_K_XL has *zero* Q2_K expert tensors — parsed from
  the shard headers), which the repack path doesn't cover either, so CPU-resident experts decode
  through the plain AVX2 `vec_dot`. Keep the flags (harmless, they cover Q8_0 dense matmuls) but
  don't reason about CPU expert speed in terms of AMX — see "Where the time goes" below. Rationale
  for explicit flags rather than native detection: this host's CPU (Xeon 6730P: `avx512f avx512bw avx512vl avx512_bf16
  amx_bf16 amx_tile amx_int8` confirmed present via `lscpu`) is identical across both reference
  hosts, so native detection would work too, but explicit flags keep the image's capabilities
  documented and reproducible rather than depending on whatever CPU happens to run the build. If a
  flag name has drifted on a given checkout, `cmake -B build -LAH | grep -iE 'amx|avx512'` inside
  the builder stage lists what that exact source tree actually exposes — check this first if a
  build fails on an unrecognized `-D` flag after either repo updates its CMake options.
- `-DLLAMA_CURL=OFF` — weights are bind-mounted, not fetched via `-hf`; skips a curl-dev dependency.
- Build targets include `llama-perplexity` and `llama-imatrix` (added 2026-09-05) — the quant gate
  and the REAP slicing procedure below need them inside the same image.
- `PATCHES="<a.patch> ..." TAG_SUFFIX=-lip bash build_image.sh` copies local git patches into the build
  context and `git apply`s them after the checkout (both `BUILD_SOURCE`s). The one shipped patch,
  `scripts/patches/kimi-k3-layer-inp.patch`, registers K3's per-layer input streams so DFlash/DSpark
  drafts can read them (see "Speculative decoding"). Images built with it are tagged `…-lip`.
- The `mainline` pin was bumped 2026-09-05 to master `4d9176092d00586775af140581bb0b558ddc4389`
  (includes #27402 IQP, #25952 fused MoE reduction, #28198 concurrent streams per split — the fork's
  b10775 base lacks the last one). With the base layers cached, a rebuild takes ~5 min, not 35.
- `-DBUILD_SHARED_LIBS=OFF` — static link. The runtime stage then just copies four binaries
  (`llama-server`, `llama-cli`, `llama-mtmd-cli`, `llama-gguf-split`), no `.so` matching/`ldconfig`.
- Multi-stage Dockerfile: `nvidia/cuda:13.0.1-devel-ubuntu24.04` builder -> `nvidia/cuda:13.0.1-runtime-ubuntu24.04`
  runtime. CUDA 13 matches what the kimi-k26 NVFP4 path already established as the right CUDA
  generation for this Blackwell hardware.
- **CUDA-stub link failure** (hit and fixed 2026-09-03): the devel image ships nvcc/cudart but not
  the real driver (`libcuda.so.1` — that's the host driver, mounted at container *runtime* via
  CDI). It does ship a link-time stub at
  `/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so`, but that directory isn't on the
  default linker search path, so linking `llama-server` failed: `undefined reference to
  'cuMemCreate'` / `cuMemRelease` / `cuDeviceGetAttribute` etc. (ggml-cuda's CUDA-VMM driver-API
  calls). Fix: `ENV LIBRARY_PATH="/usr/local/cuda/targets/x86_64-linux/lib/stubs:$LIBRARY_PATH"`
  before the `cmake --build` step (gcc/ld consult `LIBRARY_PATH` for `-l` resolution at link time).
- Both repos are young (mainline K3 support 3 weeks old at time of writing; the fork unmerged and
  actively changing) — expect real build friction on any given day. Document what you actually hit
  here as you hit it, rather than treating this section as closed.

### Sizing gate (`download.sh`)
Before downloading anything, sums the selected `QUANT/` subdirectory's bytes via the HF tree API
(same paginated-tree-API technique as kimi-k26's `download.sh`) and checks two things:
1. **Disk** (hard refusal): free space at `$HF_HOME`'s filesystem < quant size -> refuses before
   downloading a byte.
2. **VRAM+RAM** (warning only, not a refusal): `nvidia-smi --query-gpu=memory.total` summed +
   `/proc/meminfo` `MemTotal` < quant size -> the model cannot fit at *any* `--n-cpu-moe` split, no
   matter how it's tuned, so downloading it would be wasted effort. Kept as a warning rather than a
   hard refusal because the check can't know what else is running on the host at deploy time (see
   SKILL.md step 1 — check `nvidia-smi` for other tenants before assuming the full pool is yours).

## Tuning `--n-cpu-moe`

**Superseded 2026-09-03 — do not use `--cpu-moe` (force every routed expert to CPU) as the
default.** That was this section's original advice; measured on the reference host it made a
single 32-token request take **over 20 minutes and never finish** (cold `mmap` page faults for
CPU-resident expert tensors, compounded by the kernel's `numa_balancing` fighting `--numa
distribute`'s placement — see "Runtime requirements" below). `serve_docker.sh` no longer defaults
to it.

**Current default: let `--fit` choose.** This build's llama.cpp has a real auto-fit mechanism
(`--fit on` by default, `--fit-target` margin per device, default 1024 MiB) that sizes `-ngl` and
the GPU/CPU expert split from actual free VRAM across all attached devices. `serve_docker.sh`
leaves both `-ngl` and `--n-cpu-moe` unset unless `N_CPU_MOE` is explicitly given, so `--fit`
controls both. Measured 2026-09-03 (UD-Q2_K_XL, all 8 GPUs free, `--ctx-size 65536 --parallel 1`):
`--fit` landed **~84–95 GB / 97.9 GB used on every GPU** — attention/dense/shared-expert/vision
layers plus most routed experts GPU-resident, only the overflow CPU-resident. Load (with
`--load-mode none`, see below) took ~17 min; a subsequent single-request text completion took
**3 s** (vs. never-completing under the old `--cpu-moe` default) — see the `llm-inference-benchmark`
skill's Kimi-K3 section for the actual served-throughput numbers.

**`--parallel` and `--ctx-size`: `--ctx-size` is the TOTAL across slots, not per-slot.**
`--ctx-size 65536 --parallel 32` gives 2048 tokens/slot (verify in the startup log:
`load_model: initializing, n_slots = 32, n_ctx_slot = 2048`). The practical consequence is that
**raising `--parallel` at a fixed `--ctx-size` costs no extra KV memory** — it only re-partitions
the same pool — so `--fit`'s weight placement is unchanged between `--parallel 1` and `--parallel 32`
(measured: ~92-94 GB/GPU either way). What it *does* cap is per-request context, so a long-context
workload needs `--ctx-size` raised in proportion to `--parallel`.

`serve_docker.sh` defaults to `--parallel 1`; the deployed `/etc/kimi-k3.env` sets `PARALLEL=32`.
Serving anything concurrent wants more than 1 — at `--parallel 1` every extra client just queues
behind one slot, which also makes any benchmark sweep measure the slot count rather than the box
(that mistake is written up in the `llm-inference-benchmark` skill's Kimi-K3 section). But 32 is
**too many** — see the measured cap below.

**Recommended `PARALLEL=16`, not 32** (measured 2026-09-04, full clean sweep, every point N/N
successful — table in the `llm-inference-benchmark` skill). Aggregate output throughput peaks at
**c16 = 14.67 tok/s** and *regresses* to 12.02 at c32, while TTFT goes 50 s → 158 s and TPOT
897 ms → 2043 ms. Past c16 you lose throughput *and* latency at once, so a 32-slot server just buys
a worse operating point. Dropping to 16 also doubles per-slot context at a fixed `--ctx-size 65536`
(2048 → 4096 tokens), which matters because a 1024-in/256-out request already needs ~1300.

The rest of the curve, for picking a cap: c1 5.43 tok/s (TTFT 7.1 s, TPOT 157 ms) → c4 10.03 →
c8 13.59 → **c16 14.67 (peak)** → c32 12.02. TPOT degrades from the very first step, so there is no
flat-latency region beyond c1: **latency-optimal is c1, throughput-optimal is c16**, and a production
cap belongs in `[c1, c16]` depending on which you are optimising. Decode-bound at this shape
(prefill ~144 tok/s vs decode ~6.4 tok/s at c1, roughly 1:5.6) — so the CPU-resident expert compute,
not prefill, is what a faster deployment would have to attack.

Caveat worth knowing before re-tuning: every point above was measured *on* a 32-slot server, so a
dedicated `--parallel 16` server may land slightly differently. The direction is solid; re-measure
the exact peak if you are sizing for a specific SLA.

✅ **RESOLVED (2026-09-03): the "dropped requests at c >= 4" were a benchmark-client bug, not a
server fault.** The server is fine; do not go looking for a serving defect here.

`sglang.bench_serving` feeds **SSE comment lines** to `json.loads`. llama.cpp emits a bare `:`
keep-alive while a request waits during slow prefill; the client skips blanks, strips `data: `,
special-cases `[DONE]`, then JSON-parses whatever remains — so `:` raises
`JSONDecodeError: Expecting value: line 1 column 1 (char 0)`, the request is counted failed, and the
connection drops, which the server faithfully logs as `W srv stop: cancel task`. Same server, same
c8/32 point, only the client differing: **2/32 successful unpatched vs 32/32 patched.** Fix and full
write-up: the `llm-inference-benchmark` skill (`scripts/sse_keepalive_patch.py`, applied
automatically by `bench_sweep.sh`). Any *other* OpenAI-streaming client used against this server
needs the same tolerance — it is a slow server, so it *will* emit keep-alives.

⚠ **Prompt-cache eviction churn is real but unrelated to the drops.** Entries here are ~1.36 GB
against llama.cpp's `--cache-ram` default of 8192 MiB, so only ~6 fit and the server logs `making
room for prompt cache entry, removing oldest entry` constantly (317-478 evictions per c8 run). With
a correct client, **default and `--cache-ram 0` both return 32/32** — the setting does not cause
drops either way. On a benchmark grid it is pure overhead (`random-ids` prompts share no prefix, so
the cache can never hit): `--cache-ram 0` measured 9.07 vs 7.84 out tok/s and TTFT 12 s vs 126 s.
**Keep the default for real serving** — shared system prompts and multi-turn history are precisely
what it accelerates — and set `--cache-ram 0` only when benchmarking with unique prompts. To size it
instead of disabling it, budget against the ~1.36 GB entry (32 slots ≈ 44 GB) versus the ~800 GB of
1 TiB the model already holds.

**Manual override still available**: `N_CPU_MOE=<N>` switches to `-ngl 999 --n-cpu-moe N`
(pins exactly the first N layers' experts to CPU, forces everything else to GPU) if you need
deterministic placement instead of `--fit`'s live-VRAM-based choice — e.g. to compare against a
known configuration, or if `--fit` ever picks something worse than a hand-tuned value on a
particular host. Re-benchmark after changing it.

- Finer-grained alternative: `-ot/--override-tensor <pattern>=<buffer>` targets specific tensor
  name patterns (e.g. a subset of expert weight matrices) rather than whole layers — useful if
  per-layer granularity from `--n-cpu-moe` turns out too coarse, unexplored by this skill so far.
- **Untested**: whether pushing more experts GPU-resident via a manual `N_CPU_MOE` lower than
  what `--fit` already chose meaningfully improves single-stream decode speed (148 ms/token
  measured at `--fit`'s choice), or whether cross-NUMA/attention overhead dominates regardless.

## Tokenizer for benchmarking

The GGUF repo (`unsloth/Kimi-K3-GGUF`) embeds its tokenizer directly in the GGUF files — there's no
separate `tokenizer.json`/`tokenizer_config.json` an `AutoTokenizer` can load, which the
`llm-inference-benchmark` skill's client needs to generate random-id prompts. `download.sh` also
fetches the small non-weight files (config, `tiktoken.model`, `tokenization_kimi.py`, etc. — NOT
the multi-hundred-GB safetensors) from `moonshotai/Kimi-K3` for exactly this purpose. Confirmed
not gated, not private (2026-09-03). Benchmark with `MODEL_REPO=moonshotai/Kimi-K3
MODEL_NAME=kimi-k3` (the served alias `serve_docker.sh` uses by default).

## Verification commands
```bash
curl :30000/health ; curl :30000/v1/models
curl :30000/v1/chat/completions -H 'Content-Type: application/json' -d \
 '{"model":"kimi-k3","messages":[{"role":"user","content":"capital of France?"}],"max_tokens":64}'
```
Also exercise vision (base64 data URL, same fixture-403 caveat as kimi-k26's `verify.sh` — some
hosts UA-filter server-side URL fetches, fetch client-side instead) and a tool call. See
`scripts/verify.sh` / `vision-probe.py`.

## Productionization notes not covered in SKILL.md step 7
- No reverse proxy / auth setup script here (unlike kimi-k26's `setup_proxy.sh`) — this skill
  targets a research/eval-shaped deployment by default. If a real production access model is
  needed later, kimi-k26's Caddy + Tailscale-cert + Bearer-key pattern (REFERENCE.md "Access
  model" in that skill) carries over directly; port it if/when this deployment graduates.
- No cutover/GPU-wait guard like kimi-k26's `WAIT_GPU_FREE` (that existed because a ~595 GB TP=8
  teardown takes 30-60s and racing it OOMs the next launch). This skill's hybrid deploy has a
  smaller, more variable GPU footprint depending on `N_CPU_MOE`, and — more importantly — this
  hardware target is documented as a **shared** GPU pool (unlike kimi-k26's dedicated box): check
  `nvidia-smi` for *other tenants*, not just a stale copy of this same service, before every
  launch.

## Runtime requirements that are NOT tunable

Three flags in `serve_docker.sh` are architecture/hardware facts, not knobs — don't "optimize"
them away without re-verifying against Kimi-K3's actual behavior first (source: hands-on
debugging during this deployment, 2026-09-03):
- **`--numa distribute`** — the ~861 GB UD-Q2_K_XL quant exceeds one CPU socket's RAM share (512
  GiB of this host's 1 TiB across 2 sockets), so weights necessarily span both NUMA nodes.
  Cross-socket (UPI) traffic is an unavoidable cost of a model this size on a 2-socket host, not a
  misconfiguration. *Caveat (2026-09-05):* that rationale held for `--cpu-moe`; under `--fit` only
  ~130 GiB of experts stay on the CPU, which fits one node — single-socket placement was never
  measured, and it stops mattering once the model is all-VRAM (below). Keep `distribute` for hybrid
  runs; don't call it a law.
- **`--cache-type-k f16 --cache-type-v f16`** — the quantized KV cache types (the `q4_0` family,
  block size 32) fail to load on Kimi-K3: its hybrid KDA/MLA head dim is 74, which doesn't divide
  evenly into a 32-wide block. `f16` is the only cache type confirmed to load.
- **`--threads`/`--threads-batch` = physical core count** — `serve_docker.sh` computes this from
  `lscpu -p=CORE,SOCKET` (64 on this host's 2x32c/64t Xeon 6730P; override with `THREADS=`). The
  original "AMX tiles are per physical core" rationale is moot (AMX never touches the experts, above);
  the honest status is *unmeasured* — measured DRAM read bandwidth is 458 GB/s with 64 threads vs 514
  with 128, so `THREADS=128` is a legitimate A/B for hybrid runs, not a mistake.
- **Make it persistent**, or a reboot silently reintroduces the 20-minute-hang bug:
  `echo 'kernel.numa_balancing = 0' | sudo tee /etc/sysctl.d/99-kimi-k3-numa.conf` (installed on
  the reference host 2026-09-03). The `/proc` write below only lasts until reboot.
- **Host prerequisite: `echo 0 | sudo tee /proc/sys/kernel/numa_balancing`** — not something
  `serve_docker.sh` can set (host-wide sysctl, out of scope for a container launcher), but
  required in practice. The kernel's automatic NUMA page migration actively fights `--numa
  distribute`'s manual placement; combined with cold-mmap page faults (next bullet) this is what
  produced the 20+-minute stall above. Not persisted across reboot by this skill — re-apply after
  a host reboot, or bake it into `/etc/sysctl.d/` if this deployment becomes long-lived.
- **`--load-mode none`** (default in `serve_docker.sh`, override with `LOAD_MODE=`) — the
  alternative, `auto` (mmap), pages CPU-resident expert tensors in lazily on first access, which is
  exactly what produced the 20+-minute single-request stall this section used to recommend as the
  starting config. `none` reads everything upfront during load instead (slower load, roughly
  proportional to file size / NVMe throughput — measured ~17 min for 802 GB) so serving is fast
  from the first request rather than page-faulting mid-inference.

## Fork commit pin — verified current (2026-09-03)

An earlier draft of this deployment (predating this skill, same author) pinned a different commit,
`768d2a481a99cb75ec9a03b95dadbd35e7acf496`, referencing PR #48. Checked via the GitHub API before
adopting it: **PR #48 is CLOSED, not merged** — mainline absorbed most of what it carried
(`ggml-org/llama.cpp#26185`), and PR #70 is the rebased remainder (the vision-only delta on top of
mainline). Building against `768d2a4`/PR #48 today means building a stale, partially-redundant
diff. This skill's pin, `883f2c9ba78f3847148454adf025da29385fff3e` on PR #70, is the current
correct one — re-verify via the API before bumping either way, PR #70 was still receiving commits
as of this check (`updated_at: 2026-09-03T08:44:26Z`).

## Access model

Binds `--network host` + the host's Tailscale IP (`tailscale ip -4`), falling back to
loopback-only if Tailscale isn't up — never a silent `0.0.0.0`. This is a deliberate choice, not
llama.cpp's default: matches the settled "tailnet-direct, no Caddy" access decision more precisely
than a generic `-p PORT:PORT` publish would (that also exposes on the Docker bridge/LAN via
`0.0.0.0`, which isn't wanted here). No reverse-proxy/auth layer in front — see
"Productionization notes" below for when that'd need to change.

## Where the time goes (measured 2026-09-04/05)

Decode on the hybrid Q2_K_XL deployment is **not** bound by CPU expert bandwidth: the ~16 CPU-resident
expert layers read ~2.4 GB per token, ~5 ms at the measured 458 GB/s. The 157 ms/token is llama.cpp's
sequential 8-GPU layer split plus ~30 CPU splits per token (all-GPU K3 runs elsewhere reach 13 tok/s
on 8× H20 and 17.5 on 8× B200 — same order of magnitude). Removing the CPU experts entirely (all-VRAM)
gave 72 ms/token here. Full analysis: `/data/devops/kimi-k3/RESEARCH-2026-09-04-faster-serving.md` §1.

Prefill in hybrid mode is **PCIe-copy-bound**: `ggml-backend.cpp` re-copies every CPU-resident expert
tensor (~100 GiB) to GPU0 for each micro-batch of ≥ 32 tokens, with no caching. That is a fixed ~4.4 s
per micro-batch regardless of prompt length (a 100-token prompt costs 4.4 s of prefill). Hence:

- **`BATCH=4096 UBATCH=4096`** (serve_docker.sh, measured E1 2026-09-05): one copy per prompt instead
  of two → mean TTFT c1 7.1 → 4.7 s (−34%), c4 29.5 → 14.4 s (−51%), c8 37.6 → 22.2 s (−41%). The full
  re-sweep (2026-09-06, 16 slots) also lifted throughput: c8 13.6 → **16.0 tok/s** (+17 %), c32 12.0 →
  15.7, and moved the hybrid's knee from c16 to c8 (TPOT at c8 444 → 416 ms). Default for hybrid runs;
  cap the hybrid at c8. Irrelevant once the model is all-VRAM — there use 2048 (next section).
- `--no-op-offload` (compute the CPU layers' prefill on the CPU IQP path instead of copying) was not
  measured: for 1024-token prompts it costs about the same as one copy.

All-VRAM prefill is bound by llama.cpp's K3 path itself, not by data movement: ~185 tok/s at 1024
tokens plus a ~1.4 s fixed cost per prompt (34-token prompt: 1.5 s) that looks like per-prompt graph
rebuild/capture across 8 GPUs. Under concurrency this becomes prompt queueing (TTFT 25 s at c8, 57 s
at c16, 243 s at c32 for 1024-token prompts). A/Bs (IQ2_XXS, 4 slots, 2026-09-05): `GGML_CUDA_DISABLE_GRAPHS=1`
leaves prefill unchanged and costs ~17 % of decode (bench c1 TPOT 78 → 93 ms), so CUDA-graph capture is
*not* the fixed cost; `GGML_CUDA_GRAPH_OPT=1` (concurrent streams per split) is a wash (10.03 vs 10.14
tok/s). The fixed ~0.65 s is the scheduler's graph build/split/alloc for a new ubatch shape across 9
backends plus the serial KDA chunk kernel; upstream work that would help: ggml-org/llama.cpp#26001
(chunked GDN prefill kernel), #25319 (async scheduler copies). Keep the defaults.

## All-VRAM quants and the fit margin

The 8× 96 GB pool is 765 GiB. Two checkpoints fit entirely (verified serving 2026-09-05):

| Quant dir | Size | `--fit` placement | Cold load | Decode c1 |
|---|---|---|---|---|
| `UD-IQ2_XXS` (Unsloth, all 896 experts, IQ2_XXS) | 662 GiB | 84–90 GB/GPU, no CPU experts | 9.8 min | 72 ms/tok = 13.9 tok/s |
| `UD-Q2_K_XL-REAP770` (our slice, 770 experts, IQ2_XS) | 697 GiB | needs `--fit-target 4096`: 91 GB/GPU, no CPU experts (6144 left ~20 GiB on CPU) | 12.3 min | 83 ms/tok = 10.5 tok/s c1, 21.9 tok/s at c8 (8 slots; 121 ms / 7.4 tok/s when 2–3 layers spilled to CPU) |
| `UD-Q2_K_XL` (hybrid reference) | 802 GiB | ~93 GB/GPU + ~130 GiB experts on CPU | 18.7 min | 155 ms/tok = 6.4 tok/s |

Two flags are **required** for an all-VRAM run, learned the hard way (CUDA OOM in the scratch-pool
`alloc` on GPU 4 during the first compute pass, after a full 9-min load):
- **`--fit-target 4096`–`6144`** — `--fit`'s default 1 GiB per-device margin is too small once every
  expert is GPU-resident (the CUDA pool needs room for micro-batch intermediates), but too *large* a
  margin silently spills expert layers to the CPU when the quant is tight: REAP-770 (697 GiB) needs
  4096 to stay all-GPU (verified serving 8 slots x 8192 ctx); IQ2_XXS (662 GiB) is fine at 6144–8192.
  `--fit-target` takes a per-device list (`MiB0,MiB1,…`) — use it when one GPU also hosts a draft.
- **`-b/-ub 2048`** (`BATCH=2048 UBATCH=2048`) rather than 4096 — halves those intermediates; there is
  no expert copy to amortise any more.
`serve_docker.sh` takes both via `BATCH`/`UBATCH` and `EXTRA_ARGS="--fit-target 6144"`. `/etc/kimi-k3.env`
also pins `IMAGE=` explicitly now that several images exist.

**Slot count costs single-stream speed:** on REAP-770, `--parallel 16` → 4 took decode from 116 to
100 ms/token (bench c1 TPOT 121 → 98 ms) with nothing else changed. Size `--parallel` to the real
concurrency, not to "as many as fit".

**The "IQ2_XS is slower than IQ2_XXS" reading was wrong — it was placement.** A K3-shaped
`test-backend-ops perf -o MUL_MAT_ID` run (896 experts, 16 used, 3584x3072; image `…-lip-rsrb-tests`)
puts IQ2_XS and IQ2_XXS within 5 % at batch 1 (30.5 vs 29.1 µs per expert matmul, both ~1.7 TB/s;
IQ3_XXS 42–51 µs, Q2_K 49–51, Q4_K 37–40), and both scale ~linearly with batch (n=4: 133 vs 118 µs;
n=8: 270 vs 242; n=16: 1,114 µs for IQ2_XS) — i.e. **no batching gain in the expert matmul up to
n=16**, which is why aggregate throughput saturates at a couple of dozen tok/s. What actually made
REAP-770 slow in the E5 run: with `--fit-target 6144` the eight GPUs held 693.6 GiB in total including
KV/compute, less than the 697 GiB of weights, so `--fit` had quietly put ~20 GiB (2–3 expert layers) on
the CPU. With `--fit-target 4096` (all 8 GPUs, 714 GiB used) REAP-770 decodes at **86 ms/token at 8
slots** — the same class as IQ2_XXS (72–78 ms at 4 slots) — instead of 116–121 ms. Check the
`CUDA_Host model buffer size` line (visible with `-lv 4`, or in llama-perplexity's output) against the
~5.4 GiB of token embeddings whenever a quant is meant to be all-VRAM; nvidia-smi totals below the
weight size are the tell.

Also from the GGUF census: UD-IQ2_XXS's routed experts are **IQ1_M x173 (348 GiB) + IQ2_XXS x92
(218 GiB) + IQ3_XXS x11** — a mostly 1-bit-class quant, which is what its KLD reflects — while both it
and UD-Q2_K_XL carry the same 57.9 GiB of Q8_0 non-expert weights (attention 29.6, shared experts 12.0,
KDA 6.2, dense/router 7.6, embd/output 2.4 GiB) that every token reads in full (~35 ms at GPU bandwidth,
the largest fixed share of decode). Requantising *those* tensors (Q8_0 → Q6_K/Q5_K) is an untested lever
that applies to every quant equally.

Quality goes the other way (next section).

## Quant gate: perplexity + KL divergence (run before adopting any quant)

Reason: IQ-type CUDA kernels on sm_120 have unresolved corruption reports (UD-TQ2_0 produced garbage
logits on exactly these GPUs — unsloth/Kimi-K3-GGUF discussion #18; IQ3_XXS gibberish on RTX 5080,
llama.cpp #21371), so a new quant must be checked against a known-good reference, not just "it talks".

```bash
EVAL=/data/kimi-k3-eval bash scripts/eval_setup.sh                       # once: venv, slicer, corpora
MODE=base IMAGE=<image> QUANT=UD-Q2_K_XL  bash scripts/run_perplexity.sh  # saves reference logits (5.4 GB)
MODE=test IMAGE=<image> QUANT=<candidate> EXTRA="--batch-size 2048 --ubatch-size 2048 --fit-target 6144"   bash scripts/run_perplexity.sh                                          # PPL + KLD vs the reference
```
Default text `wiki.test.raw`, 16 chunks × 2048 tokens; the base run is a hybrid `--fit` load of
Q2_K_XL (18 min) plus ~2 min of compute. Results 2026-09-05 (vs UD-Q2_K_XL logits):

| Candidate | PPL ratio | Mean KLD | Median KLD | Same top token | Verdict |
|---|---|---|---|---|---|
| UD-Q2_K_XL (reference) | 1.000 (PPL 1.4981) | — | — | — | — |
| UD-IQ2_XXS | 1.226 | 0.370 | 0.052 | 84.6 % | sane (matches Unsloth's published 0.378 / 84.1 % vs Q8) — real quality cost |
| UD-Q2_K_XL-REAP770 | 1.038 | **0.047** | 0.002 | **95.4 %** | near-reference |

A broken kernel shows up as KLD ≫ 1 and PPL in the tens; both candidates are far from that.

**Task-level check (2026-09-06, `scripts/quality_eval.py` via `quality_eval_all.sh`: 200 GSM8K test +
full HumanEval (164) + 200 MBPP, greedy, `reasoning_effort=low`, 4096-token budget; per-item JSON in
`$EVAL/quality/results-*-big.json`, paired comparisons with `quality_eval.py compare`):**

| quant | GSM8K (200) | HumanEval (164) | MBPP (200) | truncated HE / MBPP | mean tokens gsm / he / mbpp |
|---|---|---|---|---|---|
| UD-IQ2_XXS (all-GPU) | 195 = 97.5 % | **157 = 95.7 %** | **194 = 97.0 %** | 4 / 3 | 255 / 506 / 465 |
| UD-Q2_K_XL-REAP770 (all-GPU) | **196 = 98.0 %** | 142 = 86.6 % | 171 = 85.5 % | 14 / 20 | 264 / 1123 / 987 |
| UD-Q2_K_XL hybrid (reference) | **196 = 98.0 %** | **159 = 97.0 %** | **197 = 98.5 %** | 0 / 2 | 248 / 437 / 395 |

Paired: GSM8K is a wash across all three (identical final answers on 197/200 between IQ2_XXS and
REAP-770). On code IQ2_XXS sits within 2–3 items of the full-quant reference (157 vs 159, 194 vs 197)
while REAP-770 loses 17 and 26 items; every discordant IQ2_XXS/REAP-770 pair but one favours IQ2_XXS
(HumanEval 15 : 0, MBPP 24 : 1), and about 60 % of REAP-770's misses are runaway reasoning that exhausts
the 4096-token budget (its code completions are 2.2x longer on average; median completion on its misses
= 4096). The hybrid reference itself was re-run at 8 slots after a first attempt at 16 slots aborted on
the client's 30-min per-request timeout — `quality_eval.py --timeout` now defaults to 3 h and records
per-item errors instead of aborting. So the 14 % expert cut, made with an English+code calibration corpus, damages code
generation specifically while the KLD gate (0.047 vs 0.37) said the opposite: **KLD on wikitext does
not predict task quality here — run the task check before choosing a quant.** A 40+30-item pilot had
already shown the same direction (26/30 vs 30/30 on HumanEval) but could not resolve it.

## REAP expert slicing (how `UD-Q2_K_XL-REAP770` was made)

Goal: keep the Q2_K_XL bits but drop the least-used 14% of routed experts so the file fits VRAM
(size ≈ 56 GiB + 746 GiB × keep/896 → 770 experts ≈ 697 GiB). Byte-exact slab slicing, no
requantisation (01554/kimi-k3-gguf-prune). Steps, all reproducible from this skill:

1. **Expert hotness** — `IMAGE=<image> QUANT=UD-Q2_K_XL bash scripts/run_imatrix.sh` runs
   `llama-imatrix` over `calib.txt` (bartowski calibration_datav3 + 600 KB wikitext-2 *train*, ~197K
   tokens) and saves a GGUF imatrix whose `blk.N.ffn_gate_exps.weight.counts` tensors are the per-expert
   routing counts (289M routings; 7 of 82,432 experts never hit). 81 min on the hybrid Q2_K_XL — the
   imatrix hook copies every MoE op's activations to the host, so it is far slower than perplexity.
2. **Plan** — `venv/bin/python scripts/make_hotness_plan.py --imatrix imatrix-UD-Q2_K_XL.gguf --report`
   prints the coverage curve (keep-770: 97.1 % of routings retained, worst layer 94.1 %; keep-640:
   91.3 % / 84.2 %); `--keep 770 --out plan_keep770.json` writes a uniform plan in kimi-k3-mlx format.
   Count-based ranking recovers ~91 % of gate-weighted REAP saliency (the slicer author's measurement);
   the calibration corpus is part of the model — English + code here.
3. **Slice** — `venv/bin/python kimi-k3-gguf-prune/scripts/prune_gguf.py prune --src <shard-00001> --plan
   plan_keep770.json --out $SNAP/UD-Q2_K_XL-REAP770/Kimi-K3-UD-Q2_K_XL-REAP770.gguf`. Writes one
   697 GiB file into a new quant dir *inside the HF snapshot* so `QUANT=UD-Q2_K_XL-REAP770` works with
   the unchanged serve script. 71 min here: the slicer reads via mmap and ZFS serves mmap page faults at
   ~70–270 MB/s (pre-warming shards through the ARC did not help). Router rows and `exp_probs_b` are
   renumbered in keep order; `expert_count` becomes 770.
4. **Gate** — the KLD test above (result: KLD 0.047, top-1 95.4 %). Then serve and `verify.sh`.

Heavier cuts are a different product: measured elsewhere, 50 % REAP costs ~20 points on GPQA-Diamond.

## Speculative decoding (E6, 2026-09-05)

- **MTP is impossible**: `num_nextn_predict_layers = 0` in the checkpoint.
- **DSpark/DFlash/EAGLE3 drafts consume the target's hidden states**; llama.cpp supports Qwen3-backbone
  drafts (`--spec-type draft-dspark`), and RadixArk/Kimi-K3-DSpark (5 Qwen3-style layers, block 7)
  converts with `convert_hf_to_gguf.py <draft> --target-model-dir <dir with the target's config,
  tokenizer files and the safetensors shard holding embed_tokens/lm_head (model-00094-of-000096)>`
  → `dflash.target_layers = [8, 24, 52, 68, 84]`. The target graph must register `t_layer_inp` — the
  shipped patch registers the attention-residual-mixed stream at the start of each layer (what SGLang's
  `_dspark_capture_stream` returns after layer il−1) and the output-side aggregate for `n_layer`.
  The converted draft lives at `$SNAP/drafts/Kimi-K3-DSpark-bf16.gguf` (4.5 GB).
- K3 is not in `llm_arch_supports_rs_rollback()`, so the server checkpoints the full recurrent state to
  host before each draft step — expect overhead that grows with `--parallel`.
- **Results (REAP-770 target, greedy probes; `--parallel 4 --ctx-size 32768` for all E6 configs):**

  | config | rewrite prompt (copies its input) | knowledge prompt | code prompt | bench c1 (random prompts) |
  |---|---|---|---|---|
  | no speculation, 16 slots (E5 server) | 8.62 tok/s | 8.57 | 8.60 | 7.44 tok/s, TPOT 121 ms |
  | no speculation, 4 slots | 9.93 | 9.92 | 9.99 | **8.99 tok/s, TPOT 98 ms** |
  | `--spec-type ngram-mod`, 4 slots | **10.48** (192 drafted / 69 accepted = 36 %) | 9.75 (no drafts) | 9.69 (no drafts) | 26.5 tok/s — **artifact** |
  | `--spec-type draft-dspark` (RadixArk draft) | crashed at draft init (3/3 attempts) | — | — | — |

  Read it as: **ngram-mod ≈ +5 % on a copy-heavy prompt, −2–3 % elsewhere** (verification overhead
  with no drafts) — not worth enabling by default; **the slot count moved decode more than
  speculation did** (16 → 4 slots: 116 → 100 ms/token, TPOT 121 → 98 ms — keep `--parallel` as low
  as the workload allows). The ngram bench-c1 "26.5 tok/s" is what `random-ids` prompts produce: the
  model's output degenerates into repetition, the drafter accepts 100 % of it (server log: `draft
  acceptance = 1.00000, mean len = 57`). Never benchmark n-gram speculation with random prompts.
- **DSpark crash — root cause found with a debug build (2026-09-05).** Build one with
  `CMAKE_BUILD_TYPE=RelWithDebInfo RUNTIME_EXTRA_PKGS=gdb TAG_SUFFIX=-dbg bash build_image.sh` and run
  the failing command under `gdb -batch -ex run -ex bt` (`docker run --cap-add=SYS_PTRACE
  --security-opt seccomp=unconfined --entrypoint gdb …`). Result:
  ```
  ggml-backend.cpp:941: pre-allocated tensor (output.weight) in a buffer (CUDA7) that cannot run the operation (NONE)
  ggml_backend_sched_split_graph ← llama_context::graph_reserve ← llama_init_from_model (draft)
  ← common_speculative_init_result ← server_context_impl::load_model
  ```
  The DFlash/DSpark draft graph borrows the **target's** `tok_embd` and `output` tensors through
  `ctx_other` (`src/models/dflash.cpp`). In a layer split the target's `output.weight` lives on the
  **last** GPU, so a draft placed anywhere else (`--spec-draft-device CUDA1` in all three failed runs,
  and the default main device CUDA0 would fail the same way) aborts while reserving its graph. It is a
  `GGML_ABORT`, not a memory bug — the release image's crash handler is what dmesg reported as a libc
  fault. **Fix: `--spec-draft-device CUDA<last>`** (CUDA7 here) so the draft's scheduler owns that
  buffer; the target's `tok_embd` stays on the CPU backend, which every scheduler has. The `--fit`
  warning "dflash requires ctx_other to be set … fitting without it" is benign but means the fit
  margin must also cover the draft (~4.3 GB weights + KV) on that GPU.
- **Second fix — bounded recurrent-state rollback for KIMI_K3 (`scripts/patches/kimi-k3-rs-rollback.patch`,
  2026-09-05).** With the device fixed, DSpark ran but *lost* 5–15 % on free-form prompts, because K3
  was not in `llm_arch_supports_rs_rollback()`: llama-server fell back to serialising the whole
  recurrent state to host before every draft step. The patch adds the arch to that switch and makes
  K3's two hand-rolled state stores rollback-aware: `kimi_k3_conv1d` writes `K = n_rs_seq + 1`
  snapshot groups of the conv window (row `s*mem_size + kv_head`, per Q/K/V third — the scheme of
  `llm_build_delta_net_base::build_conv_state`), and the KDA state goes through the generic
  `build_recurrent_attn()`, i.e. the fused `ggml_gated_delta_net(..., K)`, whose contract already
  covers the KDA gate shape `[S_v, H_v, n_tokens, n_seqs]`. Reads were already generic (`build_rs`
  + `s_copy`). With `n_rs_seq == 0` the graph is unchanged. Applies to the fork tree too; images
  carrying both patches are tagged `…-lip-rsrb` (`kimi-k3-llamacpp:fork-883f2c9ba78f-lip-rsrb` is the
  production/vision one, smoke-tested).
  - **Memory:** the snapshots cost `(1 + n_rs_seq) x` the recurrent state — 14.2 GB for 4 slots x
    7 drafts (93 layers) — and `--fit` will make room for it by pushing experts to the CPU unless the
    margins leave space: with a broadcast `--fit-target 8192` it offloaded 27 GB of experts; use a
    **per-device list**, small on the seven weight GPUs and large on the draft's GPU:
    `--fit-target 5632,5632,5632,5632,5632,5632,5632,10240` kept all but ~5 GB on GPU.
    `n_rs_seq` is taken from `--spec-draft-n-max`; fewer slots or a smaller draft shrink it linearly.
- **DSpark results (IQ2_XXS target, `--parallel 4 --ctx-size 32768`, draft on CUDA7, same
  RelWithDebInfo binary throughout, greedy probes + bench):**

  | prompt | no speculation | DSpark, host checkpoints | **DSpark + rs_rollback** |
  |---|---|---|---|
  | rewrite (copies its input) | 12.88 tok/s (77.7 ms) | 17.7–19.6 (51–56 ms) | **22.19 tok/s (45.1 ms)**, 61 % accepted, mean 5.3 |
  | knowledge | 12.81 (78.1) | 11.9–12.4 (81–84) | **15.75 (63.5 ms)**, 38 %, mean 3.6 |
  | code | 12.62 (79.2) | 10.2–10.9 (92–98) | **15.65 (63.9 ms)**, 37 %, mean 3.6 |
  | bench c1 (1024 in / 256 out, random) | 10.14 tok/s, TPOT 77.7 ms | — | **13.98 tok/s, TPOT 49.2 ms** |
  | bench c4 | **18.30 tok/s, TPOT 134.5 ms** | — | 14.92 tok/s, TPOT 220.6 ms |

  Reading: the host checkpoint was the whole cost — with rollback the same draft is **+23 % on
  free-form text and +72 % on copy-heavy text (probes), +38 % throughput / −37 % TPOT on the c1 bench**,
  but **loses at c4** (4 slots x 8-token verify batches multiply the expert reads: 14.9 vs 18.3 tok/s,
  TPOT 221 vs 135 ms). **On the production quant** (REAP-770, `--parallel 2 --ctx-size 16384`,
  `--fit-target 5120x7,13312`, mmproj loaded, fork `…-lip-rsrb` image): bench **c1 12.96 tok/s, TTFT
  3.95 s, TPOT 61.9 ms** (no-spec 4-slot REAP-770: 8.99 / 98 ms), c2 14.01 tok/s / 113 ms; probes
  18.2 / 12.1 / 13.3 tok/s with 72 / 44 / 52 % acceptance. Caveats that remain: greedy output can
  change with the draft on (ggml-org/llama.cpp#25618 reproduced on the rewrite prompt; the other prompts
  were byte-identical), and per-request `"speculative": {"n_max": N}` is ignored on this path.
- **Two serving profiles (installed 2026-09-05, both stopped, neither enabled):**
  `kimi-k3.service` = throughput (REAP-770, 8 slots x 8192, no draft, `/etc/kimi-k3.env`) and
  `kimi-k3-interactive.service` = latency (REAP-770, 2 slots x 8192, DSpark + rollback,
  `/etc/kimi-k3-interactive.env`; template `scripts/kimi-k3-interactive.env.example`). They share the
  GPUs, so each `Conflicts=` with the other: starting one stops the other. Artefacts: draft at
  `$SNAP/drafts/Kimi-K3-DSpark-bf16.gguf`, gdb logs and probes in `/data/kimi-k3-eval/dspark/`.
- **Upstreaming:** both patches are exported as ready-to-push commits with PR descriptions in
  `/data/kimi-k3-eval/upstream/` (`PR-kimi-k3-rs-rollback.md`, `PR-kimi-k3-layer-inp.md`, plus
  `ISSUES.md` for the draft-device abort and the ignored per-request `n_max`); branches
  `kimi-k3-rs-rollback` and `kimi-k3-layer-inp` in the scratch clone. Pushing needs a GitHub login
  (`gh auth login`) — not available to the deployment host's user at the time of writing.

## Throughput baselines
Not here — see the `llm-inference-benchmark` skill's REFERENCE.md, same convention as kimi-k26
(this skill documents deployment mechanics; that one owns the numbers).
