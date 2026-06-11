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
- **DeepGemm warning** (`scale_fmt not ue8m0 ... accuracy degradation`) is soft; outputs verified
  coherent. Revisit only if quality looks off.

## Diagnosis playbook
- **Hung after weight load, high CPU, 0% GPU, no log:** usually the *slow MoE weight loader*, not a hang.
  Confirm: `sudo .venv/bin/py-spy dump --pid $(pgrep -f sglang::scheduler_TP0 | head -1)` → active threads
  in `_weight_loader_impl` = loading; stuck in an NCCL collective = real hang.
- **Iterate on JIT failures fast:** the failed kernel is cached under `~/.cache/tvm-ffi/...`; reproduce
  the `nvcc` compile there (seconds) instead of reloading 595 GB. Pre-build with `ninja` to warm the cache.
- **Watch readiness:** poll `/health` and `grep` the log for `ninja: build stopped|ICE 🧊|DSLRuntimeError
  |Received sigquit|fired up and ready`.

## Tuning & limits (Phase 4)
- KV pool at `mem-fraction-static 0.85` ≈ **116K tokens** total → a single request can't reach 256K.
  Raise `--mem-fraction-static` (→0.90) and/or `--kv-cache-dtype fp8_e4m3` to grow it (~2×).
- `--enable-dp-attention` usually lifts multi-user throughput on MLA. Benchmark with `sglang.bench_serving`.
- No NVLink (PCIe only): GPU pairs share a switch (PIX); GPUs 0-3 vs 4-7 are cross-NUMA (`nvidia-smi topo -m`).

## Productionization (Phase 5)
- systemd unit (Type=simple, `TimeoutStartSec=600`, `Restart=on-failure`, `LimitMEMLOCK=infinity`).
- Reverse proxy (Caddy/nginx) for **TLS + API-key** — don't expose `:30000` directly.
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
(MoonViT works on SGLang/sm_120 — no vLLM fallback needed). If vision *were* broken, vLLM
(`--mm-encoder-tp-mode data`) is the documented fallback.
