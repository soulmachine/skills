#!/usr/bin/env python3
# Diagnose the vision WARN: dump the FULL chat message (content + reasoning_content + any
# tool/parsed fields) for a solid-red PNG, so we can tell a reasoning-parser routing artifact
# (answer landed in reasoning_content) from a real MoonViT vision failure (nothing at all).
#   python3 vision-probe.py [--base-url http://127.0.0.1:30000] [--model Kimi-K2.6]
import argparse, base64, json, struct, zlib, urllib.request

def red_png_data_url(side=64):
    raw = b"".join(b"\x00" + (b"\xff\x00\x00" * side) for _ in range(side))
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    return "data:image/png;base64," + base64.b64encode(png).decode()

ap = argparse.ArgumentParser()
ap.add_argument("--base-url", default="http://127.0.0.1:30000")
ap.add_argument("--model", default="kimi-k2.6")
ap.add_argument("--api-key", default="")
a = ap.parse_args()

body = {"model": a.model, "max_tokens": 512, "temperature": 0.0,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": "What is the dominant color of this image? Answer with just the color word."},
            {"type": "image_url", "image_url": {"url": red_png_data_url()}}]}]}
req = urllib.request.Request(a.base_url.rstrip("/") + "/v1/chat/completions",
                             data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json",
                                      **({"Authorization": "Bearer " + a.api_key} if a.api_key else {})})
with urllib.request.urlopen(req, timeout=120) as r:
    out = json.load(r)

msg = out["choices"][0]["message"]
print("=== finish_reason:", out["choices"][0].get("finish_reason"))
print("=== content:        ", repr(msg.get("content")))
print("=== reasoning_content:", repr(msg.get("reasoning_content")))
print("=== usage:          ", out.get("usage"))
got = ((msg.get("content") or "") + " " + (msg.get("reasoning_content") or "")).lower()
print("\nVERDICT:", "VISION OK (saw red)" if "red" in got
      else "NO 'red' anywhere — likely real vision failure (MoonViT) or refusal")
