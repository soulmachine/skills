#!/usr/bin/env python3
"""Turn llama-imatrix per-expert routing counts into a uniform REAP-style keep plan for Kimi-K3.

llama-imatrix (GGUF output) stores, for every MUL_MAT_ID weight it saw, two tensors:
  <weight>.in_sum2  [n_embd_in, n_expert]  sum of squared input activations per expert
  <weight>.counts   [1, n_expert]           number of (token, expert) routings per expert
For blk.L.ffn_gate_exps.weight the counts are exactly the router's selection counts for layer L
over the calibration text — the "hotness" that 01554/kimi-k3-gguf-prune's hotness_to_plan.py uses
(count-based selection recovered ~91% of gate-weighted REAP saliency at keep-640 on this model).

  make_hotness_plan.py --imatrix imatrix-UD-IQ2_XXS.gguf --report            # coverage curve
  make_hotness_plan.py --imatrix ... --keep 770 --out plan_keep770.json      # write the plan

--score count   (default) rank experts by routing count
--score energy  rank by count-weighted activation energy (sum(in_sum2)) — a proxy closer to REAP's
                gate x ||output|| score than raw counts, still not identical.
The plan format matches kimi-k3-mlx's reap_plan.json: {"mode":"uniform","layers":{"L":{"keep":[...]}}}.
"""
import argparse, json, re, sys
import numpy as np
from gguf import GGUFReader

PAT = re.compile(r"^blk\.(\d+)\.ffn_gate_exps\.weight\.(counts|in_sum2)$")

def load(path):
    r = GGUFReader(path)
    counts, energy = {}, {}
    for t in r.tensors:
        m = PAT.match(t.name)
        if not m:
            continue
        L = int(m.group(1)); a = np.asarray(t.data)
        if m.group(2) == "counts":
            counts[L] = a.reshape(-1).astype(np.float64)
        else:                       # in_sum2: ne = [n_embd, n_expert] -> numpy [n_expert, n_embd]
            energy[L] = a.reshape(a.shape[0], -1).sum(axis=1).astype(np.float64) if a.ndim == 2 else a.reshape(-1)
    if not counts:
        sys.exit("no blk.*.ffn_gate_exps.weight.counts tensors found — was the imatrix saved as GGUF?")
    return counts, energy

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--imatrix", required=True)
    ap.add_argument("--keep", type=int)
    ap.add_argument("--out")
    ap.add_argument("--score", choices=["count", "energy"], default="count")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()
    counts, energy = load(a.imatrix)
    layers = sorted(counts)
    n_exp = len(counts[layers[0]])
    score = {L: (counts[L] if a.score == "count" else energy[L]) for L in layers}
    tot = sum(counts[L].sum() for L in layers)
    print(f"layers={len(layers)} ({layers[0]}..{layers[-1]})  experts/layer={n_exp}  "
          f"total routings={tot:.0f} (= tokens x 16 x layers -> ~{tot/16/len(layers):.0f} tokens)")
    zero = sum(int((counts[L] == 0).sum()) for L in layers)
    print(f"experts never routed to in calibration: {zero} of {n_exp*len(layers)}")
    if a.report or not a.keep:
        print(f"{'keep':>5} {'cut%':>5} {'mean cov%':>9} {'worst cov%':>10} {'worst layer':>11}")
        for k in (896, 864, 832, 800, 770, 768, 736, 704, 672, 640, 576, 512, 448):
            if k > n_exp: continue
            cov = []
            for L in layers:
                idx = np.argsort(-score[L], kind="stable")[:k]
                cov.append(counts[L][idx].sum() / max(counts[L].sum(), 1))
            w = int(np.argmin(cov))
            print(f"{k:>5} {100*(1-k/n_exp):>5.1f} {100*np.mean(cov):>9.2f} {100*min(cov):>10.2f} {layers[w]:>11}")
    if a.keep:
        plan = {"mode": "uniform", "score": a.score, "top_k": 16, "num_experts": n_exp,
                "source": a.imatrix, "layers": {}}
        for L in layers:
            idx = np.argsort(-score[L], kind="stable")[:a.keep]
            plan["layers"][str(L)] = {"keep": sorted(int(i) for i in idx)}
        if a.out:
            json.dump(plan, open(a.out, "w"), indent=1)
            print(f"wrote {a.out}: keep {a.keep}/{n_exp} in {len(layers)} layers")

if __name__ == "__main__":
    main()
