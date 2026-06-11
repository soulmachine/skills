# Reference — Kimi-K2.6 on RTX PRO 6000 Blackwell

## Model facts
- Repo `moonshotai/Kimi-K2.6` (public, not gated). **Pin the commit** at execution time.
- ~595 GB, 64 safetensors shards + tokenizer (`tiktoken.model`) + `model.safetensors.index.json` +
  `modeling_*.py`/`configuration_*.py` (loaded via `--trust-remote-code`). The HF tree API paginates —
  the repo has **96 files**, not the ~47 the first page shows; verify with `HfApi.get_paths_info`.
- `model_type: kimi_k25` (vision wrapper) over text `kimi_k2`/DeepseekV3: MLA, 61 layers, 384 experts
  (8 routed + 1 shared), `max_position_embeddings: 262144`, YaRN factor 64.
- **Quant:** `compressed-tensors` `pack-quantized`, INT4 group_size 32, applied **only to routed-expert
  MoE linears**; attention / shared experts / dense MLP / vision tower / lm_head stay BF16 → runs the
  mature **Marlin** path (the NVFP4 fast path is broken on sm_120). No `--quantization` flag needed.

## The two REQUIRED sm_120 / Ubuntu-26.04 fixes (`scripts/apply_sm120_fixes.sh`)

Both crash *after* the ~15-min weight load, so each failed attempt is expensive — apply before launch.

### Fix 1 — CUDA JIT compile failure (`ninja: build stopped` → SIGQUIT)
sglang JIT-builds the INT4 `gptq_marlin_repack` kernel with nvcc (`tvm_ffi`). On glibc ≥2.41 the libc
header declares `rsqrt`/`rsqrtf` `noexcept(true)`, clashing with CUDA's device decls:
```
/usr/include/.../bits/mathcalls.h: error: exception specification is incompatible
  with that of previous function "rsqrt" (... crt/math_functions.h)
```
**Fix:** add `noexcept(true)` to the two `rsqrt`/`rsqrtf` extern decls in
`$CUDA_HOME/targets/x86_64-linux/include/crt/math_functions.h` (≈ lines 629/653). Global → fixes every
JIT kernel. Changing the host gcc (`-ccbin g++-14`) does **not** help (the conflict is in glibc headers).
Persists until CUDA is reinstalled.

### Fix 2 — FlashInfer RMSNorm CuTe-DSL MLIR ICE
flashinfer compiles RMSNorm via the CUTLASS CuTe-DSL, which ICEs in `nvidia-cutlass-dsl`'s MLIR and
kills schedulers on the first forward pass (rmsnorm is the first op):
```
DSLRuntimeError: 🧊 ICE 🧊  Verification failed:
error: 'llvm.mlir.global_dtors' op requires attribute 'data'
```
`FLASHINFER_USE_CUDA_NORM=1` selects a plain CUDA norm kernel, **but sglang schedulers don't inherit the
launcher's env**, so the env var alone is insufficient. **Fix:** patch the default in
`.venv/.../flashinfer/norm/__init__.py` line `_USE_CUDA_NORM = os.environ.get("FLASHINFER_USE_CUDA_NORM",
"0") == "1"` → default `"1"` (`!= "0"`). **Re-apply after any flashinfer reinstall/upgrade.**

## Other gotchas
- **`ninja` required for the INT4 Marlin JIT** (hard prerequisite, not optional). SGLang JIT-builds the
  `gptq_marlin_repack` kernel via `tvm_ffi`→`ninja` inside `process_weights_after_loading` — *after* the
  ~15-min load. No `ninja` on PATH ⇒ `FileNotFoundError: [Errno 2] No such file or directory: 'ninja'`
  → `Received sigquit from a child process`. Fix: `uv pip install ninja` into the venv, and keep venv/bin
  (plus CUDA bin for `nvcc`) on PATH — `serve.sh` and `scripts/kimi-k26.service` already do. Pre-warm it
  in ~7s before the real launch with `scripts/prewarm.sh` (also proves Fix 1 compiles).
- **Install lean.** `sglang[all]` drags in fragile diffusion deps (opencv/modelopt/st_attn) and fails
  to resolve; base `sglang` is the full serving runtime. `--prerelease=allow` is needed (sglang depends
  on the `flash-attn-4` beta — a thin loader wheel, not a source build).
- **`kernels` pin.** sglang leaves `kernels` unpinned → pulls 0.15.x, whose `LayerRepository` requires a
  revision/version that transformers 5.6 doesn't pass → import crash. Pin `kernels<0.13`.
- **Writable model dir.** `/data` is often root-owned; `sudo mkdir -p /data/models && sudo chown $USER`.
- **Download stalls.** The repo uses **Xet**; `HF_HUB_ENABLE_HF_TRANSFER` is ignored and the Xet client
  can deadlock at 0 B/s (process alive). `HF_HUB_DISABLE_XET=1` or, most reliably, download missing files
  directly with parallel `curl` (`scripts/download.sh`). Verify file count/sizes vs `HfApi.get_paths_info`.
- **`libtorchcodec`/`libavutil` errors** at startup are non-fatal (video codec only); image vision works.
  They print as several full `Traceback` / `OSError: libavutil.so.* cannot open shared object file` blocks
  (torchcodec probing FFmpeg 8→4 ABIs in turn) — alarming but harmless, so do **not** gate a readiness
  watcher on bare `Traceback` (see the readiness note below).
- **DeepGemm warning** (`scale_fmt not ue8m0 ... accuracy degradation`) is soft; outputs verified
  coherent. Revisit only if quality looks off.

## Diagnosis playbook
- **Hung after weight load, high CPU, 0% GPU, no log:** usually the *slow MoE weight loader*, not a hang.
  Confirm: `sudo .venv/bin/py-spy dump --pid $(pgrep -f sglang::scheduler_TP0 | head -1)` → active threads
  in `_weight_loader_impl` = loading; stuck in an NCCL collective = real hang.
- **Load time is ~15 min only on a cold cache.** A restart shortly after a stop loads in **~3 min** because
  the 595 GB is still warm in the OS page cache — a fast load is *not* a sign it skipped loading. (Drops
  back to ~15 min after a reboot or once the cache is evicted.)
- **Iterate on JIT failures fast:** the failed kernel is cached under `~/.cache/tvm-ffi/...`; reproduce
  the `nvcc` compile there (seconds) instead of reloading 595 GB. Pre-warm before launch with `VENV=./.venv
  bash scripts/prewarm.sh` — builds & caches `gptq_marlin_repack` in ~7s and proves `ninja`+Fix 1 work.
- **Watch readiness:** poll `/health` and `grep` the log for `ninja: build stopped|ICE 🧊|DSLRuntimeError
  |Received sigquit|fired up and ready`. Do **not** grep bare `Traceback` — torchcodec prints benign ones
  during startup (see Other gotchas). The signature-proof condition: loop until the log shows `fired up and
  ready` (success) **or** the launcher process dies (crash) — that catches every failure mode without
  enumerating signatures: `while ! grep -q "fired up and ready" log; do kill -0 $LAUNCHER 2>/dev/null ||
  { echo CRASHED; break; }; sleep 5; done`.

## Tuning & limits (Phase 4)
- KV pool at `mem-fraction-static 0.85` ≈ **116K tokens** total → a single request can't reach 256K.
  Raise `--mem-fraction-static` (→0.90) and/or `--kv-cache-dtype fp8_e4m3` to grow it (~2×).
- `--enable-dp-attention` usually lifts multi-user throughput on MLA. Benchmark with `sglang.bench_serving`.
- No NVLink (PCIe only): GPU pairs share a switch (PIX); GPUs 0-3 vs 4-7 are cross-NUMA (`nvidia-smi topo -m`).

## Productionization (Phase 5)
- systemd unit: use the verified **`scripts/kimi-k26.service`** (Type=simple, `TimeoutStartSec=1200`,
  `Restart=on-failure`, `LimitMEMLOCK=infinity`, `KillSignal=SIGINT` + default control-group KillMode so
  all 8 TP workers are reaped on stop). **Critical:** its `Environment=PATH=` MUST include venv/bin
  (`ninja`) and CUDA bin (`nvcc`), and `HOME=` must point at the user whose `~/.cache/tvm-ffi` holds the
  warm kernel — otherwise it fails the Marlin JIT build exactly like a fresh host. Cutover from a manual
  run: stop it first (SIGINT the process group; confirm GPU mem→0 and `:30000` free) before `systemctl
  start`, else the new instance clashes on the port / OOMs on already-resident weights.
- Reverse proxy + auth: **`scripts/setup_proxy.sh`** (idempotent) installs Caddy in front with a real
  **Tailscale Let's Encrypt** cert + **Bearer API-key** gate and locks `:30000` to loopback via iptables.
  Prereq: enable "HTTPS Certificates" in the Tailscale admin console (DNS) so `tailscale cert` works — the
  script auto-detects the node's MagicDNS name. Key lives in `/etc/caddy/kimi.env`; clients use
  `https://<magicdns>/v1` with `Authorization: Bearer <key>`. A weekly `kimi-cert-renew.timer` refreshes
  the ~90-day cert. (Tailscale already encrypts transit via WireGuard, so this TLS is app-layer for
  https:// clients. The loopback firewall re-applies at boot; the fully robust alternative is binding
  SGLang to `127.0.0.1` via `HOST=` in the systemd unit.)
- `dcgm-exporter` + Prometheus + Grafana; scrape sglang `/metrics` (queue depth, KV utilization, tok/s).

## Verification commands
```bash
curl :30000/health ; curl :30000/v1/models                    # 200, lists kimi-k2.6
# text (thinking off for a direct answer):
curl :30000/v1/chat/completions -H 'Content-Type: application/json' -d \
 '{"model":"kimi-k2.6","messages":[{"role":"user","content":"capital of France?"}],
   "chat_template_kwargs":{"thinking":false},"max_tokens":64}'
```
Also exercise a tool call (expect `tool_calls` with `kimi_k2` parser) and an `image_url` content part
**sent as a base64 data URL** — server-side URL-fetch uses a default `requests` UA that some hosts (e.g.
Wikimedia) 403, which looks like a vision failure but is just the fixture. MoonViT works on SGLang/sm_120. If vision *were* broken, vLLM
(`--mm-encoder-tp-mode data`) is the documented fallback.
