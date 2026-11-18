#!/usr/bin/env python3
"""Read the JSONs of one bench/ab/run_probe.sh tag and print the arms, the pairs and the drift floor.

  ./.venv/bin/python bench/ab/analyze_probe.py --tag ple --order mmap,ram,ram,mmap
"""
import argparse
import json
import statistics
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "results-probe"


def load(tag, order):
    rows = []
    for i, arm in enumerate(order, 1):
        p = OUT / f"{tag}-{i}-{arm}.json"
        rows.append((arm, json.loads(p.read_text(encoding="utf-8"))))
    return rows


def val(d, *keys):
    for k in keys:
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--order", required=True, help="comma separated arm names, in run order")
    a = ap.parse_args()
    order = [x.strip() for x in a.order.split(",") if x.strip()]
    rows = load(a.tag, order)

    print(f"{'#':<2} {'arm':<18} {'chat med':>9} {'chat spread':>12} {'agent med':>10} {'agent spread':>13} {'prompt med':>11}")
    for i, (arm, r) in enumerate(rows, 1):
        c = val(r, "chat", "decode_tps") or {}
        g = val(r, "agent", "aggregate_decode_tps") or {}
        p = val(r, "agent", "turn_prompt_tps") or {}
        print(f"{i:<2} {arm:<18} {c.get('median', '-'):>9} {c.get('spread_pct', '-'):>12} "
              f"{g.get('median', '-'):>10} {g.get('spread_pct', '-'):>13} {p.get('median', '-'):>11}")

    def ratio(x, y, *keys):
        a1, b1 = val(x, *keys), val(y, *keys)
        if not a1 or not b1:
            return None
        a1 = a1.get("median") if isinstance(a1, dict) else a1
        b1 = b1.get("median") if isinstance(b1, dict) else b1
        return round(b1 / a1, 3) if a1 else None

    if len(order) % 2 == 0 and len(order) >= 2:
        half = len(order) // 2
        print("\npairs (second over first, same positions):")
        print(f"{'pair':<5} {'chat':>7} {'agent':>7} {'prompt':>7}")
        for k in range(half):
            a1, b1 = rows[k], rows[k + half]
            print(f"{k + 1:<5} {ratio(b1[1], a1[1], 'chat', 'decode_tps') or '-':>7} "
                  f"{ratio(b1[1], a1[1], 'agent', 'aggregate_decode_tps') or '-':>7} "
                  f"{ratio(b1[1], a1[1], 'agent', 'turn_prompt_tps') or '-':>7}")
        same = [i for i in range(half) if rows[i][0] == rows[i + half][0]]
        if same:
            print("\ndrift (same arm on both sides, the probe's noise floor):")
            for k in same:
                a1, b1 = rows[k], rows[k + half]
                print(f"A vs A, position {k + 1}: chat {ratio(b1[1], a1[1], 'chat', 'decode_tps')} "
                      f"agent {ratio(b1[1], a1[1], 'agent', 'aggregate_decode_tps')} "
                      f"prompt {ratio(b1[1], a1[1], 'agent', 'turn_prompt_tps')}")


if __name__ == "__main__":
    main()
