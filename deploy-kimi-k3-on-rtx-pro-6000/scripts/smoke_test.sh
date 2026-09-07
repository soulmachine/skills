#!/usr/bin/env bash
# Validates a freshly built image BEFORE spending time on the real ~861GB Kimi-K3 checkpoint:
# pulls one small public GGUF and confirms llama-server actually boots and serves a completion.
# Deliberately unrelated to Kimi-K3 — it only proves the build + container/GPU/CDI plumbing work,
# cheaply (seconds, not the ~15min+ a real cold load takes). It does NOT exercise K3's
# architecture-specific code path (--numa/--cache-type-*/--n-cpu-moe only matter once the real
# model loads) — treat a smoke pass as "the image works," not "Kimi-K3 will load."
#   IMAGE=kimi-k3-llamacpp:fork-<shortsha> bash smoke_test.sh
set -euo pipefail
IMAGE="${IMAGE:?set IMAGE, e.g. kimi-k3-llamacpp:fork-883f2c9ba78f}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
SMOKE_REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF"
SMOKE_FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf"
PORT="${SMOKE_PORT:-30099}"
NAME=kimi-k3-smoke

mkdir -p "$HF_HOME/smoke"
LOCAL="$HF_HOME/smoke/$SMOKE_FILE"
if [ ! -f "$LOCAL" ]; then
  echo ">> fetching smoke-test model: $SMOKE_REPO/$SMOKE_FILE"
  curl -fSL -o "$LOCAL" "https://huggingface.co/$SMOKE_REPO/resolve/main/$SMOKE_FILE"
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo ">> starting $IMAGE against the smoke-test model on :$PORT"
docker run -d --name "$NAME" --device nvidia.com/gpu=all \
  -v "$HF_HOME/smoke:/models:ro" \
  -p "127.0.0.1:${PORT}:${PORT}" \
  "$IMAGE" --model "/models/$SMOKE_FILE" -ngl 999 --host 0.0.0.0 --port "$PORT"

echo ">> waiting for server to come up..."
ok=0
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ "$ok" -ne 1 ]; then
  echo "!! server never became healthy — logs:" >&2
  docker logs "$NAME" 2>&1 | tail -80
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  exit 1
fi

echo ">> health OK — requesting a completion"
resp="$(curl -sf "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say OK and nothing else."}],"max_tokens":8}')"
echo "$resp"
docker rm -f "$NAME" >/dev/null 2>&1 || true

if echo "$resp" | grep -qi '"content"'; then
  echo ">> SMOKE TEST PASSED: build works, GPU/CDI plumbing works, server serves completions."
else
  echo "!! SMOKE TEST FAILED: no content in response — see above." >&2
  exit 1
fi
