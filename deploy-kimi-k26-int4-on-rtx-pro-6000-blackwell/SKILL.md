---
name: deploy-kimi-k26-int4-on-rtx-pro-6000-blackwell
description: Deploy and serve the official Moonshot Kimi-K2.6 INT4 QAT release (1T MoE, compressed-tensors INT4/Marlin, 256K context, vision) — not NVFP4 or other re-quantizations — on an Ubuntu server with 8× NVIDIA RTX PRO 6000 Blackwell Server Edition (sm_120) GPUs using a uv venv + SGLang, exposing an OpenAI-compatible API. Use when deploying or serving the INT4 QAT Kimi-K2.6 (or similar INT4 compressed-tensors MoE models) on RTX PRO 6000 Blackwell / sm_120 hardware, installing SGLang in a uv venv, or troubleshooting sm_120 startup crashes — CUDA JIT "rsqrt exception specification" / glibc errors, a missing-`ninja` JIT build failure, FlashInfer CuTe-DSL MLIR ICE (llvm.mlir.global_dtors), or a slow/hung MoE weight load.
---

# Deploy Kimi-K2.6 (INT4 QAT) on 8× RTX PRO 6000 Blackwell (sm_120)

Serve **[Kimi-K2.6](https://huggingface.co/moonshotai/Kimi-K2.6)** (the official **INT4 QAT** checkpoint —
*not* NVFP4 or other re-quants; 1T MoE; compressed-tensors → **Marlin** path; MLA; 256K; MoonViT
vision) natively in a **uv venv** with **SGLang**, OpenAI-compatible API on `:30000`, **TP=8**, all
weights in VRAM. Verified on Ubuntu 26.04 / driver 580 / CUDA 13.1 / 8× 96 GB.

> **REQUIRED before the first launch** (all of these crash *after* the ~15-min weight load, so each
> failed attempt is expensive): the two glibc/sm_120 source fixes (step 4) **and** `ninja` on PATH for
> the INT4 Marlin JIT build (step 2). **Pre-warm** (step 4) validates all three in ~7s instead of ~15 min.

## Workflow

1. **Verify host** — `nvidia-smi` shows 8 GPUs, 96 GB each; driver ≥570 / CUDA ≥12.8; CUDA **toolkit**
   (`nvcc`, e.g. under `/usr/local/cuda`) installed — the INT4 Marlin kernel is JIT-compiled with nvcc;
   `uv` installed; ~650 GB free on local NVMe. Enable persistence: `sudo nvidia-smi -pm 1`.

2. **Create venv + install engine** (Python 3.12; base `sglang` IS the runtime — do **not** use `[all]`):
   ```bash
   uv venv --python 3.12 .venv
   uv pip install --python .venv/bin/python --prerelease=allow "sglang==0.5.12.post1"
   uv pip install --python .venv/bin/python "kernels<0.13"   # transformers 5.6 needs kernels<0.13
   uv pip install --python .venv/bin/python ninja            # REQUIRED: SGLang JIT-builds the INT4 Marlin kernel via ninja
   ```
   Confirm sm_120 kernels: `.venv/bin/python -c "import torch;print(torch.cuda.get_device_capability(0),'sm_120' in torch.cuda.get_arch_list())"` → `(12, 0) True`.

3. **Download checkpoint** (~595 GB) to local NVMe, pinned to a commit. The `hf`/Xet client may
   deadlock mid-transfer — if it stalls, switch to the parallel-curl fallback:
   ```bash
   bash scripts/download.sh moonshotai/Kimi-K2.6 <commit-sha> /data/models/Kimi-K2.6
   ```

4. **Apply the two REQUIRED sm_120 / Ubuntu fixes, then pre-warm the JIT kernel** (both idempotent;
   pre-warm builds in ~7s and validates Fix 1 + that `ninja` is on PATH *before* the 15-min load — a
   failure here is instant, not after weights):
   ```bash
   VENV=./.venv bash scripts/apply_sm120_fixes.sh
   VENV=./.venv bash scripts/prewarm.sh
   ```

5. **Launch** TP=8 / 256K (loads ~595 GB → ~15 min; wait for `The server is fired up and ready`).
   `serve.sh` puts venv/bin + CUDA on PATH so `ninja`/`nvcc` resolve at runtime:
   ```bash
   VENV=./.venv MODEL_PATH=/data/models/Kimi-K2.6 bash scripts/serve.sh
   ```

6. **Verify** — health, models, text, tool-call (`kimi_k2`), and vision (sent as a base64 data URL):
   ```bash
   bash scripts/verify.sh
   ```

## Key facts (don't relearn these the hard way)
- Engine: `sglang==0.5.12.post1` + `torch==2.11.0+cu130`. Parsers: `--tool-call-parser kimi_k2
  --reasoning-parser kimi_k2`. Quant auto-detects as `CompressedTensorsWNA16MarlinMoEMethod` (Marlin).
- **`ninja` is a hard prerequisite.** SGLang JIT-builds the INT4 `gptq_marlin_repack` kernel during
  `process_weights_after_loading` (AFTER the load); no `ninja` on PATH ⇒ `FileNotFoundError: 'ninja'`
  → `Received sigquit`. Install it (step 2) and keep venv/bin on PATH (serve.sh + the systemd unit do).
- Kimi-K2.6 is a **thinking model** (reasoning by default) → answer in `reasoning_content`/`content`;
  disable with `chat_template_kwargs:{"thinking":false}`.
- **Vision**: send images as a **base64 data URL**. Server-side `image_url` URL-fetch uses a default
  `requests` User-Agent that some hosts (e.g. Wikimedia) reject with **403** — that's a fixture issue,
  not a MoonViT failure. MoonViT works on SGLang/sm_120 (no vLLM fallback needed).
- MoE weight load is CPU-bound and slow (~15 min); high CPU + 0% GPU with no log is *normal loading*,
  not a hang (confirm with `py-spy dump`).

## When startup crashes or hangs
See **[REFERENCE.md](REFERENCE.md)** for exact error signatures, root causes, the two fixes + the
`ninja`/pre-warm path, py-spy diagnosis, KV-cache/256K tuning, and productionization (the verified
systemd unit `scripts/kimi-k26.service`, the TLS + API-key reverse proxy `scripts/setup_proxy.sh`, monitoring).
