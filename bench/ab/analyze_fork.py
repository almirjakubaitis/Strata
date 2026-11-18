#!/usr/bin/env python3
"""Paired analysis of the fork env runs (bench/ab/run_fork_env.sh).

The bench does not record the arm's config name, so the arms are taken in start order (mtimes) and matched to the
sequence the driver ran:  A B B A A C C A  where A = q2_0.json (today's env), B = q2_0-envmin.json (the seven
table switches off), C = q2_0-noil.json (STRATA_SM61_TABLE=0).

The same A runs twice per block, so the printout also shows the drift between the two A's of a block: an effect
smaller than that drift is not an effect.
"""
import glob
import json
import os
import statistics as st

FOLD = sorted(glob.glob("bench/results-fork/*"), key=os.path.getmtime)
LABELS = ["A", "B", "B", "A", "A", "C", "C", "A"]


def med(xs):
    xs = [x for x in xs if x is not None]
    return st.median(xs) if xs else float("nan")


def metrics(folder):
    r = json.load(open(os.path.join(folder, "results.json")))
    res = r["results"]
    ag = [q for s in (res["agent"].get("sessions") or []) for q in s if q.get("ok")]
    chat = [q for q in (res["chat"].get("requests") or []) if q.get("ok")]
    p4 = [q for q in (res["prompts"]["4K"].get("requests") or []) if q.get("ok")]
    p16 = [q for q in (res["prompts"]["16K"].get("requests") or []) if q.get("ok")]
    m = st.median([q["decode_tps"] for q in ag]) if ag else float("nan")
    return {
        "chat": med([q["decode_tps"] for q in chat]),
        "4K": med([q["prompt_tps"] for q in p4]),
        "16K": med([q["prompt_tps"] for q in p16]),
        "agent": m,
    }


rows = [(lab, metrics(f)) for lab, f in zip(LABELS, FOLD)]
print(f"{'arm':4} {'chat':>7} {'4K':>8} {'16K':>8} {'agent':>7}")
for lab, m in rows:
    print(f"{lab:4} {m['chat']:7.1f} {m['4K']:8.1f} {m['16K']:8.1f} {m['agent']:7.1f}")

for name, idx in (("block 1  envmin/base", [(0, 1), (3, 2)]), ("block 2  noil/base", [(4, 5), (7, 6)])):
    print(f"\n{name}")
    print(f"{'pair':5} {'chat':>7} {'4K':>7} {'16K':>7} {'agent':>7}")
    keys = ("chat", "4K", "16K", "agent")
    for n, (a, b) in enumerate(idx, 1):
        base, other = rows[a][1], rows[b][1]
        print(f"{n:<5} " + " ".join(f"{other[k] / base[k]:7.3f}" for k in keys))

drift_a = [(0, 3), (4, 7)]
print("\ndrift inside each block (A vs A, the noise floor)")
for n, (a, b) in enumerate(drift_a, 1):
    print(f"{n:<5} " + " ".join(f"{rows[b][1][k] / rows[a][1][k]:7.3f}" for k in ("chat", "4K", "16K", "agent")))
