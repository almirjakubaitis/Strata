# `bench/ab`: controlled A/B measurements on a Quadro P6000

This directory is the harness built for one question: how much does a small change move **decode** on this box, when
`tools/strata_bench.py --runs 1` cannot see it? It is bench-local and is not shipped with the app.

The numbers it produced are in [`FORK_P6000_PERF.md`](FORK_P6000_PERF.md), copied from the measurement fork. Raw JSONs
are in `../results-probe/`, `../results-ab/`, `../results-mmq/`, `../results-fork/` and `../results-profile/`; the
suite's own community results are in `../results/`.

## Why a second harness

On the Quadro P6000 a `strata_bench.py --runs 1` arm is 3 chat requests and 6 agent turns. Inside one arm, chat
scatters 18-28 % and agent 44-86 % around the median; two arms of the **same** config differ by 4-12 %. The floor is
therefore about 10 %, and an effect smaller than that needs a different design, not more arms.

`decode_probe.py` trades breadth for repetition:

| mode | what one arm runs | the arm's number |
|---|---|---|
| `chat` | 10 identical temperature-0 requests, 160 new tokens each, after 2 warm-ups | median of the 10 engine `predicted_per_second` |
| `agent` | 3 sessions of 6 turns (1 introduction + 5 files), each session on a different text from this repository | median of the sessions' aggregate decode |

Every arm starts a fresh server from its JSON config, so the expert cache is warm but no conversation cache carries
over. `run_probe.sh` alternates the arms A/B/B/A, cools the GPU to 66 C before each one, and waits for the previous
engine to release its pinned arena.

The design's own drift, same config on both sides of a block: **chat 0.998** and **agent 0.3-0.5 %**. It resolves about
**1-2 %**. The per-request spread inside an arm stays 7-18 % (chat), which is why the median of ten, not a single run,
is the measurement.

## Files

| file | what it does |
|---|---|
| `decode_probe.py` | one arm: start the server from a config, run chat and/or agent, write one JSON |
| `run_probe.sh` | interleaved driver: stops the serving instance, cools, runs the arms in order, logs node memory |
| `analyze_probe.py` | reads a tag's JSONs and prints arms, pair ratios and the same-config drift floor |
| `q2_0p*.json` | arm configs: installed engine, fork engine, `--ple-io ram/mmap`, arena, MMQ and sm_61 variants |
| `diag_arena.sh` | one arena arm with `STRATA_ARENA_NUMA_DEBUG=1`, sampling `numa_maps` during the load |
| `build_fork.sh` | reproducible CUDA build of the measurement fork (needs `STRATA_ISA_FLOOR=none` on this Xeon) |
| `run_ab.sh`, `run_mmq.sh`, `run_profile_ab.sh`, `run_fork_env.sh`, `run_arena.sh` | the earlier suite-level A/B blocks (`runs=1` or `runs=3`); kept as the raw record |
| `restore-server.sh`, `stop-server.sh` | this box's serving instance and a port-based stop that cannot match the caller |
| `traces-q2_0/` | routing traces (`--dump-routing`) used to build the per-pack expert profile |

## Running it

Prerequisites: the checkout's venv (`./.venv/bin/python`; the system python lacks `regex`), the model files, a valid
expert profile, a CUDA engine and `nvidia-smi`.

The configs here are this box's: absolute paths under `/home/almir/models-ssd/`, a Q2_0 pack, the per-pack profile and
the owner's environment switches. Copy one and change `exe`, `args`, `cwd`, `tokenizer`, `log`, `lib_dirs` and `env`
for another machine.

One arm (no A/B; starts and stops its own server):

```sh
./.venv/bin/python bench/ab/decode_probe.py --config bench/ab/q2_0p.json --port 18080 \
    --out bench/results-probe --label smoke --mode chat --chat-requests 10
```

A whole interleaved block, then the analysis:

```sh
bash bench/ab/run_probe.sh mytag "q2_0p q2_0p-fork q2_0p-fork q2_0p" --mode both --chat-requests 10 --sessions 3
./.venv/bin/python bench/ab/analyze_probe.py --tag mytag --order q2_0p,q2_0p-fork,q2_0p-fork,q2_0p
```

`analyze_probe.py` prints every arm (median and spread) and, for an even number of arms, each second-position arm over
its first-position partner. When both sides of a pair are the same config those ratios are the drift floor; an effect
must beat them with the same sign in both pairs.

`--attach` uses a server already listening on `--port` (smoke tests only; it starts and stops nothing).

## What the blocks found

All of these belong to this box; the full record, including the wrong turns, is in `FORK_P6000_PERF.md`.

| question | design | result |
|---|---|---|
| MMQ prompt kernels (Q2_0) | 2 suite pairs | 4K prompt **+21 %** (355-360 -> 429-440 tok/s), 16K **+12 %** (429-430 -> 478-485), chat unchanged |
| Q2_0 vs IQ2_XS | 3 suite pairs | chat 0.968, 4K 1.061, 16K 1.075, agent **0.756**: IQ2_XS wins the agent decode |
| per-pack expert profile | 4 suite arms | agent **1.106 / 1.134**, chat 1.076 / 1.066, prompt unchanged |
| PLE `mmap` vs `ram` | focused probe, A/B/B/A | 0.994 / 0.989: equal within drift; `mmap` frees 26.8 GiB of anonymous RAM |
| fork engine vs installed | focused probe, A/B/B/A | chat 1.066 / 1.001, agent 0.999 / 0.996: no difference (arm 1 of the block ran 14 C cooler) |
| arena on the GPU's NUMA node | probe + `numa_maps` | the default already lands on node 0 and balancing keeps it there; `auto` cannot improve it |

Nothing measured here justified publishing the `p6000-perf` code branch: its sm_61 table is the seven switches this
owner already sets by hand, and the arena switch cannot beat the default on this host. The harness and the findings
are the reusable part.

## Rules that cost time when broken

- One engine at a time. A server that is still loading has no listener but holds about 23 GiB of VRAM; stop it by
  command line, not only through the port.
- Nothing CPU- or disk-heavy while an arm runs: it evicts the 38 GB pack from page cache and skews the CPU-side expert
  work. That includes builds and `git worktree add`.
- Start a long-running server through the harness's background tool. `nohup ... &` inside a normal tool call dies with
  the shell.
- `stop-server.sh` can print `still alive after 60s` while the process is exiting; check the port and
  `nvidia-smi --query-compute-apps` before assuming failure.
- `pkill -f` with the server's own command line kills the calling shell.
- A native pack needs a valid `--expert-profile`; without one `--expert-cache auto` cannot fill VRAM and the server
  never reports loaded.
- `--spec 0` is rejected by native packs; use `drafting: off` with `--spec 2`.
- Restore the serving instance after a block: `sh bench/ab/restore-server.sh` (this box's Q2_0 on port 11434).
