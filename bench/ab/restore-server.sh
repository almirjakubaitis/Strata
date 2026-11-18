#!/bin/sh
# Restarts the server that was running before the A/B (Q2_0, dflash2 drafter, port 11434).
cd /home/almir/models-ssd/Strata || exit 1
exec /home/almir/models-ssd/Strata/.venv/bin/python /home/almir/models-ssd/Strata/serve/server.py \
  --engine strata --config /home/almir/models-ssd/Strata/strata-q2_0.json --port 11434 --open
