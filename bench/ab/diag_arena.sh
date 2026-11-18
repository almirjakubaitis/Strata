#!/bin/bash
# One arena arm with STRATA_ARENA_NUMA_DEBUG=1: the numbers the guard sees, and where the arena's pages really are.
# Starts the probe, samples the live engine once the port is up, then lets the probe stop it.
set -u
cd /home/almir/models-ssd/Strata || exit 1
PY=./.venv/bin/python
CFG=${1:-bench/ab/q2_0p-arena.json}
$PY -c "import json,sys; p=sys.argv[1]; c=json.load(open(p)); c['env']['STRATA_ARENA_NUMA_DEBUG']='1'; json.dump(c, open(p,'w'), indent=1)" "$CFG" || exit 2
rm -f bench/results-probe/diag-arena.json bench/results-probe/diag-arena.log
$PY bench/ab/decode_probe.py --config "$CFG" --port 18080 --out bench/results-probe --label diag-arena \
    --mode chat --chat-requests 10 > /tmp/opencode/diag-arena.out 2>&1 &
PROBE=$!
for i in $(seq 1 150); do ss -ltn 2>/dev/null | grep -q ':18080' && break; sleep 2; done
PID=$(pgrep -f "[S]trata-pascal/build-cuda12/strata --serve" | head -1)
echo "== probe $PROBE, engine ${PID:-none}, port up after $((i * 2)) s"
if [ -n "${PID:-}" ]; then
  echo "== largest anonymous VMAs:"
  awk '{anon=0; for(k=3;k<=NF;k++) if($k ~ /^anon=/){split($k,a,"=");anon=a[2]+0} if(anon>100000) printf "%10.2f GiB  %s %s\n", anon*4/1048576, $1, $2}' /proc/$PID/numa_maps | sort -nr | head -5
  echo "== per policy:"
  awk '{pol=$2; n0=0;n1=0;anon=0; for(k=3;k<=NF;k++){if($k ~ /^N0=/){split($k,a,"=");n0=a[2]+0} else if($k ~ /^N1=/){split($k,a,"=");n1=a[2]+0} else if($k ~ /^anon=/){split($k,a,"=");anon=a[2]+0}} t[pol]+=n0+n1; p0[pol]+=n0; p1[pol]+=n1; ta[pol]+=anon} END{for(k in t) printf "%-14s %8.2f GiB N0 %.2f N1 %.2f anon %.2f\n", k, t[k]*4/1048576, p0[k]*4/1048576, p1[k]*4/1048576, ta[k]*4/1048576}' /proc/$PID/numa_maps | sort -k2 -nr
  echo "== smaps_rollup:"
  grep -E "^Rss|^AnonHugePages|^Shmem" /proc/$PID/smaps_rollup 2>/dev/null
fi
wait "$PROBE"
echo "== probe rc=$?"
LOG=$($PY -c "import json,sys; print(json.load(open(sys.argv[1])).get('log',''))" "$CFG")
echo "== debug lines ($LOG):"
grep "ARENA_NUMA debug" "$LOG" | tail -4 | cut -c1-270
echo "== decision:"
grep "STRATA_ARENA_NUMA" "$LOG" | tail -2 | cut -c1-270
