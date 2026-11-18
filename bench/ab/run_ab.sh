#!/bin/bash
# Controlled A/B: Q2_0 vs IQ2_XS, identical flags, interleaved rounds, cooled between arms.
# 6 arms of the full suite (runs=3) + 2 arms without drafting (runs=1).
set -u
cd /home/almir/models-ssd/Strata || exit 1
# the bench starts serve/server.py with its own interpreter, which needs the install's venv (regex, tokenizer)
PY=./.venv/bin/python
OUT=bench/results-ab
mkdir -p "$OUT" bench/ab
LOG=bench/ab/driver.log

$PY -c "import regex, sys; sys.path.insert(0, 'tools'); import strata_tokenizer" || {
  echo "FATAL: $PY cannot import regex/strata_tokenizer; the bench would start a server that cannot load" | tee -a "$LOG"
  exit 2
}

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

cool() {
  local i t
  for i in $(seq 1 90); do
    t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    [ -n "$t" ] && [ "$t" -le 66 ] && { say "cooled to ${t}C"; return 0; }
    sleep 5
  done
  say "WARN: GPU still hot (${t}C) after 450 s"
}

arm() {   # arm <config-key> <runs>
  local key=$1 runs=$2
  cool
  say "START $key (runs=$runs)"
  $PY tools/strata_bench.py --config "bench/ab/${key}.json" --port 18080 \
          --out "$OUT" --runs "$runs" --quiet >>"$LOG" 2>&1
  local rc=$?
  say "END $key rc=$rc  gpu=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.sm --format=csv,noheader | tr -d ' ')"
  sleep 10
}

say "==== A/B begin: Q2_0 vs IQ2_XS, power limit $(nvidia-smi --query-gpu=power.limit --format=csv,noheader) ===="

# main pass: drafting on (MTP spec 4), same flags for both
arm q2_0    3
arm iq2_xs  3
arm iq2_xs  3
arm q2_0    3
arm q2_0    3
arm iq2_xs  3

# isolation pass: no drafting at all
arm q2_0-nospec   1
arm iq2_xs-nospec 1

say "==== A/B done ===="
