#!/usr/bin/env bash
# Smoke-test a running Kimi-K3 llama.cpp server: health, models, text, vision (fork build only).
#   PORT=30000 bash verify.sh
#   HOST=<lan-ip> bash verify.sh          # override (e.g. cross-host smoke test)
#   SKIP_VISION=1 bash verify.sh          # BUILD_SOURCE=mainline has no --mmproj — skip check 4
set -uo pipefail
PORT="${PORT:-30000}"
HOST="${HOST:-127.0.0.1}"
MODEL_NAME="${MODEL_NAME:-kimi-k3}"
B="http://${HOST}:${PORT}"
py(){ python3 "$@"; }

echo "== 1. /health =="; curl -sS -m 10 "$B/health" -w '  [HTTP %{http_code}]\n' || echo DOWN
echo "== 2. /v1/models =="; curl -sS -m 10 "$B/v1/models" | py -c 'import sys,json;print(" ",[m["id"] for m in json.load(sys.stdin)["data"]])'

echo "== 3. text =="
curl -sS -m 120 "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "{
 \"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Capital of France and the river through it? One sentence.\"}],
 \"max_tokens\":80}" \
 | py -c 'import sys,json;d=json.load(sys.stdin);print("  ",d.get("choices",[{}])[0].get("message",{}).get("content") or d)'

if [ "${SKIP_VISION:-0}" != "1" ]; then
  echo "== 4. vision (base64 data URL) =="
  IMG_URL="${IMG_URL:-https://upload.wikimedia.org/wikipedia/commons/3/3a/Cat03.jpg}"
  IMG_FILE="${IMG_FILE:-/tmp/kimi_k3_verify_img.jpg}"
  curl -sS -A "Mozilla/5.0 (X11; Linux x86_64) kimi-verify/1.0" -m 60 -o "$IMG_FILE" "$IMG_URL" \
    || echo "  (client-side image fetch failed; set IMG_URL or pre-place IMG_FILE)"
  py - "$B" "$IMG_FILE" "$MODEL_NAME" <<'PYEOF'
import sys, base64, json, urllib.request
B, img, model = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    url = "data:image/jpeg;base64," + base64.b64encode(open(img, "rb").read()).decode()
    payload = {"model": model, "messages": [{"role": "user", "content": [
        {"type": "text", "text": "What animal is in this image? One word."},
        {"type": "image_url", "image_url": {"url": url}}]}], "max_tokens": 200}
    req = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req, timeout=180))
    print("  ", out["choices"][0]["message"]["content"])
except Exception as e:
    print("  VISION FAILED:", e, "(if BUILD_SOURCE=mainline this is expected — no --mmproj; "
          "if BUILD_SOURCE=fork, real failure — see vision-probe.py)")
PYEOF
else
  echo "== 4. vision — SKIPPED (SKIP_VISION=1) =="
fi

echo "== 5. tool call =="
curl -sS -m 120 "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "{
 \"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Weather in Tokyo? Use the tool.\"}],
 \"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"weather for a city\",
   \"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],
 \"tool_choice\":\"auto\",\"max_tokens\":300}" \
 | py -c 'import sys,json;d=json.load(sys.stdin);tc=d.get("choices",[{}])[0].get("message",{}).get("tool_calls");print("  ",tc and tc[0]["function"] or "no tool_calls (needs --jinja + a tool-use-capable chat template — check server launch flags)")'
