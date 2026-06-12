# Reference — Kimi-K2.6 on RTX PRO 6000 Blackwell

## Model facts
- Repo [`moonshotai/Kimi-K2.6`](https://huggingface.co/moonshotai/Kimi-K2.6) (public, not gated). **Pin the commit** at execution time.
- ~595 GB, 64 safetensors shards + tokenizer (`tiktoken.model`) + `model.safetensors.index.json` +
  `modeling_*.py`/`configuration_*.py` (loaded via `--trust-remote-code`). The HF tree API paginates —
  the repo has **96 files**, not the ~47 the first page shows; `scripts/download.sh` follows the
  Link-header pagination when verifying.
- `model_type: kimi_k25` (vision wrapper) over text `kimi_k2`/DeepseekV3: MLA, 61 layers, 384 experts
  (8 routed + 1 shared), `max_position_embeddings: 262144`, YaRN factor 64.
- **Quant (INT4, the default):** `compressed-tensors` `pack-quantized`, INT4 group_size 32, applied
  **only to routed-expert MoE linears**; attention / shared experts / dense MLP / vision tower / lm_head
  stay BF16 → mature **Marlin** path, no `--quantization` flag.
- **NVFP4 is a *separate* checkpoint** ([`nvidia/Kimi-K2.6-NVFP4`](https://huggingface.co/nvidia/Kimi-K2.6-NVFP4),
  ModelOpt FP4 on the same routed experts). It runs on sm_120 **via vLLM** (not SGLang) but is **not the
  default** and gives no throughput win here — see "## NVFP4 on sm_120" below.

## Primary path: official engine image in Docker — vLLM or SGLang

Same container pattern for both engines; the engine is the user's choice at deploy time (SKILL.md
step 2 — AskUserQuestion, recommendation by hardware: **SGLang on the verified 8× RTX PRO 6000
Blackwell SE reference hardware**, vLLM elsewhere per the model card's primary guidance).

- **Image pinning.** Never `latest`; bump deliberately and re-run `verify.sh`.
  - vLLM (`scripts/serve_docker_vllm.sh`): `vllm/vllm-openai:v0.22.1` (current stable as of 2026-06-11,
    ~11 GB, multi-arch, precompiled sm_120/Blackwell kernels). Variants exist (`-cu129`,
    `-ubuntu2404`, `-x86_64`); the plain release tag is the default choice.
  - SGLang (`scripts/serve_docker_sglang.sh`): `lmsysorg/sglang:v0.5.12.post1-cu130` (~13 GB;
    the engine version verified end-to-end on the reference hardware). Use the **full** image, NOT
    `-runtime` — SGLang JIT-builds the INT4 `gptq_marlin_repack` kernel at load time and needs the
    image's ninja (1.13) + nvcc; both verified present.
- **GPU access — CDI by default** (current best practice; verified on Docker 29): spec via
  `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, then `--device nvidia.com/gpu=all`
  on plain runc — no legacy nvidia runtime hook (`docker inspect` shows `DeviceRequests` with
  `Driver: cdi`). No daemon.json flag needed on Docker ≥28; the toolkit's `nvidia-cdi-refresh.path`
  /`.service` units keep the spec fresh across driver upgrades. Legacy alternative for tooling that
  assumes it: `GPU_ARGS="--gpus all"` (runtime hook; no performance difference — purely plumbing/
  security/portability).
- **Why each container flag:**
  - `--ipc=host` — NCCL shared-memory transport between the 8 TP workers; Docker's default 64 MB
    `/dev/shm` breaks it (alternative: `--shm-size=32g`).
  - `--network host` — binds the host stack directly, so the loopback-only firewall (`kimi-fw`) and
    the Caddy reverse proxy see a plain local listener; no published-port iptables/NAT.
  - `-v $MODEL_PATH:/models/kimi:ro` — bind-mount the weights; **never** bake ~600 GB into an image
    (overlayfs read path + unshippable image).
  - `--ulimit memlock=-1 --ulimit nofile=1048576` — NCCL pinned memory + fds for shards/connections.
  - `-e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1` — full local checkpoint; no hub traffic at start.
- **SGLang ↔ vLLM flag map** (the two serve scripts differ only in these):
  `--mem-fraction-static` vs `--gpu-memory-utilization`: **NOT equivalent** (measured — mapping
  0.85↔0.85 fails). SGLang's knob = weights+KV pool, transients live *outside* it (0.85 is the
  verified ceiling; 0.90 OOM-crashes). vLLM's knob caps the *total* footprint incl. profiled
  transients (0.85 leaves 0.49 GB KV → refuses to start; **0.95 is the working setting** and is
  safe because transients are pre-reserved) · `--context-length` ↔ `--max-model-len` (vLLM bf16-KV
  tops out ~131K on 96 GB GPUs — 256K needs `--kv-cache-dtype fp8`) · `--tp-size` ↔
  `--tensor-parallel-size` · `--chunked-prefill-size 16384` ↔ chunked prefill is default-on in
  vLLM (cap via `--max-num-batched-tokens`) · parsers keep the same names (`kimi_k2`), but vLLM
  tool calling additionally requires `--enable-auto-tool-choice`, and vision-encoder TP placement
  in vLLM wants `--mm-encoder-tp-mode data` (SGLang: neither flag exists).
- **Docker-path troubleshooting (both engines):**
  - NCCL `unhandled system error` / SIGBUS shortly after the weight load → `--ipc=host` missing.
  - `no kernel image is available for execution on the device` → image predates sm_120; bump the tag.
  - Container sees no GPUs → CDI spec missing/stale: `sudo nvidia-ctk cdi generate
    --output=/etc/cdi/nvidia.yaml` (auto-refresh: `nvidia-cdi-refresh.path`/`.service`). On the
    legacy path instead: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl
    restart docker`.
  - vLLM exits at startup with `ValueError: ... KV cache is needed, which is larger than the
    available KV cache memory` → the utilization-semantics trap (see flag map): raise
    `GPU_MEM_UTIL` to 0.95 and/or lower `MAX_MODEL_LEN` / set `KV_CACHE_DTYPE=fp8`.
  - SGLang dies mid-traffic with `torch.OutOfMemoryError` → SIGQUIT → whole server down: a
    too-high mem-fraction left no transient headroom (vision tower / big-batch buffers allocate
    outside the pool) — keep 0.85 (see Tuning).
  - Tool calls never appear in responses → (vLLM only) `--enable-auto-tool-choice` missing.
  - Quiet logs + high CPU + 0% GPU for many minutes → normal MoE load, not a hang. To confirm:
    `docker exec kimi-k26 sh -c 'pip install -q py-spy && py-spy dump --pid $(pgrep -f
    scheduler_TP0 | head -1)'` — threads in `_weight_loader_impl` = still loading; stuck in an
    NCCL collective = real hang.
  - Watch readiness/failure in `docker logs -f`:
    `grep -E "fired up and ready|Application startup complete|ninja: build stopped|ICE 🧊|DSLRuntimeError|Received sigquit|OutOfMemoryError|unhandled system error"`.
- **Production.** One static unit `scripts/kimi-k26.service` (foreground `docker run --rm` wrapper,
  ordered after `docker.service`, `ExecStop=docker stop -t 120 kimi-k26`) driven by
  `/etc/kimi-k26.env` (`scripts/kimi-k26.env.example`) — the EnvironmentFile selects
  `FRAMEWORK`/`QUANT`/`IMAGE`, and `ExecStart` is `serve_docker_${FRAMEWORK}.sh`. One 595 GB variant
  fills the 8-GPU pool, so the name stays `kimi-k26`; **switch quant/engine = edit the env + `systemctl
  restart kimi-k26`**. ⚠ Keep env values **bare** — systemd `EnvironmentFile` folds an inline `# comment`
  into the value (mangled `HF_HOME` → `LocalEntryNotFoundError`). Use the unit **or** `DETACH=1`
  (`-d --restart unless-stopped`), never both. The static name also prevents a double-enable that would
  fight for `:30000` + all GPUs. (Switching engine/quant restarts in place — the new container reuses
  the port and resident weights cleanly since the old one is stopped first by `ExecStartPre`.)
- **Status.** **Both engines VERIFIED end-to-end 2026-06-11** on the reference host (verify.sh 5/5
  each, incl. tool-call + vision). SGLang-in-Docker is what the host runs (systemd, CDI, restart
  cycle, fp8 KV adopted) and is faster at every measured concurrency (see baselines); vLLM-in-Docker verified at
  `GPU_MEM_UTIL=0.95` + `MAX_MODEL_LEN=131072` (a 0.85/256K first start refuses — see flag map).
  Keep `verify.sh` as the go/no-go gate on first launch and after any image bump.

### SGLang-in-Docker specifics (`scripts/serve_docker_sglang.sh`) — VERIFIED 2026-06-11

Verified end-to-end on the reference host: all five `verify.sh` checks (text/tool-call/vision),
systemd unit, CDI GPU access, full restart cycle. Weight load ~9 min cold, ~4½ min on warm page
cache. The two sm_120 host-JIT failure modes that plague bare-metal SGLang installs are
**N/A in-container** — empirically confirmed (kept here for image-bump triage):
- *glibc≥2.41 `rsqrt`/`rsqrtf` header conflict* (`exception specification is incompatible`, breaks
  the Marlin-repack JIT compile against host CUDA): image is Ubuntu 24.04 / glibc 2.39 — the
  conflict doesn't exist in-image.
- *FlashInfer CuTe-DSL RMSNorm MLIR ICE* (`DSLRuntimeError: 🧊 ICE 🧊 ... 'llvm.mlir.global_dtors'
  op requires attribute 'data'`, kills schedulers on the first forward pass): probed
  `flashinfer.norm.rmsnorm` on-GPU in the unmodified image (`_USE_CUDA_NORM=False`, CuTe-DSL path)
  — runs clean on sm_120. The serve script still sets `FLASHINFER_USE_CUDA_NORM=1`
  belt-and-suspenders (`docker run -e` reaches every scheduler process); if a future tag ever ICEs
  on the norm probe below, that env var — or flipping flashinfer's `_USE_CUDA_NORM` default in a
  one-line derived image — is the fix.
- **Pre-launch gates** (seconds each, vs a ~15-min wasted load — run before the first real launch):
  ```bash
  IMG=lmsysorg/sglang:v0.5.12.post1-cu130
  docker run --rm --device nvidia.com/gpu=all --entrypoint nvidia-smi $IMG          # 8 GPUs visible
  docker run --rm --entrypoint bash $IMG -lc 'command -v ninja nvcc'                # JIT toolchain
  # JIT pre-warm into the persisted cache the serve script mounts (~6s):
  docker run --rm --device nvidia.com/gpu=all -v <workdir>/tvm-ffi-cache:/root/.cache/tvm-ffi \
    --entrypoint python3 $IMG -c \
    'import sglang.jit_kernel.gptq_marlin_repack as m; print(m._jit_gptq_marlin_repack_module())'
  # norm-ICE probe (if this ever ICEs on a new tag, patch flashinfer's default in a derived image):
  docker run --rm --device nvidia.com/gpu=all --entrypoint python3 $IMG -c \
    'import torch, flashinfer.norm as n; x=torch.randn(8,128,device="cuda",dtype=torch.float16); w=torch.ones(128,device="cuda",dtype=torch.float16); print(n.rmsnorm(x,w).shape)'
  ```
- The serve script bind-mounts `tvm-ffi-cache/` (cwd-relative; the systemd unit's
  `WorkingDirectory` anchors it) over `/root/.cache/tvm-ffi` so the Marlin JIT kernel persists
  across container restarts; SGLang also auto-builds a few small kernels there on first launch.
- Expect the PCIe-only warning `CustomAllReduceV2 is disabled ... more than two PCIe-only GPUs`
  and the soft DeepGemm `scale_fmt not ue8m0` warning — both benign (outputs verified coherent).

## NVFP4 on sm_120 (vLLM only; `QUANT=nvfp4`) — verified 2026-06-11
Checkpoint [`nvidia/Kimi-K2.6-NVFP4`](https://huggingface.co/nvidia/Kimi-K2.6-NVFP4): ModelOpt **NVFP4**
(group 16, FP8 block scales) on the **routed experts only**; attention/shared/vision/lm_head stay BF16.
The entire FP4 question is the grouped MoE GEMM. Four sm_120 facts, each a wall hit this date:

1. **Engine: vLLM only.** SGLang NVFP4 produces **NaN** on sm_120 (sgl-project #18954, flashinfer #2577);
   `serve_docker_sglang.sh` refuses `QUANT=nvfp4`.
2. **MLA backend: TRITON_MLA, patched.** On sm_120 vLLM's MLA selector rejects FlashInfer-MLA/FlashMLA
   (even when forced via `VLLM_ATTENTION_BACKEND`) and lands on `TRITON_MLA` — whose grouped-decode
   kernel `_decode_grouped_att_m_fwd` keeps `num_stages=2` for the MLA latent `BLOCK_DMODEL=512`, needing
   **102400 B** smem > sm_120's **101376** → `triton OutOfResources` at CUDA-graph capture. `build_nvfp4_image.sh`
   relaxes the existing `num_stages=1` guard from `>=1024` to `>=512`. (Attention-side — needed for *both*
   `--moe-backend marlin` and `flashinfer_b12x`.)
3. **MoE backend: CUDA 13 for native; Marlin is faster anyway.** `--moe-backend flashinfer_b12x` (native
   FP4 tensor cores, vLLM PR #40082) hard-errors on CUDA 12 ("b12x fused MoE requires CUDA 13"), so the
   image must be CUDA 13. It *does* dispatch FP4 (oracle log `Using 'FLASHINFER_B12X' NvFp4 MoE backend`,
   no silent Marlin fallback — `auto` would silently pick Marlin, so name it explicitly). **But the A/B**
   (TP=8, IN=1024/OUT=256, MAX_SEQS=16): marlin **57/264/359/369/368** out-tok/s @ c1/8/16/32/64 vs b12x
   **49/248/320/320/328** — marlin **~12% faster** and more KV (309K vs 192K tok; b12x reserves ~3.2 GB/GPU
   more workspace). The box is **PCIe-comm-bound at TP=8 (no NVLink)**, so the FP4 GEMM speedup never
   reaches end-to-end. → default `--moe-backend marlin`; `flashinfer_b12x` only to exercise the tensor cores.
4. **Offline remote-code de-symlink.** With `HF_HUB_OFFLINE=1` vLLM passes the snapshot dir; transformers
   ≥5.10 `resolve()`s the custom tokenizer into `blobs/` (hash-named) and can't find its relative imports
   → `FileNotFoundError …/blobs/tool_declaration_ts.py`. `prep_remote_code.sh` de-references the snapshot
   `*.py` into real files (weights stay symlinked). Run as the cache owner; re-run after any fresh download.

Extra vLLM flags `serve_docker_vllm.sh` adds for `QUANT=nvfp4`: `--quantization modelopt_fp4
--kv-cache-dtype fp8 --disable-custom-all-reduce --moe-backend ${MOE_BACKEND:-marlin}` (GPU_MEM_UTIL 0.90).
On **datacenter Blackwell (sm_100/B200)** none of 1–2 apply and native FP4 (`flashinfer_cutedsl`) is tuned —
prefer NVFP4 there. Verify the chosen MoE backend in the log: `Using '<BACKEND>' NvFp4 MoE backend …`.

## Checkpoint download gotchas (engine-agnostic, `scripts/download.sh`)
- The repo uses **Xet**; `HF_HUB_ENABLE_HF_TRANSFER` is ignored and the Xet client can deadlock at
  0 B/s (process alive). `HF_HUB_DISABLE_XET=1` or, most reliably, the script's parallel-curl
  fallback + stdlib integrity check against the paginated tree API (no host pip packages; `hf` CLI
  optional).
- **Writable cache dir.** Checkpoints go to the hub cache under `$HF_HOME` (default
  `~/.cache/huggingface`). When pointing `HF_HOME` at a data disk (root-owned mount):
  `sudo mkdir -p "$HF_HOME" && sudo chown $USER "$HF_HOME"`.

## Tuning & limits
- KV pool at 0.85 GPU-mem utilization = **116,470 tokens** with bf16 KV (measured, SGLang
  0.5.12.post1) → a single request can't reach 256K. **FP8 KV cache doubles it**:
  `KV_CACHE_DTYPE=fp8_e4m3` (env knob in `serve_docker_sglang.sh`) → **232,306 tokens**, verify
  5/5 incl. vision, throughput parity at c1/c8 and **+86% at c128** (see baseline below). vLLM
  equivalent: `--kv-cache-dtype fp8`.
- **Do NOT raise mem-fraction to 0.90 on this model/hardware** (measured 2026-06-11): the static
  pool leaves <1 GB/GPU transient headroom and the server **OOM-crashes** — the MoonViT vision
  tower allocates ~0.1–1 GB/request *outside* the pool (112 MiB alloc failed with 4 MiB free), and
  even text at concurrency 8 needed an 804 MiB transient buffer (745 MiB free). A scheduler OOM
  escalates to SIGQUIT and kills the whole server, so this is a crash, not a slowdown. 0.85 is the
  verified ceiling; pair it with fp8 KV for capacity instead.
- RTX PRO 6000 Blackwell SE has **no NVLink** — TP=8 all-reduce rides PCIe. Switch sharing and the
  NUMA split are *board*-specific, so check `nvidia-smi topo -m` (verified host: GPU pairs share a
  PCIe switch (PIX), GPUs 0-3 vs 4-7 cross-NUMA).
- Reference throughput baselines (SGLang 0.5.12.post1, reference host, 1024 in / 256 out,
  out-tok/s @ c1/8/64/128, measured 2026-06-11):
  - bf16 KV, 0.85 (engine default): **59.7 / 206.7 / 388.7 / 329.9** — reproduces the retired
    native deploy within ±1.5%; containerization costs nothing. (c128 < c64 = KV pressure at 116K.)
  - fp8 KV, 0.85 (`KV_CACHE_DTYPE=fp8_e4m3`; **production config on the reference host since
    2026-06-11**): **59.4 / 208.2 / 398.5 / 613.3** — the c128 KV-pressure regression disappears
    with the 232K pool. Re-confirmed in production under systemd 2026-06-12:
    **59.3 / 207.1 / 396.1 / 610.7** (every point within 0.6%; service stayed healthy through the
    sweep) — c128 is **+85% over bf16**, reproducibly.
  - vLLM 0.22.1 (0.95 util, 131K max-len, bf16 KV): **44.5 / 183.1 / 332.9 / 474.2** — KV pool
    166,960 tokens; slower than SGLang at every point (−25% single-stream). Client:
    `sglang.bench_serving --backend vllm` run from the SGLang image (`--network host`, no GPU).
  Benchmark any new engine or image bump against these: `scripts/bench_sweep_sglang.sh`
  (`sglang.bench_serving` via `docker exec`) / `scripts/bench_sweep_vllm.sh` (client runs from the
  SGLang image over `--network host` — the vLLM image ships no bench tool).

## Productionization (Phase 5)
- Serving: see "Production" under the primary path above (docker systemd unit XOR restart policy).
- Reverse proxy + auth: **`scripts/setup_proxy.sh`** (idempotent, engine-agnostic) installs Caddy in
  front with a real **Tailscale Let's Encrypt** cert + **Bearer API-key** gate and locks `:30000` to
  loopback via iptables. Prereq: enable "HTTPS Certificates" in the Tailscale admin console (DNS) so
  `tailscale cert` works — the script auto-detects the node's MagicDNS name. Key lives in
  `/etc/caddy/kimi.env`; clients use `https://<magicdns>/v1` with `Authorization: Bearer <key>`. A
  weekly `kimi-cert-renew.timer` refreshes the ~90-day cert. (Tailscale already encrypts transit via
  WireGuard, so this TLS is app-layer for https:// clients. The loopback firewall re-applies at boot;
  the fully robust alternative is binding the server to `127.0.0.1` via `HOST=`.) **No Tailscale?**
  The script's cert steps are Tailscale-specific, but the shape carries over: point a public DNS name
  at the host, drop the `tls` line from the Caddyfile (Caddy's built-in ACME then issues the cert) and
  skip `kimi-cert-renew.*`; the Bearer-key gate and the loopback lock are unchanged.
- `dcgm-exporter` + Prometheus + Grafana; scrape the server's `/metrics` (queue depth, KV utilization,
  tok/s) — exposed by both vLLM and SGLang.

## Verification commands
```bash
curl :30000/health ; curl :30000/v1/models                    # 200, lists kimi-k2.6
# text (thinking off for a direct answer):
curl :30000/v1/chat/completions -H 'Content-Type: application/json' -d \
 '{"model":"kimi-k2.6","messages":[{"role":"user","content":"capital of France?"}],
   "chat_template_kwargs":{"thinking":false},"max_tokens":64}'
```
Also exercise a tool call (expect `tool_calls` with the `kimi_k2` parser) and an `image_url` content
part **sent as a base64 data URL** — server-side URL-fetch uses a default UA that some hosts (e.g.
Wikimedia) 403, which looks like a vision failure but is just the fixture. MoonViT works on sm_120;
for vision-encoder TP placement in vLLM use `--mm-encoder-tp-mode data`.
