---
name: deploy-kimi-k26-int4-on-rtx-pro-6000
description: Deploy and serve the official Moonshot Kimi-K2.6 INT4 QAT release (1T MoE, compressed-tensors INT4/Marlin, 256K context, vision) — not NVFP4 or other re-quantizations — on a Linux server (verified Ubuntu 26.04) with 8× NVIDIA RTX PRO 6000 Blackwell Server Edition (96 GB, sm_120) GPUs, running an official engine Docker image — vLLM or SGLang, chosen by the user at deploy time with a hardware-based recommendation — via nvidia-container-toolkit CDI (--device nvidia.com/gpu=all --ipc=host --network host, bind-mounted weights) and exposing an OpenAI-compatible API. Use when deploying or serving the INT4 QAT Kimi-K2.6 (or similar INT4 compressed-tensors MoE models) on RTX PRO 6000 Blackwell / sm_120 hardware — vLLM-in-Docker or SGLang-in-Docker (verified) — or troubleshooting NCCL /dev/shm "unhandled system error" in GPU containers, sm_120 "no kernel image" errors, a missing-`ninja` JIT build failure (-runtime image tag), FlashInfer CuTe-DSL MLIR ICE (llvm.mlir.global_dtors), or a slow/hung MoE weight load.
---

# Deploy Kimi-K2.6 (INT4 QAT) on 8× RTX PRO 6000 Blackwell Server Edition (sm_120)

Serve **[Kimi-K2.6](https://huggingface.co/moonshotai/Kimi-K2.6)** (the official **INT4 QAT** checkpoint —
*not* NVFP4 or other re-quants; 1T MoE; compressed-tensors → **Marlin** path; MLA; 256K; MoonViT
vision) with an **official engine Docker image — vLLM or SGLang, user's choice** — OpenAI-compatible
API on `:30000`, **TP=8**, weights bind-mounted read-only from local NVMe, all in VRAM.

**Hardware target:** 8× **RTX PRO 6000 Blackwell Server Edition** (GB202, 96 GB, sm_120) — ~595 GB of
weights + KV cache need the full 8×96 GB pool; PCIe-only, no NVLink. Same-chip Workstation/Max-Q
variants should behave identically (unverified). The host needs only the NVIDIA driver (≥570, open
kernel module, incl. nvidia-persistenced), Docker, and nvidia-container-toolkit — **no CUDA
toolkit, no Python packages** (the download check uses stock python3 + curl).

**Why Docker-only (current best practice):** the official images ship precompiled sm_120 kernels with
their own CUDA + glibc, so the host-JIT failure class a native venv fights (glibc≥2.41 `rsqrt`
header conflict, `ninja`, JIT pre-warm against host CUDA) doesn't exist here, and the deploy
reproduces across hosts — both of those sm_120 fixes are empirically confirmed unnecessary
in-container (image glibc 2.39; the CuTe-DSL norm ICE does **not** reproduce). GPU access uses
**CDI** (`--device nvidia.com/gpu=all`, plain runc — not the legacy `--gpus` runtime hook). Treat
step 6 as the go/no-go gate before fronting traffic.

## Workflow

1. **Verify host** — `nvidia-smi`: GPU model/count/VRAM (this also drives the engine recommendation
   in step 2); persistence daemon active (`systemctl is-active nvidia-persistenced` — ships with the
   driver and still matters for containers: it keeps GPU state resident across container restarts;
   ad-hoc fallback `sudo nvidia-smi -pm 1`); ~650 GB free on local NVMe; GPU containers work via
   CDI (spec: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`):
   ```bash
   docker run --rm --device nvidia.com/gpu=all --entrypoint nvidia-smi <engine-image>
   ```
   (Legacy alternative to CDI: `--gpus all` — see REFERENCE.md.)

2. **Choose the engine** — ask the user with the AskUserQuestion tool: *"Which engine should serve
   Kimi-K2.6?"*, options **SGLang** and **vLLM**, marking one **(Recommended)** by hardware:
   - **8× RTX PRO 6000 Blackwell SE / sm_120 (this skill's reference hardware) → recommend SGLang** —
     the only combination verified end-to-end *and* benchmarked here (baseline 59/210/390/330
     out-tok/s @ c1/8/64/128, reproduced in-Docker within ±1.5% on 2026-06-11).
   - **Other hardware (H100/H200/B200, …) → recommend vLLM** — the model card's primary serving
     guidance, precompiled kernels, no load-time JIT dependency; neither engine is verified by this
     skill there, so prefer the upstream-documented path.
   Both run in the identical container pattern; the choice is about verified support on the GPU, not
   about the container plumbing.

3. **Download checkpoint** (~595 GB) into the HF hub cache, pinned to a commit. **Always respect
   `HF_HOME`** (default `~/.cache/huggingface`) — never hardcode model paths. Point it at big local
   NVMe first, e.g. `export HF_HOME=/data/huggingface`. The `hf`/Xet client may deadlock
   mid-transfer — the script falls back to parallel curl, verifies size/count against the paginated
   HF tree API (needs only curl + python3 stdlib, no pip packages), and writes `refs/main` so the
   serve scripts resolve the snapshot:
   ```bash
   bash scripts/download.sh moonshotai/Kimi-K2.6 <commit-sha>
   ```

4. **Pull the pinned engine image** — never `latest`; bump deliberately and re-run `verify.sh`:
   - SGLang: `docker pull lmsysorg/sglang:v0.5.12.post1-cu130` (~13 GB; the **full** image, not
     `-runtime` — the INT4 Marlin JIT needs ninja+nvcc). Then run the **pre-launch gates**
     (JIT pre-warm + norm probe, seconds each — see REFERENCE.md) before the first real launch.
   - vLLM: `docker pull vllm/vllm-openai:v0.22.1` (~11 GB; current stable as of 2026-06-11).

5. **Launch** (foreground; `DETACH=1` = `-d --restart unless-stopped`). The checkpoint is resolved
   from the `$HF_HOME` hub cache; set `MODEL_PATH=/path/to/ckpt` only to override:
   ```bash
   bash scripts/serve_docker_sglang.sh     # SGLang  (engine flags: see REFERENCE.md)
   bash scripts/serve_docker_vllm.sh       # vLLM
   ```
   Container (both): CDI GPUs, `--ipc=host --network host`, weights `:ro` bind-mount, memlock/nofile
   ulimits, `HF_HUB_OFFLINE=1`. Weight load ~10–15 min from NVMe (~4–5 min warm page cache); ready on
   "The server is fired up and ready to roll!" (SGLang) / "Application startup complete" (vLLM) —
   `docker logs -f kimi-k26-int4`.

6. **Verify** — health, models, text, tool-call, and vision (sent as a base64 data URL):
   ```bash
   bash scripts/verify.sh
   ```

7. **Productionize** — systemd (wraps the serve script; use it **or** `DETACH=1`'s restart policy,
   never both): `scripts/kimi-k26-int4-sglang-docker.service` (SGLang) or
   `scripts/kimi-k26-int4-vllm-docker.service` (vLLM) — install as
   `/etc/systemd/system/kimi-k26-int4.service`.
   TLS + Bearer-API-key reverse proxy + loopback firewall: `scripts/setup_proxy.sh`
   (engine-agnostic, fronts `:30000`).

## Key facts (don't relearn these the hard way)
- **`--ipc=host` is non-negotiable** for TP=8: NCCL needs shared memory and Docker's default 64 MB
  `/dev/shm` breaks it. NCCL "unhandled system error"/SIGBUS right after the load ⇒ check this first.
- Quant auto-detects (compressed-tensors INT4 → Marlin MoE) — no `--quantization` flag. The NVFP4
  fast path is broken on sm_120; that's exactly why the INT4 QAT checkpoint + Marlin.
- Tool calls: SGLang needs only `--tool-call-parser kimi_k2`; vLLM needs **both**
  `--tool-call-parser kimi_k2` **and** `--enable-auto-tool-choice` (missing ⇒ no `tool_calls`).
- Kimi-K2.6 is a **thinking model** (reasoning by default) → answer in `reasoning_content`/`content`;
  disable per request with `chat_template_kwargs:{"thinking":false}`.
- **Vision**: send images as **base64 data URLs**. Server-side `image_url` URL-fetch gets 403 from
  UA-filtering hosts (e.g. Wikimedia) — fixture issue, not a MoonViT failure. vLLM additionally wants
  `--mm-encoder-tp-mode data` (SGLang needs nothing extra).
- MoE weight load is CPU-bound and slow (~10–15 min); high CPU + 0% GPU + quiet logs = *normal loading*.
- `no kernel image is available` on sm_120 ⇒ the image predates Blackwell support — bump the tag.

## When startup crashes or hangs
See **[REFERENCE.md](REFERENCE.md)**: per-engine Docker paths (image pinning, CDI, NCCL/shm, the
SGLang pre-launch gates, the SGLang↔vLLM flag map, py-spy load-vs-hang diagnosis),
checkpoint-download gotchas, KV-cache/256K tuning, and productionization (systemd vs restart
policy, proxy, monitoring).
