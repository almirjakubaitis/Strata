#!/bin/bash
# MMQ A/B on Q2_0: engine-cuda12/strata (built without MMQ, in use today) vs engine-mmq/strata (same tree, -DSTRATA_MMQ=ON).
# Same config otherwise.  A B B A = two pairs, drift cancels.  runs=3 inside each arm (the prompt metrics scatter little).
set -u
cd /home/almir/models-ssd/Strata || exit 1
PY=./.venv/bin/python
OUT=bench/results-mmq
mkdir -p "$OUT"
LOG=bench/ab/driver-mmq.log

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

$PY -c "import regex, sys; sys.path.insert(0, 'tools'); import strata_tokenizer" || {
  echo "FATAL: preflight failed" | tee -a "$LOG"; exit 2
}

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
  local key=$1
  cool
  say "START $key"
  $PY tools/strata_bench.py --config "bench/ab/${key}.json" --port 18080 \
       --out "$OUT" --runs 3 --quiet >>"$LOG" 2>&1
  local rc=$?
  say "END $key rc=$rc gpu=$(nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv,noheader | tr -d ' ')"
  sleep 10
}

say "==== MMQ A/B begin (Q2_0, power limit $(nvidia-smi --query-gpu=power.limit --format=csv,noheader)) ===="
arm q2_0
arm q2_0-mmq
arm q2_0-mmq
arm q2_0
say "==== MMQ A/B done ===="
