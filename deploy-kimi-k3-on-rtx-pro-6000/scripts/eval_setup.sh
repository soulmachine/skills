#!/usr/bin/env bash
# One-time setup for the Kimi-K3 quant-gate / REAP-slicing tooling (host side, no GPU):
#   EVAL=/data/kimi-k3-eval bash eval_setup.sh
# Creates $EVAL with a uv-managed Python 3.12 venv (numpy + gguf-py from a llama.cpp checkout),
# clones 01554/kimi-k3-gguf-prune (byte-exact expert slicer), and fetches the wikitext-2 test
# corpus used as the perplexity/KLD gate text. Needs: uv, git, curl, unzip.
set -euo pipefail
EVAL="${EVAL:-/data/kimi-k3-eval}"
LLAMA_REF="${LLAMA_REF:-master}"
mkdir -p "$EVAL/logits" "$EVAL/scripts" && cd "$EVAL"
[ -d llama.cpp ] || git clone -q --depth 1 --branch "$LLAMA_REF" https://github.com/ggml-org/llama.cpp llama.cpp
[ -d kimi-k3-gguf-prune ] || git clone -q --depth 1 https://github.com/01554/kimi-k3-gguf-prune
[ -x venv/bin/python ] || uv venv --python 3.12 venv
uv pip install --python venv/bin/python -q numpy ./llama.cpp/gguf-py
[ -f wiki.test.raw ] || { curl -fsSL -o wikitext-2-raw-v1.zip https://huggingface.co/datasets/ggml-org/ci/resolve/main/wikitext-2-raw-v1.zip && unzip -o -q wikitext-2-raw-v1.zip && cp wikitext-2-raw/wiki.test.raw . ; }
[ -f calibration_datav3.txt ] || curl -fsSL -o calibration_datav3.txt https://gist.githubusercontent.com/bartowski1182/eb213dccb3571f863da82e99418f81e8/raw/calibration_datav3.txt
[ -f calib.txt ] || { cat calibration_datav3.txt; head -c 600000 wikitext-2-raw/wiki.train.raw; } > calib.txt
chmod -R a+rX wiki.test.raw calib.txt; chmod a+rwx logits   # eval containers run as your uid, but be safe
echo "ready: $EVAL (venv: $EVAL/venv, slicer: $EVAL/kimi-k3-gguf-prune/scripts/prune_gguf.py)"
