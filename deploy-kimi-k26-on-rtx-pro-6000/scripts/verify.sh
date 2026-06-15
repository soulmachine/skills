#!/usr/bin/env bash
# Smoke-test a running Kimi-K2.6 server (engine-agnostic — SGLang or vLLM): health, models,
# text, tool-call, vision.
#   PORT=30000 bash verify.sh                  # default: 127.0.0.1 (server binds 0.0.0.0, so loopback works)
#   HOST=<lan-ip> bash verify.sh               # override (e.g. to smoke-test a peer across the LAN)
# The server runs --network host bound to 0.0.0.0, so loopback is the stable, DHCP-proof target.
set -uo pipefail
PORT="${PORT:-30000}"
HOST="${HOST:-127.0.0.1}"
B="http://${HOST}:${PORT}"
py(){ python3 "$@"; }

echo "== 1. /health =="; curl -sS -m 10 "$B/health" -w '  [HTTP %{http_code}]\n' || echo DOWN
echo "== 2. /v1/models =="; curl -sS -m 10 "$B/v1/models" | py -c 'import sys,json;print(" ",[m["id"] for m in json.load(sys.stdin)["data"]])'

echo "== 3. text (thinking off) =="
curl -sS -m 120 "$B/v1/chat/completions" -H 'Content-Type: application/json' -d '{
 "model":"kimi-k2.6","messages":[{"role":"user","content":"Capital of France and the river through it? One sentence."}],
 "chat_template_kwargs":{"thinking":false},"max_tokens":80}' \
 | py -c 'import sys,json;print("  ",json.load(sys.stdin)["choices"][0]["message"]["content"])'

echo "== 4. tool call (kimi_k2 parser) =="
curl -sS -m 120 "$B/v1/chat/completions" -H 'Content-Type: application/json' -d '{
 "model":"kimi-k2.6","messages":[{"role":"user","content":"Weather in Tokyo? Use the tool."}],
 "tools":[{"type":"function","function":{"name":"get_weather","description":"weather for a city",
   "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
 "tool_choice":"auto","max_tokens":300}' \
 | py -c 'import sys,json;tc=json.load(sys.stdin)["choices"][0]["message"].get("tool_calls");print("  ",tc and tc[0]["function"])'

echo "== 5. vision (base64 data URL) =="
# NB: send images as a base64 data URL. Server-side image_url URL-fetch uses a default `requests`
# User-Agent that some hosts (e.g. Wikimedia) 403 — that's a fixture issue, NOT a MoonViT failure.
# So fetch CLIENT-side with a real UA, then inline as base64 (the server never fetches the URL).
IMG_URL="${IMG_URL:-https://upload.wikimedia.org/wikipedia/commons/3/3a/Cat03.jpg}"
IMG_FILE="${IMG_FILE:-/tmp/kimi_verify_img.jpg}"
curl -sS -A "Mozilla/5.0 (X11; Linux x86_64) kimi-verify/1.0" -m 60 -o "$IMG_FILE" "$IMG_URL" \
  || echo "  (client-side image fetch failed; set IMG_URL or pre-place IMG_FILE)"
py - "$B" "$IMG_FILE" <<'PYEOF'
import sys, base64, json, urllib.request
B, img = sys.argv[1], sys.argv[2]
try:
    url = "data:image/jpeg;base64," + base64.b64encode(open(img, "rb").read()).decode()
    payload = {"model": "kimi-k2.6", "messages": [{"role": "user", "content": [
        {"type": "text", "text": "What animal is in this image? One word."},
        {"type": "image_url", "image_url": {"url": url}}]}],
        "chat_template_kwargs": {"thinking": False}, "max_tokens": 200}
    req = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req, timeout=180))
    print("  ", out["choices"][0]["message"]["content"])
except Exception as e:
    print("  VISION FAILED:", e, "(MoonViT works on sm_120; if truly broken, vLLM --mm-encoder-tp-mode data)")
PYEOF
