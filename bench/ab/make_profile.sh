#!/bin/bash
# Build a Q2_0-specific expert profile: serve with the same flags as the A/B arms, let the adaptive tier learn
# under the real suite, then stop the server so the engine writes --expert-profile-save.
set -u
cd /home/almir/models-ssd/Strata || exit 1
PY=./.venv/bin/python
LOG=bench/ab/profile.log
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

$PY - <<'EOF'
import json
from pathlib import Path
NEW = '/home/almir/models-ssd/Strata/data/expert-profile-q2_0.bin'
base = json.loads(Path('bench/ab/q2_0.json').read_text())
c = dict(base)
c['exe'] = '/home/almir/models-ssd/Strata/engine-cuda12/strata'
c['log'] = '/home/almir/models-ssd/Strata/bench/ab/q2_0-profgen.log'
c['port'] = 18080
c['host'] = '127.0.0.1'
c['drafting'] = 'mtp'
a = list(base['args'])
i = a.index('--expert-profile')
del a[i:i + 2]                      # a missing prior is fatal (generate.cpp:6378): start from nothing and learn
a += ['--expert-profile-save', NEW, '--expert-profile-save-every', '1']
c['args'] = a
Path('bench/ab/q2_0-profgen.json').write_text(json.dumps(c, indent=1))
print('profgen profile flags:', ' '.join(a[j] + ' ' + a[j+1] for j in range(len(a)-1) if 'profile' in a[j]))
EOF

say "== stopping the serving instance"
sh bench/ab/stop-server.sh 11434 | tee -a "$LOG"
sleep 5

say "== starting the profile-generating server on 18080"
nohup $PY serve/server.py --engine strata --config bench/ab/q2_0-profgen.json --port 18080 \
      >>bench/ab/profgen-server.log 2>&1 &
spid=$!
for i in $(seq 1 90); do
  h=$(curl -s --max-time 3 http://127.0.0.1:18080/health 2>/dev/null)
  case "$h" in *'"loaded": true'*) say "ready after ${i}0s"; break;; esac
  sleep 5
done
case "$h" in *'"loaded": true'*) ;; *) say "FATAL: server never became ready"; tail -5 bench/ab/profgen-server.log | tee -a "$LOG"; exit 1;; esac

say "== sending the suite (runs=2) so the tier learns"
$PY tools/strata_bench.py --url http://127.0.0.1:18080 --runs 2 --out bench/results-profgen --quiet >>"$LOG" 2>&1
say "bench rc=$?"

say "== stopping (writes the profile)"
sh bench/ab/stop-server.sh 18080 | tee -a "$LOG"
sleep 3
ls -la --time-style=+"%H:%M" data/expert-profile-q2_0.bin 2>/dev/null | tee -a "$LOG" || say "WARN: no profile file"
say "== profile pass done"
