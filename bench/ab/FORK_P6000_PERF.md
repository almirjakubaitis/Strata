# Fork `p6000-perf`: Quadro P6000 (sm_61), state and how to resume

Working note for the fork at `/home/almir/models-ssd/Strata-pascal`, branch `p6000-perf`, cut from
`c77572806` of the main checkout `/home/almir/models-ssd/Strata`. It is not upstream documentation: it records what
was done, what was measured, and what is still open, so the work survives an interruption.

Status: **code complete and committed locally on `p6000-perf` (not pushed), CUDA build made, and the deferred
measurements done** - PLE mode, arena placement and fork-vs-installed, all with the focused decoder probe (below).
Production stays on the installed engine, the default arena placement and `--ple-io mmap`.

## The machine (every number below belongs to this box)

| | |
|---|---|
| GPU | Quadro P6000 24 GB, compute capability **6.1** (Pascal GP104), 30 SMs, PCIe `03:00.0`, **NUMA node 0** |
| Link | PCIe **gen2 x16**, power cap **250 W**, 81-85 °C under load |
| CPU | 2 x Xeon X5670 (12 physical cores / 24 threads, **no AVX2**), 2 NUMA nodes, ~48.3 GB each |
| RAM | 94.4 GiB; `numactl -H` free during a run: node 0 363 MB, node 1 133 MB; swap 2 GB with ~820 MB used |
| Disk | SATA SSD; the 38 GB of experts load at 0.40-0.42 GiB/s |
| Driver / CUDA | 580.196.07 / CUDA 12.8, engine built for `61;86` |
| Engine | 0.1.61; the installed engine (`engine-cuda12/strata`) is now the MMQ build (backup `strata.nomq-0.1.61.bak`), and the fork builds with `-DSTRATA_MMQ=ON` too |

## Where the art sits on this box (measured in the main checkout)

Interleaved A/B, same flags on both sides, 250 W, cooled to 66 °C before each arm.

| what | result | notes |
|---|---|---|
| **MMQ prompt kernels** | 4K prompt **+21%** (355-360 -> 429-440 tok/s), 16K **+12%** (429-430 -> 478-485), chat unchanged | Q2_0, 2 pairs, same tree; the build without MMQ is the one that prints `every chunk runs 48 of 48 layers on the int8 kernels` |
| **Q2_0 vs IQ2_XS** | chat 0.968, 4K 1.061, 16K 1.075, agent **0.756** | 3 pairs, `--spec 4`; IQ2_XS wins the agent decode |
| **expert profile per pack** | agent **1.106 / 1.134**, chat 1.076 / 1.066, prompt unchanged; PCIe expert reads 6.65% -> 4.64% | 4 arms A/B/B/A `runs=1`; profile from `--dump-routing` traces + `tools/make_profile_mix.py` |
| **agent gap Q2_0 vs IQ2_XS** | not MTP (draft acceptance 47-52% both) but expert streaming: Q2_0 spikes to 13-14% PCIe reads, IQ2_XS settles at 2-5% | from `--spec 4` logs |

The installed server runs the per-pack profile: `data/expert-profile-q2_0.bin`, 13,488 cache slots.

## The noise floor of this bench, measured (read this before planning a run)

`tools/strata_bench.py --runs 1` gives, per arm, **3 chat requests and 6 agent turns**. Within one arm those scatter:

| metric | spread inside one arm (min..max over its samples) |
|---|---|
| chat decode | 18.5 - 27.5 % of the median |
| agent decode | 43.8 - 85.8 % of the median |

Two arms of the **same** config, run back to back, differ by 4-12% (measured twice, 8 arms):

| drift, same config | chat | 4K prompt | 16K prompt | agent |
|---|---|---|---|---|
| block A1 -> A4 | 0.901 | 0.962 | 0.946 | 0.875 |
| block A5 -> A8 | 0.958 | 0.958 | 0.952 | 0.922 |

So **this design cannot resolve an effect below roughly 10%.** The per-pack profile result (+11-13% agent) sat above
the floor and repeated in both pairs, which is why it was accepted; the two blocks below did not.

`STRATA_ADAPT_NOWAIT=1` (documented upstream as making two starts differ) is **not** the cause here: the arms without
it scatter the same (20.8% / 20.6% chat spread against 21.5% / 26.8% with it).

Any small effect (NUMA, PLE) needs a decoder-only measurement with many repetitions. That tool now exists in the main
checkout: `bench/ab/decode_probe.py`, with the interleaved driver `bench/ab/run_probe.sh` and the analysis
`bench/ab/analyze_probe.py`.

- Each arm runs **10 identical temperature-0 chat requests** (160 tokens, long enough for a steady rate) and **3 agent
  sessions** of 6 turns, each session on a different text from this repository's own docs. Per-request rows are kept;
  the arm's number is the median of the requests (chat) and of the sessions' aggregate decode (agent), both from the
  engine's own `predicted_per_second`.
- The design's own drift, same config on both sides, measured on this box: **chat 0.998** (41.4 vs 41.3 tok/s) and
  **agent 0.3-0.5%** between arms that differ only in position. The per-request spread inside an arm stays 7-18 %
  (chat), which is why the median of ten, not a single run, is the measurement.
- It resolves roughly **1-2 %**, against the ~10 % floor of `strata_bench.py --runs 1`.

## Measured with the focused probe (17-18 Nov, this box)

A/B/B/A on every question: the two arms alternate, so a drift that is a function of position shows up as a sign flip
in the two pairs. Chat and agent are medians of the design above.

| question | arms (in order) | chat ratio, pair 1 / pair 2 | agent ratio, pair 1 / pair 2 | decision |
|---|---|---|---|---|
| PLE `ram` vs `mmap` | mmap,ram,ram,mmap | 0.994 / 0.989 | not run | **keep `mmap`**: equal within the 0.2 % A-vs-A drift, and it frees 26.8 GiB of anonymous RAM (the table becomes a reclaimable file mapping) |
| arena `auto` vs default | fork,auto,auto,fork | 1.022 / 1.020 | 0.996 / 0.965 | **not a valid test**: mbind ran after `cudaHostRegister` had already faulted the arena in, so all four arms were first-touch placement (see the arena section). With the hook, `auto` binds node 0 - where the default already puts the arena |
| arena `interleave` vs default | diag arms | pages 30.56 GiB N0 / 1.08 GiB N1 after the load | - | **no gain possible**: the default already puts the arena on the GPU's node, and automatic NUMA balancing keeps it there |
| fork engine vs installed | installed,fork,fork,installed | 1.066 / 1.001 | 0.999 / 0.996 | **no difference**: the installed engine's own two arms differ by 7 % in chat (arm 1 started at 52 C, the others at 66 C); both second-position arms are ~0.3-0.4 % slower, a position effect, not an engine one |
| MTP vs DFlash2 drafter (Q2_0) | mtp,dflash2,dflash2,mtp | 0.893 / 1.146 | 1.036 / 1.031 | **DFlash2 for chat (13.3 %), agent a wash**: both pairs put DFlash2 above MTP in chat, the agent pairs disagree in sign; prompt equal |

PLE chat medians, in run order: 41.4 / 40.85 / 41.65 / 41.3 tok/s (mmap / ram / ram / mmap). The two ram arms and the
two mmap arms bracket each other; the ratio is below the drift of two identical arms.

Fork-vs-installed medians, in run order: chat 41.85 / 39.15 / 39.25 / 39.1 tok/s, agent 37.56 / 37.34 / 37.61 / 37.48
tok/s, prompt 385.3 / 385.8 / 385.1 / 384.4 tok/s. The fork is the 2nd and 3rd; the installed engine is the 1st and
4th. The installed engine's 41.85 in arm 1 is the outlier of the block, and it is the arm that ran 14 C cooler.

MTP-vs-DFlash2 medians, in run order: chat 33.65 / 39.25 / 37.70 / 34.25 tok/s, agent 39.02 / 35.58 / 37.65 /
34.52 tok/s, prompt 385.7 / 382.85 / 382.15 / 384.0 tok/s. Each arm ran the app's own default for that drafter: MTP
`--spec 4` (with `--lookup-max-t 12`, windows up to 4 tokens, no DFlash2), DFlash2 `--draft dflash2 --draft-conf 0.7
--spec 6` (no MTP layer). Geometric mean of each drafter's two arms: chat 33.95 against 38.47 tok/s (**+13.3 % for
DFlash2**), agent 36.70 against 36.60 (-0.3 %), prompt 384.85 against 382.50 (-0.6 %). The chat gap is draft acceptance
over the ten identical requests: DFlash2 29 of 49 and 28 of 47 (59 %), MTP 61 of 193 and 54 of 180 (30-32 %). Arm 1 (MTP)
started at 56 C while arms 2-4 were cooled to 65-66 C, so the thermal bias ran against the winner. Cost: the MTP layer is
837 MiB of VRAM plus a 178.4 MiB head, the DFlash2 drafter 690 MiB plus 104.2 MiB, which leaves 13,311 expert-cache
slots with MTP against 13,415 with DFlash2.

Decision: production keeps the installed engine (`engine-cuda12/strata`, the MMQ build) and the fork stays a
measurement tree. The fork's sm_61 table is also a no-op for this owner, whose `strata-q2_0.json` sets the same seven
switches by hand.

## What this fork changes

Committed on `p6000-perf` (`6f141f6b1`, `6e2dccad2`, `4dfc773a7`), not pushed:

### 1. sm_61 defaults (`nv_defaults`)

- `src/core/nv_defaults.cpp`: a new `mj == 6 && mn == 1` branch carrying the seven sm_60 switches
  (`STRATA_ADAPT_NOWAIT=1`, `ADAPT_LAG=2`, `SIDE_MIXER=2`, `FUSE_WAIT=2`, `B6_MMVQ_ROWS=1`, `FUSE_DECODE=1`,
  `GR_UP75=1`) to Pascal GP104, with `STRATA_SM61_PERF=0` as the off switch and `STRATA_DEFAULTS=026` leaving the
  table out (it is newer than that release, like sm_121). The print branch says `sm_61 (Pascal GP104)`.
- `include/strata/core/nv_defaults.hpp`: the variable, documented as **carried over, not yet measured card by card**.
- `src/core/nv_defaults_test.cpp`: content equals the sm_60 set, the off switch, empty under 026, and a user-set
  switch wins. `nv_defaults_test: ok`.

Justification is currently *the absence of a measured loss*, not a measured gain — see the block below. For the
machine's owner the table is also a no-op: their `strata-q2_0.json` sets the same seven by hand.

### 2. Arena placement (`STRATA_ARENA_NUMA`)

- `src/core/expert_source.cpp`: `place_arena_numa()`, applied through a hook that `PinnedArena`'s constructor calls
  between `reserve()` and `cudaHostRegister`. That is the only moment a page policy still decides where the bytes
  land: the register must run before anything touches the arena, and it faults in the whole arena on the calling
  thread's node.
- The first version called it from `ArenaExpertSource::open` right after `new PinnedArena`, and that was **too late**.
  Measured: at mbind the arena VMA already held all **31.64 GiB on node 0**, `numa_maps` then reported the policy
  `interleave:0-1` with the same 31.64 GiB on N0, and the mbind had moved nothing. The arms of the first arena A/B
  were first-touch placement in disguise. The hook (commit `4dfc773a7`) fixed the ordering; the diagnostic
  `STRATA_ARENA_NUMA_DEBUG=1` now shows the empty VMA at mbind (node 0: 35.35 GiB free) and the decision it took.
- **The hypothesis was already true by default on this box.** The default first-touch placement, then automatic NUMA
  balancing (`numa_balancing=1`), puts the arena on node 0 - the GPU's node. With `interleave` set before the faults,
  the arena still ended at **30.56 GiB N0 / 1.08 GiB N1**: balancing migrates the pages to the CPUs that touch them.
  `auto` (bind node 0) therefore cannot beat the default, and production keeps `STRATA_ARENA_NUMA` unset.
- `STRATA_ARENA_NUMA=off|0` (default) does nothing, so the default path is the upstream one.
  `auto` = the NUMA node of the first NVIDIA display device (read from sysfs, not assumed to be 0).
  `interleave` = every node evenly. `N` = node N when it has the room, otherwise interleave with the reason printed
  (`MPOL_BIND` a node cannot serve makes the kernel reclaim inside that node). The number is parsed strictly: anything
  that is not a node of this host (`foo`, `auto1`, an out-of-range number) is refused with a line and changes nothing,
  where `atoi` would have read it as node 0.
- The room guard credits `MemFree` **plus** `FilePages` + `SReclaimable`. `MemFree` alone refused node 0 at 0.34 GiB
  while tens of GiB of the pack sat in reclaimable page cache, which is memory `MPOL_BIND` may drop anyway.
- `mbind()` on an untouched anonymous mapping sets the policy only: no page is migrated, no privilege is needed
  (unlike `mbind` with `MPOL_MF_MOVE`, which needs `CAP_SYS_NICE`). A shared arena is skipped.

Why whole-arena and not per-slice: the arena is opened (`generate.cpp:8292`) **before** the CPU pool exists
(`~8420`), so `active_numa_split()` — the plan that tells which core set owns which half of every expert — is not
available at that point. The per-slice version the `FileExpertSource` path uses
(`NumaComplementPlacement`, `expert_source.cpp:580-710`) would need the pool created first. That is a boot reorder,
not a local change, and it was not attempted.

## The two env A/B blocks: run, and inconclusive

`bench/ab/run_fork_env.sh` (main checkout), 8 arms, `runs=1`, analysis with `bench/ab/analyze_fork.py`.

| block | question | chat | 4K | 16K | agent |
|---|---|---|---|---|---|
| 1 pair 1 | do the seven sm_60 switches earn their place on GP104? (`q2_0-envmin` / `q2_0`) | 0.977 | 1.002 | 0.993 | 0.810 |
| 1 pair 2 | idem | 1.000 | 0.984 | 1.004 | 0.695 |
| 2 pair 1 | is `kIlRows_61` (the interleaved MMVQ table **measured on a Tesla P40**) right for GP104? (`q2_0-noil` / `q2_0`) | 0.933 | 1.014 | 1.004 | 0.917 |
| 2 pair 2 | idem | 1.019 | 1.055 | 1.046 | 0.909 |

Against a drift floor of 0.90-0.96 on every metric, **neither question is decided**. What the numbers do support:

- Nothing measurably **hurts**: every ratio is within or next to the floor on at least one pair.
- The table cannot touch the prompt **by construction**: `native_mmvq_il_supported` only accepts 1-8 columns and a
  prompt matmul has far more. Block 2's apparent +1.4 to +5.5% prompt "gain" is noise, and it is a useful check that
  the method can invent an effect where none is possible.
- `src/kernels/cuda/native_mmvq.cu:3811` maps `cc 61 -> kIlRows_61`, so **this card already ran the P40's table
  before this fork**. Nothing here changes what it runs by default.

Recording the two open questions, so that nobody re-runs them the same way: they need the decoder-only measurement,
not another `runs=1` pair. That measurement now exists (`bench/ab/decode_probe.py`); it would take 8 interleaved probe
arms to answer the drop-one question, and the owner's config already sets all seven switches, so it does not change
this box's speed.

## PLE table and `RLIMIT_MEMLOCK`

The engine prints, on every start:

```
strata: the PLE table (26.8 GiB) was not locked in RAM: this program may lock only 11.8 GiB (RLIMIT_MEMLOCK).
```

- The limit was `soft = hard = 12,370,148 KiB` (11.8 GiB); a non-root process cannot raise a hard limit.
  `systemd-run --user --scope -p LimitMEMLOCK=infinity` is refused (the user manager may not set it).
- `/etc/security/limits.d/99-strata-memlock.conf` now holds `almir soft/hard memlock unlimited` (**added by the
  machine's owner**). It applies at **login**: a process tree started before the change keeps the old limit, so a
  server started from the owner's existing session — or from an agent's shell — still prints `was not locked`. Only a
  fresh login (or a root shell) gets `unlimited`.
- Cost of locking: 26.8 GiB of **unreclaimable** memory on a host that already holds ~70 of 94 GiB and has ~820 MB
  in swap. It can push the box into OOM when the desktop asks for RAM. Revert = delete the file.
- The no-privilege alternative is `--ple-io mmap`: the table is served from the page cache (reclaimable), not locked
  and not resident-anonymous. Upstream documents the lock as "measured up to 6% faster in decode (#4671)" — **their
  measurement, not one made here**, and 6% is below this box's noise floor anyway.
- The focused A/B above answers it on this box: **`mmap` and `ram` are equal** within the design's 0.2 % drift
  (0.994 and 0.989, opposite signs), and `mmap` frees 26.8 GiB of anonymous RAM. Production now runs `--ple-io mmap`
  (backup: `strata-q2_0.json.bak-ple-20261118-002434`). The `ram` arm still hit `RLIMIT_MEMLOCK` (11.8 GiB), so what
  was compared is anonymous-resident against file-backed, not the mlock itself.

## How to resume

```sh
# the server the person uses (Q2_0 + dflash2 + the per-pack profile, port 11434)
cd /home/almir/models-msd/Strata && sh bench/ab/restore-server.sh    # through the background tool, not nohup

# stop it without killing the calling shell (finds the listener through ss)
sh bench/ab/stop-server.sh 11434

# one focused arm: 10 identical chat requests, ~2.5 min including the load
./.venv/bin/python bench/ab/decode_probe.py --config bench/ab/q2_0p.json --port 18080 \
    --out bench/results-probe --label mytag-1-installed --mode chat --chat-requests 10

# a whole interleaved A/B/B/A (4 arms, ~20 min) and its analysis
bash bench/ab/run_probe.sh mytag "q2_0p q2_0p-fork q2_0p-fork q2_0p" --mode both --chat-requests 10 --sessions 3
./.venv/bin/python bench/ab/analyze_probe.py --tag mytag --order q2_0p,q2_0p-fork,q2_0p-fork,q2_0p
```

Rules that cost time when broken:

- The bench must run with `./.venv/bin/python` (the system python has no `regex`).
- Nothing CPU- or disk-heavy while a bench runs: it evicts the 38 GB pack from page cache and skews the CPU-side
  expert work. That includes builds and `git worktree add`.
- A server started with `nohup ... &` inside a normal tool call dies with the shell; use the background tool.
- A server that is **still loading** has no listener, so `stop-server.sh` cannot see it while it holds ~23 GiB of VRAM.
  `run_probe.sh` kills `serve/server.py ... --port 11434` by command line before the first arm for that reason.
- The engine's own messages go to the config's `log` path (`bench/ab/q2_0p*.log`), not to the probe's log. That is
  where `STRATA_ARENA_NUMA` and `expert arena` lines are.
- `stop-server.sh` can report `still alive after 60s` while the server is in fact exiting; check the port and
  `nvidia-smi --query-compute-apps` before assuming it failed.
- `--spec 0` is rejected by native packs; use `drafting: off` with `--spec 2`.
- A native pack needs a valid `--expert-profile`: without one `--expert-cache auto` cannot fill VRAM and the server
  never reports loaded (and a profile cannot be generated from nothing; it needs `--dump-routing` traces).
- `pkill -f` with the server's own command line kills the calling shell.

Revert points: `engine-cuda12/strata.nomq-0.1.61.bak` (the release engine without MMQ), `strata-q2_0.json.bak-*`,
and the old shared profile `data/expert-profile.bin` (7 Oct).

## Still open, in the order that would pay

Done in this window: the decoder-only probe (item 1 of the old list), the fork's CUDA build (old item 2), and
`STRATA_ARENA_NUMA` against the default (old item 3, no gain on this box - see above). What is left:

1. **The sm_61 drop-one run** the `nv_defaults.cpp` comment promises (8 interleaved pairs with the probe), if the
   table is ever offered upstream. Until then the comment says "carried over, not measured here", and that is
   accurate.
2. **Upstreaming `STRATA_MMQ`**: it is a build option only (`CMakeLists.txt:112`, default OFF since 0.1.61). The
   +21%/+12% measured here belongs in that request; on this card the option is worth more than the binary size it
   saves. `tools/settings_register.py --check` passes as is.
3. **The driver's first-arm bias**: arm 1 starts at 52 C (idle before it) and every later arm at the 66 C target, and
   in the fork block that alone looked like +7 % chat. Warm the card to the target before arm 1 (or cool to 66 C
   unconditionally) before the next A/B; the probe's own drift is 0.2 %.
4. **The position effect**: the second arm of each pair is consistently ~0.3-0.4 % slower in agent, on both engines.
   Small, but it is why every question above is A/B/B/A and read as a pair, not as one number against another.
5. **`--ple-io` with the mlock actually granted** (a fresh login, `unlimited` memlock): the claim that matters is
   "locked is faster", not "resident is faster". The `mmap` result already frees 26.8 GiB; a locked `ram` arm would
   trade that memory back for an unmeasured gain, and the box has 820 MB in swap, so it needs a measured win to be
   worth it.
6. **The same drafter A/B on IQ2_XS and IQ3_XXS**: the +13.3 % chat / wash agent above is Q2_0 with the per-pack
   profile. The other two packs have their own default `--spec` and their own acceptance, so the result does not carry
   over untested.
