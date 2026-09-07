#!/usr/bin/env python3
"""Patch sglang.bench_serving to tolerate SSE comment/keep-alive lines.

Why this exists (measured 2026-09-03, Kimi-K3 on llama.cpp):
  sglang.bench_serving's streaming parsers skip blank lines, strip a "data: " prefix,
  special-case "[DONE]", then json.loads() whatever is left. An SSE *comment* line -- a
  bare ":" -- passes every one of those guards and lands in json.loads(), raising
      json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
  which the client records as a FAILED request and which closes the connection (the
  server then logs "cancel task", i.e. client disconnect).

  SSE comments are spec-legal keep-alives (W3C SSE: a line beginning with ":" is ignored).
  llama.cpp's llama-server emits them while a request waits during slow prefill, so the
  failure only shows up on slow/contended servers -- and scales with concurrency, because
  longer waits mean more keep-alives. On fast servers no keep-alive is ever sent and the
  bug is invisible, which is why it went unnoticed against GPU-resident models.

  Left unpatched this silently destroys benchmark validity: requests are counted as
  failures, "Successful requests" collapses, and Benchmark duration (which still counts
  the wall time of abandoned requests) makes the throughput columns meaningless.

Idempotent: safe to run repeatedly; exits 0 if already patched.
"""
import re
import sys

try:
    import sglang.bench_serving as m
except Exception as e:  # pragma: no cover
    print(f"[sse-patch] cannot import sglang.bench_serving: {e}", file=sys.stderr)
    sys.exit(1)

path = m.__file__
src = open(path).read()

if 'startswith(b":")' in src:
    print("[sse-patch] already patched")
    sys.exit(0)

# Anchor on the empty-line guard that precedes every stream-parsing loop, preserving
# whatever indentation that loop uses (the file has several at different depths).
pattern = re.compile(
    r"(?P<indent>[ \t]+)chunk_bytes = chunk_bytes\.strip\(\)\n"
    r"(?P=indent)if not chunk_bytes:\n"
    r"(?P=indent)    continue\n"
)


def repl(mo):
    i = mo.group("indent")
    return (
        f"{i}chunk_bytes = chunk_bytes.strip()\n"
        f"{i}if not chunk_bytes:\n"
        f"{i}    continue\n"
        f"{i}# SSE comment/keep-alive (':' prefix) is spec-legal and not JSON; llama.cpp\n"
        f"{i}# emits it during slow prefill. Skipping it is what makes slow-server\n"
        f"{i}# benchmarks valid -- see sse_keepalive_patch.py for the full story.\n"
        f"{i}if chunk_bytes.startswith(b\":\"):\n"
        f"{i}    continue\n"
    )


patched, n = pattern.subn(repl, src)
if n == 0:
    print("[sse-patch] WARNING: no stream loop matched -- client version changed; "
          "benchmark results against slow servers may be invalid", file=sys.stderr)
    sys.exit(1)

open(path, "w").write(patched)
print(f"[sse-patch] patched {n} stream loop(s) in {path}")
