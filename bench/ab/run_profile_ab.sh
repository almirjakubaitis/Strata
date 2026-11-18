#!/bin/bash
# Expert-profile A/B on Q2_0: data/expert-profile.bin (7 Oct, shared by every pack) vs the Q2_0-specific one.
# Same config, same engine (MMQ), same flags; only --expert-profile's path differs.
# Four arms of runs=1 (A B B A): four starts, each with 15 agent turns, so between-start variance is sampled too.
set -u
cd /home/almir/models-ssd/Strata || exit 1
PY=./.venv/bin/python
OUT=bench/results-profile
mkdir -p "$OUT"
LOG=bench/ab/driver-profile.log

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

$PY -c "import regex, sys; sys.path.insert(0, 'tools'); import strata_tokenizer" || {
  echo "FATAL: preflight failed" | tee -a "$LOG"; exit 2
}
[ -s data/expert-profile-q2_0.bin ] || { say "FATAL: data/expert-profile-q2_0.bin is missing or empty"; exit 2; }

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

say "==== profile A/B begin (Q2_0; old = 7 Oct shared, new = per-pack) ===="
arm q2_0
arm q2_0-prof
arm q2_0-prof
arm q2_0
say "==== profile A/B done ===="
