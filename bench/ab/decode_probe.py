#!/usr/bin/env python3
"""Focused decode probe (bench-local, not shipped with the app).

tools/strata_bench.py answers "how does this box do on a wide mix", but on the Quadro P6000 its arms scatter 18-27 %
(chat) and 44-86 % (agent) per sample, so an effect under ~10 % is invisible.  This probe trades breadth for
repetition: the same work, many times, temperature 0, and the engine's own `predicted_per_second`.

  chat   N identical short requests (default 10)          -> decode tok/s, steady state, warm expert cache
  agent  S sessions of 6 turns, each a different text     -> per-session aggregate decode and prompt tok/s

Two arms of the SAME config give this probe's drift floor; that ratio is what any effect has to beat.

  ./.venv/bin/python bench/ab/decode_probe.py --config bench/ab/q2_0p.json --port 18080 \\
      --out bench/results-probe --label q2_0-mmap --mode both --chat-requests 10 --sessions 3

  --attach   use a server that is already running on --port instead of starting/stopping one (smoke tests)
"""
import argparse
import json
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import strata_bench as sb  # noqa: E402

# One fixed question, answers in 150-200 tokens: long enough for a steady decode rate, short enough to repeat.
CHAT_PROMPT = ("Explique em um paragrafo direto por que uma placa de video antiga pode ser mais lenta que uma nova "
               "em modelos de linguagem, mesmo tendo bastante memoria. Cite dois fatores concretos.")
CHAT_MAX = 160
DOCS = ("README.md", "docs/HOW_IT_WORKS.md", "docs/DETAILS.md", "docs/INSTALL.md", "docs/MODELS.md",
        "docs/COMMUNITY_BENCHMARKS.md")


def stats(values, digits=3):
    v = [x for x in values if isinstance(x, (int, float))]
    if not v:
        return None
    med = statistics.median(v)
    return {"n": len(v), "median": round(med, digits), "mean": round(statistics.fmean(v), digits),
            "min": round(min(v), digits), "max": round(max(v), digits),
            "stdev": round(statistics.stdev(v), digits) if len(v) > 2 else None,
            "spread_pct": round((max(v) - min(v)) / med * 100, 1) if med else None}


def corpus():
    """One long text built from this repository's own documents (nothing personal)."""
    words = []
    for rel in DOCS:
        p = ROOT / rel
        if p.is_file():
            words += p.read_text(encoding="utf-8", errors="replace").split()
    if len(words) < 20000:
        words += sb.long_prompt(20000).split()
    return words


def window(words, start, size):
    start %= max(1, len(words) - size - 1)
    return " ".join(words[start:start + size])


def chat_round(base, key, n, log=print):
    log("  chat warm-up (2 requests, not measured) ...")
    for i in range(2):
        sb.chat(base, key, [{"role": "user", "content": f"[warm {i}] {sb.PROMPTS[0]}"}], 24)
    rows = []
    for i in range(n):
        d = sb.digest(sb.chat(base, key, [{"role": "user", "content": CHAT_PROMPT}], CHAT_MAX))
        rows.append(d)
        log(f"  chat {i + 1}/{n}: decode {d['decode_tps']} tok/s, {d['generated_tokens']} tokens, "
            f"first token {d['ttft_s']} s" + ("" if d["ok"] else f"  FAILED: {d['err']}"))
    good = [r for r in rows if r["ok"]]
    return {"requests": rows, "decode_tps": stats([r["decode_tps"] for r in good]),
            "generated_tokens": stats([r["generated_tokens"] for r in good]),
            "ttft_s": stats([r["ttft_s"] for r in good])}


def agent_session(base, key, nonce, files, log=print):
    """The harness's agent session (tools/strata_bench.py: agent_session), with the texts passed in."""
    msgs = [{"role": "system", "content": f"{sb.SYSTEM}\n(session {nonce})"},
            {"role": "user", "content": "I will show you files from a project one at a time. After each file, answer in "
                                        "one or two sentences what it is for. Do not call tools."}]
    turns = []
    for t in range(sb.AGENT_TURNS + 1):
        if t > 0:
            rel, body = files[t - 1]
            msgs.append({"role": "user", "content": f"File {rel}:\n{body}\n\nWhat is this file for? Two sentences."})
        r = sb.chat(base, key, msgs, sb.AGENT_MAX_TOKENS, False, tools=sb.TOOLS)
        d = sb.digest(r)
        d["turn"] = t
        turns.append(d)
        if not d["ok"]:
            log(f"    turn {t} FAILED: {d['err']}")
            break
        msgs.append({"role": "assistant", "content": r["text"] or "Understood."})
    return turns


def session_metrics(turns):
    good = [d for d in turns if d["ok"]]
    gen = sum(d["generated_tokens"] or 0 for d in good)
    ms = sum(d["decode_ms"] or 0 for d in good)
    return {"turns": len(turns), "ok_turns": len(good),
            "aggregate_decode_tps": round(gen / (ms / 1000.0), 2) if ms else None,
            "turn_decode_tps": stats([d["decode_tps"] for d in good]),
            "turn_prompt_tps": stats([d["prompt_tps"] for d in good]),
            "prompt_tokens_last": good[-1]["prompt_tokens"] if good else None}


def agent_round(base, key, sessions, words, log=print):
    log("  agent warm-up (one session on other text, not measured) ...")
    warm = [(f"warm/part{i}.txt", window(words, 40000 + i * 1500, 1500)) for i in range(sb.AGENT_TURNS)]
    agent_session(base, key, "warm", warm)
    out = []
    for s in range(sessions):
        files = [(f"docs/part{s}-{i}.txt", window(words, s * 9000 + i * 1500, 1500))
                 for i in range(sb.AGENT_TURNS)]
        turns = agent_session(base, key, f"probe{s}", files)
        m = session_metrics(turns)
        m["session"] = s
        out.append(m)
        log(f"  agent session {s + 1}/{sessions}: {m['aggregate_decode_tps']} tok/s aggregate, "
            f"turn decode {m['turn_decode_tps'] and m['turn_decode_tps']['median']} tok/s, "
            f"prompt {m['turn_prompt_tps'] and m['turn_prompt_tps']['median']} tok/s")
    return {"sessions": out,
            "aggregate_decode_tps": stats([m["aggregate_decode_tps"] for m in out]),
            "turn_prompt_tps": stats([x for m in out for x in
                                      ([m["turn_prompt_tps"]["median"]] if m["turn_prompt_tps"] else [])])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=False, help="a run config (exe/args/env), as tools/strata_bench.py takes")
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--out", default="bench/results-probe")
    ap.add_argument("--label", default="arm")
    ap.add_argument("--mode", choices=("chat", "agent", "both"), default="both")
    ap.add_argument("--chat-requests", type=int, default=10)
    ap.add_argument("--sessions", type=int, default=3)
    ap.add_argument("--attach", action="store_true")
    a = ap.parse_args()

    base = f"http://127.0.0.1:{a.port}"
    key = ""
    proc, log_path, cfg = None, Path(a.out) / f"{a.label}.log", None
    if not a.attach:
        if not a.config:
            ap.error("--config is needed unless --attach")
        cfg_path = Path(a.config)
        cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
        log_path.parent.mkdir(parents=True, exist_ok=True)
        proc = sb.start_server(cfg_path, a.port, None, log_path)
    out_dir = Path(a.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    if not sb.wait_ready(base, key, proc, 900, log=print):
        print("the server did not become ready", file=sys.stderr)
        sb.stop_server(proc)
        sys.exit(2)

    result = {"label": a.label, "config": a.config, "mode": a.mode, "port": a.port,
              "engine": (cfg or {}).get("exe"), "env": (cfg or {}).get("env") or {},
              "started": time.strftime("%Y-%m-%dT%H:%M:%S")}
    temperature = sb.run_cmd("nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv,noheader,nounits") \
        if hasattr(sb, "run_cmd") else ""
    result["gpu_before"] = temperature.replace("\n", " ")

    try:
        words = corpus()
        if a.mode in ("agent", "both"):
            print(f"agent: {a.sessions} sessions ...")
            result["agent"] = agent_round(base, key, a.sessions, words)
        if a.mode in ("chat", "both"):
            print(f"chat: {a.chat_requests} identical requests ...")
            result["chat"] = chat_round(base, key, a.chat_requests)
    finally:
        result["elapsed_s"] = round(time.time() - t0, 1)
        result["gpu_after"] = (sb.run_cmd("nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv,noheader,nounits")
                               if hasattr(sb, "run_cmd") else "")
        (out_dir / f"{a.label}.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
        sb.stop_server(proc)

    print(json.dumps({"label": a.label,
                      "chat_decode": (result.get("chat") or {}).get("decode_tps"),
                      "agent_decode": (result.get("agent") or {}).get("aggregate_decode_tps"),
                      "elapsed_s": result["elapsed_s"]}, indent=1))


if __name__ == "__main__":
    main()
