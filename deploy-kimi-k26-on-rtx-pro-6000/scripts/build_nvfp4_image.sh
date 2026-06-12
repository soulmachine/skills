#!/usr/bin/env bash
# Build the sm_120 NVFP4 vLLM image: a CUDA-13 vLLM (with the FlashInfer b12x FP4 MoE kernels from
# vLLM PR #40082) PLUS the TRITON_MLA shared-memory patch. Two sm_120 facts force this:
#   1. NVFP4 native FP4 MoE (flashinfer_b12x) HARD-REQUIRES CUDA 13 ("b12x fused MoE requires CUDA 13").
#   2. Kimi MLA on sm_120 can ONLY use TRITON_MLA (FlashInfer/FlashMLA reject the config), and its
#      grouped-decode kernel OOMs at graph capture: "triton OutOfResources: shared memory, Required:
#      102400, Hardware limit: 101376" — it keeps num_stages=2 for the MLA latent BLOCK_DMODEL=512
#      (needs 100KB > sm_120's ~99KB; fine on sm_100/sm_90). The fix relaxes the existing num_stages=1
#      guard from BLOCK_DMODEL>=1024 to >=512. (Marlin MoE also needs this — the patch is attention-side.)
#
#   bash build_nvfp4_image.sh           # -> kimi-k26-nvfp4-vllm:cu130-mla (used by QUANT=nvfp4 serve_docker_vllm.sh)
#   BASE_IMAGE=<cuda13 vllm w/ b12x> OUT_IMAGE=<tag> bash build_nvfp4_image.sh
set -euo pipefail

# BASE must be a CUDA-13 vLLM that already contains the b12x kernels (>= PR #40082). The mainline
# cu130-nightly was stale (pre-#40082) and cu129 is the wrong CUDA — pin a known-good CUDA-13 tag.
BASE_IMAGE="${BASE_IMAGE:-vllm/vllm-openai:gemma-x86_64-cu130}"
OUT_IMAGE="${OUT_IMAGE:-kimi-k26-nvfp4-vllm:cu130-mla}"
F=/usr/local/lib/python3.12/dist-packages/vllm/v1/attention/ops/triton_decode_attention.py
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

echo ">> base: $BASE_IMAGE -> out: $OUT_IMAGE"
docker pull "$BASE_IMAGE" || echo "   (using local $BASE_IMAGE)"

# 1) extract the MLA decode kernel from the base image
cid="$(docker create "$BASE_IMAGE")"
docker cp "$cid:$F" "$work/triton_decode_attention.py"
docker rm "$cid" >/dev/null

# 2) widen the num_stages=1 smem guard to cover the MLA latent (BLOCK_DMODEL=512)
if grep -q 'BLOCK_DMODEL >= 1024' "$work/triton_decode_attention.py"; then
  sed -i 's/BLOCK_DMODEL >= 1024/BLOCK_DMODEL >= 512/' "$work/triton_decode_attention.py"
  echo ">> patched: num_stages=1 guard now BLOCK_DMODEL >= 512"
elif grep -q 'BLOCK_DMODEL >= 512' "$work/triton_decode_attention.py"; then
  echo ">> base already patched (>=512) — nothing to change"
else
  echo "!! guard pattern not found — base kernel layout changed; inspect $F by hand" >&2; exit 1
fi

# 3) rebuild (single COPY layer on the base)
printf 'FROM %s\nCOPY triton_decode_attention.py %s\n' "$BASE_IMAGE" "$F" > "$work/Dockerfile"
docker build -f "$work/Dockerfile" -t "$OUT_IMAGE" "$work"
echo ">> built $OUT_IMAGE"
