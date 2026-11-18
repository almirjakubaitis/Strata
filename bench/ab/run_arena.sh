#!/bin/bash
# Does placing the expert arena on the GPU's NUMA node pay on this box?
# Both arms run the FORK engine (same tree, same flags, same env plus one): A = the upstream first-touch placement,
# B = STRATA_ARENA_NUMA=auto (the page policy is set before the load touches the arena).  A B B A, runs=1.
# Read chat (the CPU pool's short-prompt share) and agent (the GPU's PCIe misses) separately: the proposal moves
# pages toward the GPU's socket and away from the pool's second slice, so one of the two can lose.
set -u
cd /home/almir/models-msd/Strata || exit 1
PY=./.venv/bin/python
OUT=bench/results-arena
FORK=/home/almir/models-msd/Strata-pascal/build-cuda12/strata
mkdir -p "$OUT"
LOG=bench/ab/driver-arena.log
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

[ -x "$FORK" ] || { say "FATAL: $FORK is missing (build it first)"; exit 2; }
$PY -c "import regex, sys; sys.path.insert(0, 'tools'); import strata_tokenizer" || {
  echo "FATAL: preflight failed" | tee -a "$LOG"; exit 2
}

say "== stopping the serving instance (port 11434)"
sh bench/ab/stop-server.sh 11434 | tee -a "$LOG"
sleep 5

cool() {
  local i t
  for i in $(seq 1 90); do
    t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    [ -n "$t" ] && [ "$t" -le 66 ] && { say "cooled to ${t}C"; return 0; }
    sleep 5
  done
  say "WARN: GPU still hot (${t}C)"
}

arm() {
  cool
  say "START $1"
  $PY tools/strata_bench.py --config "bench/ab/$1.json" --port 18080 --out "$OUT" --runs 1 --quiet >>"$LOG" 2>&1
  say "END $1 rc=$? gpu=$(nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv,noheader | tr -d ' ')"
  sleep 10
}

say "==== arena NUMA A/B begin (fork engine, Q2_0) ===="
arm q2_0-fork
arm q2_0-arena
arm q2_0-arena
arm q2_0-fork
say "==== arena NUMA A/B done ===="
say "placement actually reached:"
grep -h "STRATA_ARENA_NUMA" bench/ab/q2_0-arena.log | tail -2 | tee -a "$LOG"
