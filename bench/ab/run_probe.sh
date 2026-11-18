#!/bin/bash
# Interleaved focused probe (bench/ab/decode_probe.py): the same repetition on every arm, only the arm's config differs.
#
#   bash bench/ab/run_probe.sh <tag> "arm1 arm2 arm2 arm1" [probe options, e.g. --mode chat --chat-requests 10]
#
# Each arm is bench/ab/<arm>.json.  The script stops the serving instance on 11434, cools to 66 C before every arm,
# and does NOT restart the server: run bench/ab/restore-server.sh at the end (through the background tool).
set -u
cd /home/almir/models-ssd/Strata || exit 1
PY=./.venv/bin/python
OUT=bench/results-probe
TAG=${1:?usage: run_probe.sh TAG "arms" [probe options]}
ARMS=${2:?usage: run_probe.sh TAG "arms" [probe options]}
shift 2
EXTRA=("$@")            # kept: `set -- $ARMS` below would otherwise overwrite them
mkdir -p "$OUT"
LOG=bench/ab/driver-probe.log
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

set -- $ARMS
for a in "$@"; do
  [ -f "bench/ab/$a.json" ] || { say "FATAL: bench/ab/$a.json is missing"; exit 2; }
done
$PY -c "import regex, sys; sys.path.insert(0, 'tools'); import strata_tokenizer" || {
  echo "FATAL: preflight failed" | tee -a "$LOG"; exit 2
}

say "== stopping the serving instance (port 11434)"
sh bench/ab/stop-server.sh 11434 | tee -a "$LOG"
# A server that is still loading has no listener yet, so stop-server.sh cannot see it; it would keep the GPU and the
# arena of the previous model, and the next arm would start against 400 MiB of free VRAM.
for pid in $(pgrep -f "serve/server\.py.*--port 11434" 2>/dev/null); do
  say "stopping a still-loading server (pid $pid)"
  kill "$pid" 2>/dev/null
done
for i in $(seq 1 90); do
  pgrep -f "serve/server\.py.*--port 11434" >/dev/null 2>&1 || break
  sleep 2
done
pgrep -f "serve/server\.py.*--port 11434" >/dev/null 2>&1 && say "WARN: a server is still alive on 11434"
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

# The previous arm's engine keeps its 31.6 GiB pinned until it really exits (the server process is reaped first), and the
# next arm's arena guard would read that memory as taken.  Wait for the engine and the card to go quiet.
wait_engine_gone() {
  local i
  for i in $(seq 1 60); do
    if ! pgrep -f "strata --serve" >/dev/null 2>&1 && [ -z "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ]; then
      sleep 3
      return 0
    fi
    sleep 2
  done
  say "WARN: an engine or a GPU process is still running before the next arm"
}

node_mem() {
  say "node memory: $(grep -hE 'MemFree|FilePages' /sys/devices/system/node/node*/meminfo | tr -s ' ' | tr '\n' ' ')"
}

i=0
say "==== probe $TAG begin: $ARMS | extra: ${EXTRA[*]} ===="
for a in "$@"; do
  i=$((i + 1))
  wait_engine_gone
  cool
  node_mem
  say "START $TAG arm $i = $a"
  $PY bench/ab/decode_probe.py --config "bench/ab/$a.json" --port 18080 --out "$OUT" \
      --label "$TAG-$i-$a" "${EXTRA[@]}" >>"$LOG" 2>&1
  say "END $TAG arm $i = $a rc=$? gpu=$(nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv,noheader | tr -d ' ')"
  sleep 8
done
say "==== probe $TAG done ===="
say "restart the serving instance: sh bench/ab/restore-server.sh"
