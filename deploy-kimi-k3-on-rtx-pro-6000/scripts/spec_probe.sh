#!/usr/bin/env bash
# Probe a running kimi-k3 llama-server for decode speed and speculative-decoding acceptance.
#   bash spec_probe.sh [label]            # HOST/PORT/MODEL_NAME env as usual
# Sends (a) a repetition-heavy prompt (rewrite a given text — where n-gram drafts shine),
# (b) a plain knowledge prompt, (c) a short code prompt; prints server-side timings incl. draft stats
# (llama-server reports draft_n / draft_n_accepted in `timings` when a --spec-type is active).
set -uo pipefail
HOST="${HOST:-100.68.217.84}"; PORT="${PORT:-30000}"; MODEL_NAME="${MODEL_NAME:-kimi-k3}"; LABEL="${1:-probe}"
B="http://$HOST:$PORT/v1/chat/completions"
TEXT='The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump! The five boxing wizards jump quickly. Sphinx of black quartz, judge my vow. Jackdaws love my big sphinx of quartz. The quick brown fox jumps over the lazy dog again and again while the five boxing wizards keep jumping quickly over the lazy dog.'
q() { # q <name> <prompt> <max_tokens>
  local name="$1" prompt="$2" n="$3"
  python3 - "$B" "$MODEL_NAME" "$name" "$prompt" "$n" "$LABEL" <<'PY'
import sys, json, time, urllib.request
B, model, name, prompt, n, label = sys.argv[1:7]
payload = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": int(n), "temperature": 0}
t0 = time.time()
req = urllib.request.Request(B, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
d = json.load(urllib.request.urlopen(req, timeout=1800))
wall = time.time() - t0
t = d.get("timings", {})
u = d.get("usage", {})
acc = ""
if t.get("draft_n"):
    acc = f" draft_n={t['draft_n']} accepted={t.get('draft_n_accepted')} acc_rate={t.get('draft_n_accepted',0)/max(t['draft_n'],1):.2f}"
print(f"[{label}] {name:10s} prompt_n={t.get('prompt_n')} prompt_ms={t.get('prompt_ms',0):.0f} "
      f"gen_n={t.get('predicted_n')} gen_ms={t.get('predicted_ms',0):.0f} "
      f"decode={t.get('predicted_per_second',0):.2f} tok/s ({t.get('predicted_per_token_ms',0):.1f} ms/tok) wall={wall:.1f}s{acc}")
m = d["choices"][0]["message"]
print("    out:", (m.get("content") or m.get("reasoning_content") or "").strip().replace("\n", " ")[:160])
PY
}
q rewrite  "Rewrite the following text exactly as it is, but replace the word 'quick' with 'swift' everywhere. Output only the rewritten text.\n\n$TEXT" 500
q knowledge "Explain in about 150 words why the sky is blue and why sunsets are red." 200
q code      "Write a Python function that parses an ISO-8601 date string and returns a datetime, with a docstring and two doctests." 200
