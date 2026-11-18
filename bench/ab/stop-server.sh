#!/bin/sh
# Stop the server listening on the given port (default 11434) and wait for the engine to exit, so it flushes
# --expert-profile-save.  Finds the PID through ss, so the caller's own command line never matches.
port="${1:-11434}"
pid=$(ss -ltnp 2>/dev/null | awk -v p=":$port " 'index($0, p) {print}' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
if [ -z "$pid" ]; then echo "nothing listening on $port"; exit 0; fi
echo "stopping pid $pid (port $port)"
kill -TERM "$pid"
i=0
while [ $i -lt 60 ]; do
  kill -0 "$pid" 2>/dev/null || { echo "stopped after ${i}s"; exit 0; }
  sleep 1; i=$((i+1))
done
echo "still alive after 60s"
exit 1
