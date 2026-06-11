#!/usr/bin/env bash
# Smoke-test a running Kimi-K2.6 SGLang server: health, models, text, tool-call, vision.
#   PORT=30000 bash verify.sh
set -uo pipefail
PORT="${PORT:-30000}"; B="http://127.0.0.1:${PORT}"
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

echo "== 5. vision (gating check) =="
IMG="${IMG_URL:-https://upload.wikimedia.org/wikipedia/commons/3/3a/Cat03.jpg}"
curl -sS -m 180 "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "{
 \"model\":\"kimi-k2.6\",\"messages\":[{\"role\":\"user\",\"content\":[
   {\"type\":\"text\",\"text\":\"What animal is in this image? One word.\"},
   {\"type\":\"image_url\",\"image_url\":{\"url\":\"$IMG\"}}]}],\"max_tokens\":200}" \
 | py -c 'import sys,json
try: print("  ",json.load(sys.stdin)["choices"][0]["message"]["content"])
except Exception as e: print("  VISION FAILED:",e,"(fall back to vLLM --mm-encoder-tp-mode data)")'
