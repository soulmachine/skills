#!/usr/bin/env python3
"""Speculative decoding helpers for bench_sweep.sh (stdlib only; runs on the client host).

  spec.py convert QUESTION_JSONL         Spec-Bench question.jsonl -> custom-loader JSONL (turn 0), stdout
  spec.py categories DATASET             category names in file order, one per line
  spec.py sample DATASET N [CATEGORY]    exactly N rows (category-interleaved, or one category), stdout
  spec.py snap URL                       one JSON line: the server's speculative metrics at URL (/metrics)
  spec.py poll URL OUT                   append a snap to OUT every 2 s until killed (SGLang has gauges only)
  spec.py moved BEFORE AFTER [K]         did a drafter run between two snaps? exit 0 yes, 1 no, 2 cannot tell
  spec.py point RESULT BEFORE AFTER POLL [CATEGORY]   one SPECPOINT/SPECCAT line from a client result
  spec.py compare LOG [LOG...]           off log + on logs (one per k): speedup, best k, crossover, acceptance
  spec.py selftest
"""
import json
import statistics
import sys
import time
import urllib.request

# vLLM and llama.cpp export the same counter family; exact names, so the *_created timestamps and the
# *_per_pos_total series that share the prefix are never summed in.
COUNTERS = {f"{e}:spec_decode_num_{k}_total": (e, k)
            for e in ("vllm", "llamacpp") for k in ("drafts", "draft_tokens", "accepted_tokens")}
GAUGES = {"sglang:spec_accept_length": "len", "sglang:spec_accept_rate": "rate"}


def parse_metrics(text):
    """Prometheus text -> snap dict. engine is set when any metric of a known engine is present."""
    snap = {"engine": None}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        name = line.split("{", 1)[0].split(" ", 1)[0]
        try:
            val = float(line.rsplit(" ", 1)[1])
        except (IndexError, ValueError):
            continue
        prefix = name.split(":", 1)[0]
        if prefix in ("vllm", "llamacpp", "sglang") and snap["engine"] is None:
            snap["engine"] = prefix
        if name in COUNTERS:
            snap["engine"], key = COUNTERS[name]
            snap[key] = snap.get(key, 0.0) + val  # summed over label sets (one per engine/model)
        elif name in GAUGES:
            snap["engine"] = "sglang"
            snap[GAUGES[name]] = max(snap.get(GAUGES[name], 0.0), val)
    snap["spec"] = any(k in snap for k in ("drafts", "len"))
    return snap


def snap(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return parse_metrics(r.read().decode("utf-8", "replace"))
    except Exception as e:  # unreachable, 404 (SGLang without --enable-metrics), ...
        return {"error": f"{url}: {e}"}


def moved(before, after, k=None):
    """(code, word): 0 = a drafter ran, 1 = none, 2 = cannot tell."""
    if "error" in after:
        return 2, f"unknown ({after['error']})"
    if after.get("engine") is None:
        return 2, "unknown (no vllm/sglang/llamacpp metrics)"
    if not after["spec"]:
        return 1, "off"  # vLLM exports the spec counters only when a drafter is configured
    if after["engine"] == "sglang":
        return (0, "on") if after.get("len", 0) > 0 else (1, "off")
    d = after.get("drafts", 0) - before.get("drafts", 0)
    if d <= 0:
        return 1, "off"
    per = (after.get("draft_tokens", 0) - before.get("draft_tokens", 0)) / d
    word = f"on draft_per={per:.2f}"
    if k is not None:
        # vLLM drafts exactly k per step; llama.cpp drafts up to --draft-max.
        bad = abs(per - k) > 0.01 if after["engine"] == "vllm" else per > k + 0.01
        if bad:
            print(f"warning: K={k:g} but the server drafted {per:.2f} tokens per step — wrong K or stale server",
                  file=sys.stderr)
            word += " K_MISMATCH"
    return 0, word


def acceptance(before, after, polls):
    """(accept_len, accept_rate, draft_per); '-' where the engine gives no number."""
    if "drafts" in after and "drafts" in before:
        d = after["drafts"] - before["drafts"]
        t = after.get("draft_tokens", 0) - before.get("draft_tokens", 0)
        a = after.get("accepted_tokens", 0) - before.get("accepted_tokens", 0)
        if d > 0 and t > 0:
            return f"{1 + a / d:.2f}", f"{a / t:.3f}", f"{t / d:.2f}"
    lens = [p["len"] for p in polls if p.get("len", 0) > 0]
    if lens:  # SGLang: mean of the gauge sampled during the point
        rates = [p.get("rate", 0) for p in polls if p.get("len", 0) > 0]
        return f"{statistics.mean(lens):.2f}", f"{statistics.mean(rates):.3f}", "-"
    return "-", "-", "-"


def point(rec, before, after, polls, category=None):
    """One line from the client's --output-details record. Token counts are the retokenized text:
    with EOS on, the client's output_len falls back to max_tokens when the stream has no usage (vLLM)."""
    ok = [i for i, e in enumerate(rec["errors"]) if not e]
    n, dur, gen = rec["completed"], rec["duration"], rec["total_output_tokens_retokenized"]
    decode_s = sum(sum(rec["itls"][i]) for i in ok)  # first token -> last token, per request
    tpot = 1000 * decode_s / max(gen - n, 1)          # token-weighted; ITL is per SSE chunk, not per token
    ttft = 1000 * statistics.median([rec["ttfts"][i] for i in ok]) if ok else 0
    alen, arate, per = acceptance(before, after, polls)
    head = f"SPECCAT cat={category}" if category else "SPECPOINT"
    return (f"{head} c={rec['max_concurrency']} n={n} failed={len(rec['errors']) - len(ok)} gen={gen} "
            f"dur={dur:.2f} out_tok_s={gen / dur:.2f} tpot_ms={tpot:.2f} ttft_ms={ttft:.1f} "
            f"accept_len={alen} accept_rate={arate} draft_per={per}")


def load_rows(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def categories(rows):
    return list(dict.fromkeys(r["category"] for r in rows if "category" in r))


def sample(rows, n, category=None):
    if category:
        pool = [r for r in rows if r.get("category") == category]
    else:  # order by position inside the category, so every prefix keeps the dataset's category mix
        groups = [[r for r in rows if r.get("category") == c] for c in categories(rows)] or [rows]
        keyed = [((i + 0.5) / len(g), gi, r) for gi, g in enumerate(groups) for i, r in enumerate(g)]
        pool = [r for _, _, r in sorted(keyed, key=lambda t: t[:2])]
    if n > len(pool):
        sys.exit(f"spec.py sample: need {n} prompts{' in ' + category if category else ''}, "
                 f"dataset has {len(pool)} — lower PROMPTS_PER/CONC/CAT_N or use a bigger DATASET")
    return pool[:n]


def convert(path):
    for q in load_rows(path):
        yield {"category": q["category"], "question_id": q["question_id"],
               "conversations": [{"role": "user", "content": q["turns"][0]},
                                 {"role": "assistant", "content": ""}]}


def parse_log(path):
    log = {"path": path, "points": {}, "cats": {}, "grid": None, "model": None, "spec": {}, "fails": 0}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("# grid:"):
                log["grid"] = line
            elif line.startswith("# server /v1/models:"):
                log["model"] = line.split(":", 1)[1].split()[0] if line.split(":", 1)[1].split() else "?"
            elif line.startswith("# spec:"):
                log["spec"] = dict(kv.split("=", 1) for kv in line[7:].split() if "=" in kv)
            elif line.startswith("SPECFAIL"):
                log["fails"] += 1
            elif line.startswith(("SPECPOINT", "SPECCAT")):
                kv = dict(x.split("=", 1) for x in line.split()[1:])
                if line.startswith("SPECCAT"):
                    log["cats"][kv["cat"]] = kv
                else:
                    log["points"][int(kv["c"])] = kv
    return log


def compare(paths, out=print):
    logs = [parse_log(p) for p in paths]
    for lg in logs[1:]:
        for key in ("grid", "model"):
            if lg[key] != logs[0][key]:
                out(f"refusing: {key} differs\n  {logs[0]['path']}: {logs[0][key]}\n  {lg['path']}: {lg[key]}")
                return 1
    for lg in logs:
        if "K_MISMATCH" in lg["spec"].get("probe", ""):
            out(f"warning: {lg['path']}: the server drafted a different k than K={lg['spec'].get('K')} ({lg['spec']['probe']})")
        if lg["fails"]:
            out(f"warning: {lg['path']}: {lg['fails']} point(s) produced no client result (SPECFAIL)")
    off = next((lg for lg in logs if lg["spec"].get("SPEC") == "off"), None)
    ons = sorted((lg for lg in logs if lg["spec"].get("SPEC") == "on"), key=lambda lg: float(lg["spec"]["K"]))
    out(f"model {logs[0]['model']}  {logs[0]['grid'][2:] if logs[0]['grid'] else ''}")
    concs = sorted({c for lg in logs for c in lg["points"]})
    cols = ([("off", off)] if off else []) + [(f"k={lg['spec']['K']}", lg) for lg in ons]
    out("conc  " + "".join(f"{name:>34}" for name, _ in cols))
    for c in concs:
        row = f"{c:<6}"
        for name, lg in cols:
            p = lg["points"].get(c)
            if not p:
                row += f"{'-':>34}"
                continue
            cell = f"{float(p['out_tok_s']):.1f}t/s {float(p['tpot_ms']):.1f}ms"
            if lg is not off:
                cell += f" acc{p['accept_len']}"
                if off and c in off["points"]:
                    cell = f"x{float(p['out_tok_s']) / float(off['points'][c]['out_tok_s']):.2f} " + cell
            row += f"{cell:>34}"
        out(row)
    if off and ons:
        for c in concs:
            if c not in off["points"]:
                continue
            o = off["points"][c]
            for lg in ons:  # greedy + lossless: both sides generate the same text, so token totals match
                p = lg["points"].get(c)
                if p and abs(int(p["gen"]) - int(o["gen"])) > 0.05 * max(int(o["gen"]), 1):
                    out(f"warning: c={c} k={lg['spec']['K']} generated {p['gen']} tokens vs off {o['gen']} — "
                        "not a like-for-like pair (temperature > 0, lossy drafter, or failed requests)")
            scored = [(float(lg["points"][c]["out_tok_s"]), lg["spec"]["K"]) for lg in ons if c in lg["points"]]
            if scored:
                best = max(scored)
                verdict = f"k={best[1]} x{best[0] / float(o['out_tok_s']):.2f}"
                out(f"best at c={c}: {verdict if best[0] > float(o['out_tok_s']) else 'off (no k beats it)'}")
        for lg in ons:
            slower = [c for c in concs if c in lg["points"] and c in off["points"]
                      and float(lg["points"][c]["out_tok_s"]) < float(off["points"][c]["out_tok_s"])]
            out(f"crossover k={lg['spec']['K']}: " + (f"c={min(slower)} (spec slower from here)" if slower
                                                     else "none in this grid (spec wins at every point)"))
    cats = list(dict.fromkeys(cat for lg in ons for cat in lg["cats"]))
    if cats:
        out("acceptance by category (c1, accept_len / accept_rate):")
        out(f"{'category':<16}" + "".join(f"{'k=' + lg['spec']['K']:>16}" for lg in ons))
        for cat in cats:
            out(f"{cat:<16}" + "".join(
                f"{(lg['cats'][cat]['accept_len'] + ' / ' + lg['cats'][cat]['accept_rate']) if cat in lg['cats'] else '-':>16}"
                for lg in ons))
    return 0


def selftest():
    import os
    import tempfile
    vllm = """# HELP vllm:spec_decode_num_drafts_total x
vllm:spec_decode_num_drafts_total{engine="0",model_name="m"} 100.0
vllm:spec_decode_num_drafts_created{engine="0",model_name="m"} 1.7e9
vllm:spec_decode_num_draft_tokens_total{engine="0",model_name="m"} 400.0
vllm:spec_decode_num_accepted_tokens_total{engine="0",model_name="m"} 250.0
vllm:spec_decode_num_accepted_tokens_per_pos_total{engine="0",model_name="m",position="0"} 90.0
vllm:num_requests_running{engine="0"} 1.0"""
    s = parse_metrics(vllm)
    assert (s["engine"], s["drafts"], s["draft_tokens"], s["accepted_tokens"]) == ("vllm", 100, 400, 250), s
    b = parse_metrics(vllm.replace(" 100.0", " 50.0").replace(" 400.0", " 200.0").replace(" 250.0", " 150.0"))
    code, word = moved(b, s, 4)
    assert code == 0 and "draft_per=4.00" in word and "K_MISMATCH" not in word, word
    assert moved(b, s, 5)[1].endswith("K_MISMATCH")
    assert moved(s, s) == (1, "off")
    assert acceptance(b, s, []) == ("3.00", "0.500", "4.00"), acceptance(b, s, [])
    plain = parse_metrics("vllm:num_requests_running{engine=\"0\"} 1.0")
    assert moved(plain, plain) == (1, "off") and moved({}, {"error": "x"})[0] == 2
    assert moved({}, parse_metrics("http_requests_total 3"))[0] == 2
    ll = parse_metrics("llamacpp:spec_decode_num_drafts_total 10\nllamacpp:spec_decode_num_draft_tokens_total 60\n"
                       "llamacpp:spec_decode_num_accepted_tokens_total 30\n"
                       "llamacpp:spec_decode_num_accepted_tokens_per_pos_total{position=\"0\"} 9")
    assert ll["engine"] == "llamacpp" and ll["drafts"] == 10 and ll["accepted_tokens"] == 30, ll
    assert moved({}, ll, 8)[0] == 0 and "K_MISMATCH" not in moved({}, ll, 8)[1]  # llama.cpp: per <= K is fine
    sg_off = parse_metrics('sglang:spec_accept_length{model_name="m"} 0.0\nsglang:num_running_reqs 0')
    sg_on = parse_metrics('sglang:spec_accept_length{model_name="m"} 3.1\nsglang:spec_accept_rate{model_name="m"} 0.7')
    assert moved({}, sg_off) == (1, "off") and moved({}, sg_on) == (0, "on")
    assert acceptance({}, sg_on, [sg_on, sg_off, sg_on]) == ("3.10", "0.700", "-")

    # Contract: every prefix keeps the dataset's category mix (acceptance depends on content, so a mix
    # that drifts with concurrency would confound the speedup), and the order is the same every run.
    rows = [{"category": c, "i": i} for c, n in (("big", 40), ("small", 10)) for i in range(n)]
    for n in range(1, 51):
        got = sum(r["category"] == "small" for r in sample(rows, n))
        assert abs(got - n * 0.2) <= 1, (n, got)
    assert sample(rows, 30) == sample(rows, 30) and len(sample(rows, 2, "small")) == 2
    assert all(r["category"] == "small" for r in sample(rows, 10, "small"))
    assert categories(rows) == ["big", "small"]
    try:
        sample(rows, 51)
        raise AssertionError("sample must refuse a dataset that is too small")
    except SystemExit:
        pass

    rec = {"max_concurrency": 8, "completed": 2, "duration": 10.0, "total_output_tokens_retokenized": 202,
           "errors": ["", ""], "itls": [[0.01] * 50, [0.01] * 50], "ttfts": [0.1, 0.3]}
    line = point(rec, b, s, [])
    assert "c=8 n=2 failed=0 gen=202" in line and "out_tok_s=20.20 tpot_ms=5.00 ttft_ms=200.0" in line, line
    assert line.endswith("accept_len=3.00 accept_rate=0.500 draft_per=4.00"), line

    grid = "# grid: CONC=[1 8] dataset=spec_bench.jsonl sha256=abc out=1024 prompts_per=7 temperature=0"
    def mk(spec, pts, cats=(), g=grid):
        fd, p = tempfile.mkstemp(suffix=".log")
        with os.fdopen(fd, "w") as f:
            f.write(f"# server /v1/models: m max_model_len=1\n{g}\n# spec: {spec}\n")
            for c, tps, gen in pts:
                f.write(f"SPECPOINT c={c} n=8 failed=0 gen={gen} dur=1 out_tok_s={tps} tpot_ms=5 ttft_ms=1 "
                        "accept_len=3.00 accept_rate=0.5 draft_per=4.00\n")
            for cat in cats:
                f.write(f"SPECCAT cat={cat} c=1 n=10 failed=0 gen=1 dur=1 out_tok_s=1 tpot_ms=1 ttft_ms=1 "
                        "accept_len=2.50 accept_rate=0.40 draft_per=4.00\n")
        return p
    off = mk("SPEC=off probe=off", [(1, 50, 1000), (8, 300, 1000)])
    k2 = mk("SPEC=on K=2 probe=on", [(1, 80, 1000), (8, 280, 1000)], ["coding"])
    k4 = mk("SPEC=on K=4 probe=on", [(1, 95, 1000), (8, 310, 1500)], ["coding", "math"])
    lines = []
    assert compare([off, k4, k2], lines.append) == 0
    text = "\n".join(lines)
    assert "best at c=1: k=4 x1.90" in text and "best at c=8: k=4 x1.03" in text, text
    assert "crossover k=2: c=8" in text and "crossover k=4: none" in text, text
    assert "c=8 k=4 generated 1500 tokens" in text, text
    assert "coding" in text and text.index("k=2") < text.index("k=4"), text
    k5 = mk("SPEC=on K=5 probe=on_draft_per=4.00_K_MISMATCH", [(1, 90, 1000)])
    with open(k5, "a") as f:
        f.write("SPECFAIL c=8 no client result\n")
    lines = []
    compare([off, k5], lines.append)
    assert "different k than K=5" in lines[0] and "1 point(s) produced no client result" in lines[1], lines
    os.unlink(k5)
    bad = mk("SPEC=on K=6 probe=on", [(1, 99, 1000)], g=grid.replace("out=1024", "out=256"))
    lines = []
    assert compare([off, bad], lines.append) == 1 and "refusing: grid differs" in lines[0], lines
    for p in (off, k2, k4, bad):
        os.unlink(p)
    print("selftest ok")


def main(argv):
    cmd, args = (argv[1], argv[2:]) if len(argv) > 1 else ("", [])
    if cmd == "convert":
        for row in convert(args[0]):
            print(json.dumps(row, ensure_ascii=False))
    elif cmd == "categories":
        print("\n".join(categories(load_rows(args[0]))))
    elif cmd == "sample":
        for row in sample(load_rows(args[0]), int(args[1]), args[2] if len(args) > 2 else None):
            print(json.dumps(row, ensure_ascii=False))
    elif cmd == "snap":
        print(json.dumps(snap(args[0])))
    elif cmd == "poll":
        while True:
            with open(args[1], "a") as f:
                f.write(json.dumps(snap(args[0])) + "\n")
            time.sleep(2)
    elif cmd == "moved":
        code, word = moved(json.loads(args[0]), json.loads(args[1]), float(args[2]) if len(args) > 2 else None)
        print(word)
        return code
    elif cmd == "point":
        rec = load_rows(args[0])[-1]
        polls = load_rows(args[3]) if len(args) > 3 else []
        print(point(rec, json.loads(args[1]), json.loads(args[2]), polls, args[4] if len(args) > 4 else None))
    elif cmd == "compare":
        return compare(args)
    elif cmd == "selftest":
        selftest()
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
