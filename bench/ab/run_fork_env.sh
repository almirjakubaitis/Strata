#!/bin/bash
# Two env-only questions on the Quadro P6000 (sm_61, GP104), same engine, same config, only environment differs.
#   block 1  A B B A : the 7 switches of the sm_60 table carried by hand  -> are they a win on GP104?
#   block 2  A C C A : the interleaved MMVQ table kIlRows_61 (measured on a Tesla P40, GP102) -> right for GP104?
# Every arm is runs=1; A is the same q2_0.json in both blocks, so the two blocks also give a drift check.
set -u
cd /home/almir/models-ssd/Strata || exit 1
PY=./.venv/bin/python
OUT=bench/results-fork
mkdir -p "$OUT"
LOG=bench/ab/driver-fork.log

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

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

say "==== fork env A/B begin (P6000, power limit $(nvidia-smi --query-gpu=power.limit --format=csv,noheader)) ===="
say "-- block 1: sm_60 switch set carried to sm_61"
arm q2_0
arm q2_0-envmin
arm q2_0-envmin
arm q2_0
say "-- block 2: kIlRows_61 (P40 table) vs native_mmvq"
arm q2_0
arm q2_0-noil
arm q2_0-noil
arm q2_0
say "==== fork env A/B done ===="
