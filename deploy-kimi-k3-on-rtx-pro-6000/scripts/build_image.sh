#!/usr/bin/env bash
# Build a llama.cpp Docker image from source, compiled for CUDA sm_120 (RTX PRO 6000 Blackwell)
# AND this host's CPU (AMX tile/int8/bf16, AVX-512) — no upstream image ships both, and both
# BUILD_SOURCE repos are too young/unmerged to trust a moving `latest`.
#
#   BUILD_SOURCE=fork     bash build_image.sh   # unslothai/llama.cpp PR #70 — vision (MoonViT-3d)
#   BUILD_SOURCE=mainline bash build_image.sh   # ggml-org/llama.cpp        — text only
#   REPO_URL=... REF=<sha> bash build_image.sh  # explicit override (either BUILD_SOURCE)
#   PATCHES="/path/a.patch ..." TAG_SUFFIX=-lip bash build_image.sh   # apply local git patches after checkout
#   CMAKE_BUILD_TYPE=RelWithDebInfo RUNTIME_EXTRA_PKGS=gdb TAG_SUFFIX=-dbg bash build_image.sh   # debuggable image
set -euo pipefail
BUILD_SOURCE="${BUILD_SOURCE:-fork}"
case "$BUILD_SOURCE" in
  fork)
    REPO_URL="${REPO_URL:-https://github.com/unslothai/llama.cpp}"
    # PR #70 "kimi-k3 : the MoonViT-3d vision tower and full-size loading fixes", branch
    # kimi-k3-vision-only. Unmerged — pin explicitly, re-check the PR before bumping this.
    # NOT PR #48 (an earlier iteration, commit 768d2a481a99cb75ec9a03b95dadbd35e7acf496): #48 is
    # CLOSED/superseded (verified via the GitHub API 2026-09-03) — mainline absorbed most of what
    # #48 carried (ggml-org/llama.cpp#26185), and #70 is the rebased remainder (vision-only delta
    # on top of mainline). Building against #48 today means building a stale, partially-redundant
    # diff — #70 is the current correct pin.
    REF="${REF:-883f2c9ba78f3847148454adf025da29385fff3e}"
    ;;
  mainline)
    REPO_URL="${REPO_URL:-https://github.com/ggml-org/llama.cpp}"
    # Kimi-K3 text model merged in #26185 (ad1de39e, 2026-08-15). Text-only — no --mmproj.
    # Pinned to master HEAD of 2026-09-05 so the image carries the 2026-09 perf merges the fork's
    # b10775 base lacks (#28198 concurrent CUDA streams per split; also #27402 IQP, #25952).
    REF="${REF:-4d9176092d00586775af140581bb0b558ddc4389}"
    ;;
  *) echo "Unknown BUILD_SOURCE='$BUILD_SOURCE' (use: fork | mainline)" >&2; exit 2 ;;
esac
SHORT_REF="${REF:0:12}"
OUT_IMAGE="${OUT_IMAGE:-kimi-k3-llamacpp:${BUILD_SOURCE}-${SHORT_REF}${TAG_SUFFIX:-}}"
CUDA_ARCH="${CUDA_ARCH:-120}"   # sm_120 = compute capability 12.0 (RTX PRO 6000 Blackwell / GB202)
BASE_CUDA_IMAGE="${BASE_CUDA_IMAGE:-nvidia/cuda:13.0.1-devel-ubuntu24.04}"
RUNTIME_CUDA_IMAGE="${RUNTIME_CUDA_IMAGE:-nvidia/cuda:13.0.1-runtime-ubuntu24.04}"
# CMAKE_BUILD_TYPE: Release (default) | RelWithDebInfo (symbols for gdb backtraces, still -O2) | Debug.
# RUNTIME_EXTRA_PKGS: extra apt packages for the runtime stage, e.g. "gdb" for in-container debugging
# (run such a container with --cap-add=SYS_PTRACE --security-opt seccomp=unconfined).
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
# BUILD_TESTS=ON adds test-backend-ops to the image (kernel micro-benchmarks: `test-backend-ops perf -o MUL_MAT_ID`).
BUILD_TESTS="${BUILD_TESTS:-OFF}"
EXTRA_TARGETS="${EXTRA_TARGETS:-}"
RUNTIME_EXTRA_PKGS="${RUNTIME_EXTRA_PKGS:-}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# PATCHES: space-separated local .patch files (git diff format) applied with `git apply` right
# after the checkout — e.g. the Kimi-K3 t_layer_inp registration that DFlash/DSpark drafts need
# (/data/kimi-k3-eval/dspark/kimi-k3-layer-inp.patch). Use TAG_SUFFIX to mark patched images.
mkdir -p "$work/patches"; PATCH_STEP=""
if [ -n "${PATCHES:-}" ]; then
  for pf in $PATCHES; do cp "$pf" "$work/patches/"; done
  PATCH_STEP='COPY patches/ /patches/
RUN for p in /patches/*.patch; do echo ">> applying $p"; git apply --verbose "$p"; done'
fi
cat > "$work/Dockerfile" <<DOCKERFILE
# syntax=docker/dockerfile:1
FROM ${BASE_CUDA_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \\
      git cmake ninja-build build-essential ca-certificates \\
    && rm -rf /var/lib/apt/lists/*
RUN git clone --no-checkout ${REPO_URL} /src && cd /src && git checkout ${REF}
WORKDIR /src
${PATCH_STEP}
# The devel image ships nvcc/cudart but NOT the real driver (libcuda.so.1 — that's the host
# driver, mounted at container *runtime* via CDI). It does ship a link-time stub at
# .../targets/x86_64-linux/lib/stubs/libcuda.so, but that dir isn't on the default linker search
# path, so ggml-cuda's driver-API calls (cuMemCreate, cuMemRelease, ...) fail to link with
# "undefined reference" (confirmed 2026-09-03 without this). LIBRARY_PATH is what gcc/ld consult
# for -l at link time — set it once for every build step below, don't special-case one target.
ENV LIBRARY_PATH="/usr/local/cuda/targets/x86_64-linux/lib/stubs:\${LIBRARY_PATH}"
# CUDA (sm_120) + CPU (AMX + AVX-512) explicit flags — NOT -march=native, so this image stays
# reproducible/portable across identical-CPU hosts rather than depending on the build host's
# opaque autodetection. If a flag name has drifted on this checkout, \`cmake -B build -LAH |
# grep -i amx\` (or avx512) lists what this exact source tree actually exposes.
# BUILD_SHARED_LIBS=OFF (static): the runtime stage then only needs the binaries, not a matching
# set of .so files copied and ldconfig'd by hand.
RUN cmake -B build -G Ninja \\
      -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} \\
      -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH} \\
      -DGGML_NATIVE=OFF -DBUILD_SHARED_LIBS=OFF \\
      -DGGML_AVX512=ON -DGGML_AVX512_VBMI=ON -DGGML_AVX512_VNNI=ON -DGGML_AVX512_BF16=ON \\
      -DGGML_AMX_TILE=ON -DGGML_AMX_INT8=ON -DGGML_AMX_BF16=ON \\
      -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=${BUILD_TESTS} -DLLAMA_BUILD_EXAMPLES=ON \\
    && cmake --build build --config Release -j"\$(nproc)" \\
      --target llama-server llama-cli llama-mtmd-cli llama-gguf-split llama-perplexity llama-imatrix ${EXTRA_TARGETS}

FROM ${RUNTIME_CUDA_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 libcurl4 curl ${RUNTIME_EXTRA_PKGS} \\
    && rm -rf /var/lib/apt/lists/* \\
    && useradd -m llama   # no -u 1000: this base image already has a UID-1000 user ('ubuntu');
                           # nothing here depends on a specific UID (unlike the LXD dev-server
                           # convention elsewhere in this repo), so just take whatever's free
COPY --from=builder /src/build/bin/ /usr/local/bin/
USER llama
ENTRYPOINT ["/usr/local/bin/llama-server"]
DOCKERFILE

echo ">> building $OUT_IMAGE from $REPO_URL @ $REF (BUILD_SOURCE=$BUILD_SOURCE, sm_$CUDA_ARCH)"
docker build -t "$OUT_IMAGE" "$work"
echo ">> built $OUT_IMAGE"
echo ">> sanity: docker run --rm --device nvidia.com/gpu=all $OUT_IMAGE --version"
