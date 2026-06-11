# Reference — Kimi-K2.6 on RTX PRO 6000 Blackwell

## Model facts
- Repo [`moonshotai/Kimi-K2.6`](https://huggingface.co/moonshotai/Kimi-K2.6) (public, not gated). **Pin the commit** at execution time.
- ~595 GB, 64 safetensors shards + tokenizer (`tiktoken.model`) + `model.safetensors.index.json` +
  `modeling_*.py`/`configuration_*.py` (loaded via `--trust-remote-code`). The HF tree API paginates —
  the repo has **96 files**, not the ~47 the first page shows; `scripts/download.sh` follows the
  Link-header pagination when verifying.
- `model_type: kimi_k25` (vision wrapper) over text `kimi_k2`/DeepseekV3: MLA, 61 layers, 384 experts
  (8 routed + 1 shared), `max_position_embeddings: 262144`, YaRN factor 64.
- **Quant:** `compressed-tensors` `pack-quantized`, INT4 group_size 32, applied **only to routed-expert
  MoE linears**; attention / shared experts / dense MLP / vision tower / lm_head stay BF16 → runs the
  mature **Marlin** path (the NVFP4 fast path is broken on sm_120). No `--quantization` flag needed.

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
  `--mem-fraction-static 0.85` ↔ `--gpu-memory-utilization 0.85` · `--context-length` ↔
  `--max-model-len` · `--tp-size` ↔ `--tensor-parallel-size` · `--chunked-prefill-size 16384` ↔
  chunked prefill is default-on in vLLM (cap via `--max-num-batched-tokens`) · parsers keep the same
  names (`kimi_k2`), but vLLM tool calling additionally requires `--enable-auto-tool-choice`, and
  vision-encoder TP placement in vLLM wants `--mm-encoder-tp-mode data` (SGLang: neither flag exists).
- **Docker-path troubleshooting (both engines):**
  - NCCL `unhandled system error` / SIGBUS shortly after the weight load → `--ipc=host` missing.
  - `no kernel image is available for execution on the device` → image predates sm_120; bump the tag.
  - Container sees no GPUs → CDI spec missing/stale: `sudo nvidia-ctk cdi generate
    --output=/etc/cdi/nvidia.yaml` (auto-refresh: `nvidia-cdi-refresh.path`/`.service`). On the
    legacy path instead: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl
    restart docker`.
  - Tool calls never appear in responses → (vLLM only) `--enable-auto-tool-choice` missing.
  - Quiet logs + high CPU + 0% GPU for many minutes → normal MoE load, not a hang. To confirm:
    `docker exec kimi-k26-int4 sh -c 'pip install -q py-spy && py-spy dump --pid $(pgrep -f
    scheduler_TP0 | head -1)'` — threads in `_weight_loader_impl` = still loading; stuck in an
    NCCL collective = real hang.
  - Watch readiness/failure in `docker logs -f`:
    `grep -E "fired up and ready|Application startup complete|ninja: build stopped|ICE 🧊|DSLRuntimeError|Received sigquit|unhandled system error"`.
- **Production.** Either the systemd unit — `scripts/kimi-k26-int4-sglang-docker.service` (SGLang)
  or `scripts/kimi-k26-int4-vllm-docker.service` (vLLM), both foreground `docker run --rm` wrappers (journald
  via `SyslogIdentifier`, ordered after `docker.service`, `ExecStop=docker stop -t 120`), installed
  as `/etc/systemd/system/kimi-k26-int4.service` — **or** `DETACH=1` (`-d --restart unless-stopped`);
  one mechanism, never both. Cutover from any running instance (e.g. the other engine): stop it
  first and confirm GPU mem → 0 and `:30000` free, or the container clashes on the port / OOMs on
  already-resident weights.
- **Status.** **SGLang-in-Docker: VERIFIED end-to-end 2026-06-11** on the reference host (verify.sh
  5/5, systemd, CDI, restart cycle) — it is what the host now runs. vLLM-in-Docker: not yet exercised
  on this hardware; flags follow the model card's vLLM guidance. Either way keep `verify.sh` (incl.
  tool-call + vision checks) as the go/no-go gate on first launch and after any image bump.

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

## Checkpoint download gotchas (engine-agnostic, `scripts/download.sh`)
- The repo uses **Xet**; `HF_HUB_ENABLE_HF_TRANSFER` is ignored and the Xet client can deadlock at
  0 B/s (process alive). `HF_HUB_DISABLE_XET=1` or, most reliably, the script's parallel-curl
  fallback + stdlib integrity check against the paginated tree API (no host pip packages; `hf` CLI
  optional).
- **Writable cache dir.** Checkpoints go to the hub cache under `$HF_HOME` (default
  `~/.cache/huggingface`). When pointing `HF_HOME` at a data disk (root-owned mount):
  `sudo mkdir -p "$HF_HOME" && sudo chown $USER "$HF_HOME"`.

## Tuning & limits
- KV pool at 0.85 GPU-mem utilization ≈ **116K tokens** total (measured with SGLang 0.5.12.post1
  on the reference host; vLLM lands in the same ballpark) → a single request can't reach 256K.
  Raise toward 0.90 and/or FP8 KV cache (`--kv-cache-dtype fp8_e4m3` SGLang / `--kv-cache-dtype
  fp8` vLLM) for ~2×.
- RTX PRO 6000 Blackwell SE has **no NVLink** — TP=8 all-reduce rides PCIe. Switch sharing and the
  NUMA split are *board*-specific, so check `nvidia-smi topo -m` (verified host: GPU pairs share a
  PCIe switch (PIX), GPUs 0-3 vs 4-7 cross-NUMA).
- Reference throughput baseline (SGLang 0.5.12.post1, reference host, 1024 in / 256 out):
  **59 out-tok/s @ concurrency 1, 210 @ 8, 390 @ 64, 330 @ 128**. The Docker deploy reproduces it
  within ±1.5% (measured 2026-06-11: 59.7/206.7/388.7/329.9) — containerization costs nothing.
  Benchmark any new engine or image bump against these (`sglang.bench_serving` sweep; runs
  in-container via `docker exec kimi-k26-int4 python3 -m sglang.bench_serving ...`).

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
