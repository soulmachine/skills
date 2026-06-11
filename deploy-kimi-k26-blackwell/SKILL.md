---
name: deploy-kimi-k26-blackwell
description: Deploy and serve Moonshot Kimi-K2.6 (1T MoE, INT4/Marlin, 256K context, vision) on an Ubuntu server with 8× NVIDIA RTX PRO 6000 Blackwell (sm_120) GPUs using a uv venv + SGLang, exposing an OpenAI-compatible API. Use when deploying or serving Kimi-K2.6 (or similar INT4 compressed-tensors MoE models) on RTX PRO 6000 Blackwell / sm_120 hardware, installing SGLang in a uv venv, or troubleshooting sm_120 startup crashes — CUDA JIT "rsqrt exception specification" / glibc errors, FlashInfer CuTe-DSL MLIR ICE (llvm.mlir.global_dtors), or a slow/hung MoE weight load.
---

# Deploy Kimi-K2.6 on 8× RTX PRO 6000 Blackwell (sm_120)

Serve **Kimi-K2.6** (1T MoE; native INT4/compressed-tensors → **Marlin** path; MLA; 256K; MoonViT
vision) natively in a **uv venv** with **SGLang**, OpenAI-compatible API on `:30000`, **TP=8**, all
weights in VRAM. Verified on Ubuntu 26.04 / driver 580 / CUDA 13.1 / 8× 96 GB.

> **The two fixes in step 4 are REQUIRED on bleeding-edge Ubuntu (glibc ≥2.41, gcc ≥15).** Without
> them the server loads all weights (~15 min) and *then* crashes. Apply them before the first launch.

## Workflow

1. **Verify host** — `nvidia-smi` shows 8 GPUs, 96 GB each; driver ≥570 / CUDA ≥12.8; `uv` installed;
   ~650 GB free on local NVMe. Enable persistence: `sudo nvidia-smi -pm 1`.

2. **Create venv + install engine** (Python 3.12; base `sglang` IS the runtime — do **not** use `[all]`):
   ```bash
   uv venv --python 3.12 .venv
   uv pip install --python .venv/bin/python --prerelease=allow "sglang==0.5.12.post1"
   uv pip install --python .venv/bin/python "kernels<0.13"   # transformers 5.6 needs kernels<0.13
   ```
   Confirm sm_120 kernels: `.venv/bin/python -c "import torch;print(torch.cuda.get_device_capability(0),'sm_120' in torch.cuda.get_arch_list())"` → `(12, 0) True`.

3. **Download checkpoint** (~595 GB) to local NVMe, pinned to a commit. The `hf`/Xet client may
   deadlock mid-transfer — if it stalls, switch to the parallel-curl fallback:
   ```bash
   bash scripts/download.sh moonshotai/Kimi-K2.6 <commit-sha> /data/models/Kimi-K2.6
   ```

4. **Apply the two REQUIRED sm_120 / Ubuntu fixes** (idempotent, backs up originals):
   ```bash
   VENV=./.venv bash scripts/apply_sm120_fixes.sh
   ```

5. **Launch** TP=8 / 256K (loads ~595 GB → ~15 min; wait for `The server is fired up and ready`):
   ```bash
   VENV=./.venv MODEL_PATH=/data/models/Kimi-K2.6 bash scripts/serve.sh
   ```

6. **Verify** — health, models, text, tool-call (`kimi_k2`), and vision (gating check):
   ```bash
   bash scripts/verify.sh
   ```

## Key facts (don't relearn these the hard way)
- Engine: `sglang==0.5.12.post1` + `torch==2.11.0+cu130`. Parsers: `--tool-call-parser kimi_k2
  --reasoning-parser kimi_k2`. Quant auto-detects as `CompressedTensorsWNA16MarlinMoEMethod` (Marlin).
- Kimi-K2.6 is a **thinking model** (reasoning by default) → answer in `reasoning_content`/`content`;
  disable with `chat_template_kwargs:{"thinking":false}`.
- MoE weight load is CPU-bound and slow (~15 min); high CPU + 0% GPU with no log is *normal loading*,
  not a hang (confirm with `py-spy dump`).

## When startup crashes or hangs
See **[REFERENCE.md](REFERENCE.md)** for exact error signatures, root causes, the two fixes explained,
py-spy diagnosis, KV-cache/256K tuning, and productionization (systemd, auth, monitoring).
