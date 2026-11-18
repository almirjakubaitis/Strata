#!/bin/bash
# Build a Q2_0-specific expert profile the sanctioned way: routing traces of representative prompts
# (tools/collect_profile_traces.py --mode routing), then a weighted mix (tools/make_profile_mix.py).
set -u
cd /home/almir/models-ssd/Strata || exit 1
PY=./.venv/bin/python
LOG=bench/ab/profile-trace.log
TRACES=bench/ab/traces-q2_0
NEW=/home/almir/models-ssd/Strata/data/expert-profile-q2_0.bin
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# one-shot trace config: the A/B args, no drafter (a draft's tokens are verified but not produced: they would
# pollute the trace), --spec 2 is the minimum a native pack accepts
$PY - <<'EOF'
import json
from pathlib import Path
base = json.loads(Path('bench/ab/q2_0.json').read_text())
a = list(base['args'])
i = a.index('--spec'); a[i+1] = '2'
if '--mtp' in a: del a[a.index('--mtp'):a.index('--mtp')+2]
if '--vision' in a: a.remove('--vision')
c = dict(base); c['args'] = a
c['exe'] = '/home/almir/models-ssd/Strata/engine-cuda12/strata'
c['log'] = '/home/almir/models-ssd/Strata/bench/ab/trace-one-shot.log'
c.pop('drafting', None)
Path('bench/ab/q2_0-trace.json').write_text(json.dumps(c, indent=1))
print('trace config: spec 2, sem --mtp, sem --vision')
EOF

say "== stopping the serving instance"
sh bench/ab/stop-server.sh 11434 | tee -a "$LOG"
sleep 5

mkdir -p "$TRACES"
say "== collecting routing traces (prompts 1, 9, 36, 37: code, code-error, tool, summary)"
$PY tools/collect_profile_traces.py bench/ab/q2_0-trace.json "$TRACES" \
    --mode routing --max-new 200 --only 1,9,36,37 >>"$LOG" 2>&1
say "collect rc=$?"
ls -la "$TRACES" | tee -a "$LOG"

say "== building the mixed profile"
$PY tools/make_profile_mix.py "$TRACES"/*.trace --out "$NEW" >>"$LOG" 2>&1
say "mix rc=$?"
ls -la --time-style=+"%H:%M" "$NEW" 2>/dev/null | tee -a "$LOG" || say "WARN: no profile"
say "== trace pass done"
