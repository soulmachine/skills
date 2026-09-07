#!/usr/bin/env python3
"""Small task-level quality check for a Kimi-K3 llama-server (OpenAI-compatible API).

  quality_eval.py run --label reap770 [--host H --port P] [--gsm8k 40] [--humaneval 30] [--mbpp 0] [--concurrency 8]
  (MBPP: google-research-datasets/mbpp test split; the prompt includes the task's asserts, as is standard)

Greedy decoding, fixed item subsets (first N of each set), so two servers can be compared PAIRWISE:
per-item results are written to $EVAL/quality/results-<label>.json and `compare` prints agreement.
GSM8K: final answer must appear as '#### <number>' (prompted); HumanEval: the model completes the
function, we execute the canonical tests in a subprocess (10 s timeout) with the eval venv's python.
The model reasons before answering (K3 is thinking-only); reasoning_effort=low is requested via
chat_template_kwargs and MAX_TOKENS bounds the total. Truncated items count as wrong and are reported.

  quality_eval.py compare results-reap770.json results-q2kxl.json
"""
import argparse, json, os, re, subprocess, sys, tempfile, time, concurrent.futures as cf, urllib.request

EVAL = os.environ.get("EVAL", "/data/kimi-k3-eval")
Q = os.path.join(EVAL, "quality")

def chat(host, port, model, prompt, max_tokens, timeout=10800):
    payload = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": max_tokens,
               "temperature": 0, "chat_template_kwargs": {"reasoning_effort": "low"}}
    req = urllib.request.Request(f"http://{host}:{port}/v1/chat/completions", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time(); d = json.load(urllib.request.urlopen(req, timeout=timeout)); dt = time.time() - t0
    m = d["choices"][0]["message"]
    return {"content": m.get("content") or "", "reasoning": m.get("reasoning_content") or "",
            "finish": d["choices"][0].get("finish_reason"), "usage": d.get("usage", {}), "secs": round(dt, 1)}

NUM = re.compile(r"-?\d[\d,]*(?:\.\d+)?")
def gsm8k_extract(text):
    m = re.findall(r"####\s*([-\d,\.]+)", text)
    cand = m[-1] if m else (NUM.findall(text)[-1] if NUM.findall(text) else None)
    if cand is None: return None
    cand = cand.replace(",", "").rstrip(".")
    try: return str(int(float(cand))) if float(cand) == int(float(cand)) else cand
    except ValueError: return None

def run_gsm8k(args, items):
    def one(i, it):
        prompt = (it["question"].strip() + "\n\nSolve the problem step by step, then give the final numeric answer "
                  "on its own line in the form '#### <number>'.")
        try:
            r = chat(args.host, args.port, args.model, prompt, args.max_tokens, args.timeout)
        except Exception as e:
            return {"task": "gsm8k", "idx": i, "gold": it["answer"].split("####")[-1].strip().replace(",", ""), "pred": None,
                    "correct": False, "truncated": False, "tokens": None, "secs": None, "error": repr(e)[:200]}
        gold = it["answer"].split("####")[-1].strip().replace(",", "")
        pred = gsm8k_extract(r["content"] if r["content"].strip() else r["reasoning"])
        return {"task": "gsm8k", "idx": i, "gold": gold, "pred": pred, "correct": pred == gold,
                "truncated": r["finish"] == "length", "tokens": r["usage"].get("completion_tokens"), "secs": r["secs"]}
    with cf.ThreadPoolExecutor(args.concurrency) as ex:
        res = list(ex.map(lambda p: one(*p), enumerate(items)))
    return res

def run_humaneval(args, items):
    py = os.path.join(EVAL, "venv", "bin", "python")
    def extract_code(text):
        blocks = re.findall(r"```(?:python)?\n(.*?)```", text, re.S)
        return blocks[-1] if blocks else text
    def one(i, it):
        prompt = ("Complete the following Python function. Return the complete function (signature included) "
                  "in a single ```python code block, with no tests and no extra prose.\n\n```python\n" + it["prompt"] + "```")
        try:
            r = chat(args.host, args.port, args.model, prompt, args.max_tokens, args.timeout)
        except Exception as e:
            return {"task": "humaneval", "idx": i, "task_id": it["task_id"], "correct": False, "truncated": False,
                    "tokens": None, "secs": None, "error": repr(e)[:200]}
        code = extract_code(r["content"]) if r["content"].strip() else ""
        passed = False
        if code.strip():
            prog = it["prompt"].split("def ")[0] + code + "\n\n" + it["test"] + f"\n\ncheck({it['entry_point']})\n"
            with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
                f.write(prog); fn = f.name
            try:
                p = subprocess.run([py, fn], capture_output=True, timeout=10)
                passed = p.returncode == 0
            except subprocess.TimeoutExpired:
                passed = False
            finally:
                os.unlink(fn)
        return {"task": "humaneval", "idx": i, "task_id": it["task_id"], "correct": passed,
                "truncated": r["finish"] == "length", "tokens": r["usage"].get("completion_tokens"), "secs": r["secs"]}
    with cf.ThreadPoolExecutor(args.concurrency) as ex:
        res = list(ex.map(lambda p: one(*p), enumerate(items)))
    return res

def run_mbpp(args, items):
    py = os.path.join(EVAL, "venv", "bin", "python")
    def extract_code(text):
        blocks = re.findall(r"```(?:python)?\n(.*?)```", text, re.S)
        return blocks[-1] if blocks else text
    def one(i, it):
        tests = "\n".join(it["test_list"])
        prompt = (it["text"].strip() + "\n\nYour code should pass these tests:\n```python\n" + tests +
                  "\n```\nReturn the complete Python solution in a single ```python code block, with no tests and no extra prose.")
        try:
            r = chat(args.host, args.port, args.model, prompt, args.max_tokens, args.timeout)
        except Exception as e:
            return {"task": "mbpp", "idx": i, "task_id": it["task_id"], "correct": False, "truncated": False,
                    "tokens": None, "secs": None, "error": repr(e)[:200]}
        code = extract_code(r["content"]) if r["content"].strip() else ""
        passed = False
        if code.strip():
            prog = (it.get("test_setup_code") or "") + "\n" + code + "\n\n" + tests + "\n"
            with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
                f.write(prog); fn = f.name
            try:
                passed = subprocess.run([py, fn], capture_output=True, timeout=10).returncode == 0
            except subprocess.TimeoutExpired:
                passed = False
            finally:
                os.unlink(fn)
        return {"task": "mbpp", "idx": i, "task_id": it["task_id"], "correct": passed,
                "truncated": r["finish"] == "length", "tokens": r["usage"].get("completion_tokens"), "secs": r["secs"]}
    with cf.ThreadPoolExecutor(args.concurrency) as ex:
        res = list(ex.map(lambda p: one(*p), enumerate(items)))
    return res

def summarize(label, res):
    for task in ("gsm8k", "humaneval", "mbpp"):
        rs = [r for r in res if r["task"] == task]
        if not rs: continue
        n = len(rs); c = sum(r["correct"] for r in rs); t = sum(r["truncated"] for r in rs); e = sum(1 for r in rs if r.get("error"))
        toks = sum(r["tokens"] or 0 for r in rs)
        print(f"[{label}] {task:9s} {c}/{n} correct = {100*c/n:.1f} %   truncated {t}   errors {e}   mean completion tokens {toks/n:.0f}")

def compare(paths):
    data = {p: json.load(open(p)) for p in paths}
    labels = [os.path.basename(p) for p in paths]
    for task in ("gsm8k", "humaneval", "mbpp"):
        per = {p: {r["idx"]: r for r in d["results"] if r["task"] == task} for p, d in data.items()}
        idxs = sorted(set.intersection(*[set(v) for v in per.values()]))
        if not idxs: continue
        print(f"== {task}: {len(idxs)} paired items")
        for p in paths:
            c = sum(per[p][i]["correct"] for i in idxs); print(f"   {os.path.basename(p):40s} {c}/{len(idxs)} = {100*c/len(idxs):.1f} %")
        if len(paths) == 2:
            a, b = paths
            agree = sum(per[a][i]["correct"] == per[b][i]["correct"] for i in idxs)
            both = sum(per[a][i]["correct"] and per[b][i]["correct"] for i in idxs)
            only_a = sum(per[a][i]["correct"] and not per[b][i]["correct"] for i in idxs)
            only_b = sum(per[b][i]["correct"] and not per[a][i]["correct"] for i in idxs)
            print(f"   same outcome on {agree}/{len(idxs)}; both right {both}; only {labels[0]} right {only_a}; only {labels[1]} right {only_b}")
            if task == "gsm8k":
                same_pred = sum(per[a][i]["pred"] == per[b][i]["pred"] for i in idxs)
                print(f"   identical final answers on {same_pred}/{len(idxs)}")

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    r = sub.add_parser("run"); r.add_argument("--label", required=True); r.add_argument("--host", default="100.68.217.84")
    r.add_argument("--port", type=int, default=30001); r.add_argument("--model", default="kimi-k3")
    r.add_argument("--gsm8k", type=int, default=40); r.add_argument("--humaneval", type=int, default=30); r.add_argument("--mbpp", type=int, default=0)
    r.add_argument("--concurrency", type=int, default=8); r.add_argument("--max-tokens", type=int, default=2048)
    r.add_argument("--timeout", type=int, default=10800, help="per-request HTTP timeout in seconds (hybrid servers at high concurrency need hours)")
    c = sub.add_parser("compare"); c.add_argument("paths", nargs="+")
    args = ap.parse_args()
    if args.cmd == "compare":
        compare(args.paths); return
    gsm = json.load(open(os.path.join(Q, "gsm8k_test.json")))[:args.gsm8k]
    he = [json.loads(l) for l in open(os.path.join(Q, "HumanEval.jsonl"))][:args.humaneval]
    t0 = time.time(); res = []
    if gsm: r = run_gsm8k(args, gsm); res += r; summarize(args.label, r)
    if he: r = run_humaneval(args, he); res += r; summarize(args.label, r)
    mb = json.load(open(os.path.join(Q, "mbpp_test.json")))[:args.mbpp] if args.mbpp else []
    if mb: r = run_mbpp(args, mb); res += r; summarize(args.label, r)
    out = os.path.join(Q, f"results-{args.label}.json")
    json.dump({"label": args.label, "host": args.host, "port": args.port, "max_tokens": args.max_tokens,
               "reasoning_effort": "low", "elapsed_s": round(time.time() - t0), "results": res}, open(out, "w"), indent=1)
    print(f"wrote {out} in {time.time()-t0:.0f} s")

if __name__ == "__main__":
    main()
