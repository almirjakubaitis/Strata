#!/usr/bin/env python3
"""Read the A/B result folders and print the comparison (medians, ranges, paired ratios).

    python bench/ab/analyze.py [ROOT]      ROOT defaults to bench/results-ab

Pairs consecutive runs by folder mtime (the driver alternates the arms), so a round is
(q2_0, iq2_xs) or (iq2_xs, q2_0).  Prints one table per metric and the paired ratios.
"""
from __future__ import annotations

import json
import statistics as st
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def reqs(block) -> list[dict]:
    if not isinstance(block, dict):
        return []
    if "requests" in block and isinstance(block["requests"], list):
        return block["requests"]
    out = []
    for v in block.values():
        if isinstance(v, dict):
            out += reqs(v)
    return out


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return st.median(xs) if xs else None


def fmt(x, nd=1):
    return "-" if x is None else f"{x:.{nd}f}"


def rng(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return f"({min(xs):.1f}-{max(xs):.1f})" if xs else ""


def load(folder: Path) -> dict | None:
    try:
        r = json.loads((folder / "results.json").read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(r, dict) or "machine" not in r or "results" not in r:
        return None
    m = r["machine"]
    res = r["results"]
    chat = [q.get("decode_tps") for q in reqs(res.get("chat", {})) if q.get("ok")]
    ttft = [q.get("ttft_s") for q in reqs(res.get("chat", {})) if q.get("ok")]
    p4 = [q.get("prompt_tps") for q in reqs(res.get("prompts", {}).get("4K", {})) if q.get("ok")]
    p16 = [q.get("prompt_tps") for q in reqs(res.get("prompts", {}).get("16K", {})) if q.get("ok")]
    agent = []
    ag = res.get("agent", {})
    for s in (ag.get("sessions") or []) if isinstance(ag, dict) else []:
        for q in (s if isinstance(s, list) else reqs(s)):
            if isinstance(q, dict) and q.get("ok"):
                agent.append(q.get("decode_tps"))
    if not agent and isinstance(ag, dict):
        agent = [q.get("decode_tps") for q in reqs(ag) if q.get("ok")]
    det = (m.get("gpu_detail") or [{}])[0]
    return {
        "folder": folder, "quant": (m.get("quant") or "?").upper(),
        "chat": chat, "ttft": ttft, "p4": p4, "p16": p16, "agent": agent,
        "power": det.get("power_limit_w"), "temp": det.get("temp_c"),
        "engine": m.get("engine_version"), "mtime": folder.stat().st_mtime,
    }


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "bench" / "results-ab"
    folders = sorted([p for p in root.iterdir() if (p / "results.json").is_file()],
                     key=lambda p: p.stat().st_mtime)
    if not folders:
        print(f"no results under {root}")
        return 1
    runs = [x for x in (load(p) for p in folders) if x]

    print(f"{len(runs)} runs under {root}\n")
    print(f"{'#':>2} {'quant':8} {'W':>5} {'T':>3} {'chat':>6} {'range':>14} {'4K':>6} {'16K':>6} {'agent':>6} folder")
    for i, r in enumerate(runs, 1):
        print(f"{i:>2} {r['quant']:8} {str(r['power']):>5} {str(r['temp']):>3} "
              f"{fmt(med(r['chat'])):>6} {rng(r['chat']):>14} {fmt(med(r['p4'])):>6} "
              f"{fmt(med(r['p16'])):>6} {fmt(med(r['agent'])):>6} {r['folder'].name[:46]}")

    # paired rounds: consecutive runs of different quants
    pairs = []
    i = 0
    while i + 1 < len(runs):
        a, b = runs[i], runs[i + 1]
        if a["quant"] != b["quant"]:
            pairs.append((a, b))
            i += 2
        else:
            i += 1
    if pairs:
        print(f"\npaired rounds ({len(pairs)}): ratio q2_0 / iq2_xs")
        print(f"{'pair':>4} {'chat':>7} {'4K':>7} {'16K':>7} {'agent':>7}")
        ratios = {"chat": [], "p4": [], "p16": [], "agent": []}
        for n, (a, b) in enumerate(pairs, 1):
            q2, iq = (a, b) if a["quant"].startswith("Q2") else (b, a)
            cells = []
            for k in ("chat", "p4", "p16", "agent"):
                x, y = med(q2[k]), med(iq[k])
                if x and y:
                    ratios[k].append(x / y)
                    cells.append(f"{x / y:7.3f}")
                else:
                    cells.append(f"{'-':>7}")
            print(f"{n:>4} " + " ".join(cells))
        print(f"{'med':>4} " + " ".join(
            f"{(st.median(v) if v else 0):7.3f}" for v in ratios.values()))

    # pooled medians per quant (the headline)
    print("\npooled medians")
    for quant in sorted({r["quant"] for r in runs}):
        g = [r for r in runs if r["quant"] == quant]
        for k, label in (("chat", "chat decode"), ("p4", "4K prompt"), ("p16", "16K prompt"), ("agent", "agent decode")):
            xs = [x for r in g for x in r[k] if isinstance(x, (int, float))]
            print(f"  {quant:8} {label:12} median {fmt(med(xs)):>6} {rng(xs):>16} n={len(xs)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
