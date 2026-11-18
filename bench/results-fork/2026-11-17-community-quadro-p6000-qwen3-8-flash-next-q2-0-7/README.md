# Community benchmark on Quadro P6000

Measured on 2026-11-17 with `tools/strata_bench.py` (suite 1, 1 runs per test, medians with ranges). Speeds are the engine's own timings; first-token times are measured by the client over HTTP. Speed only: no correctness check was run.

## Hardware and software

- GPU and VRAM: Quadro P6000, 24 GiB VRAM
- CPU: Intel(R) Xeon(R) CPU           X5670  @ 2.93GHz (12 cores, 24 threads); installed RAM: 94.4 GiB; storage: sda  Patriot Burst Elite 120GB sata; sdb  WD Green 2.5 480GB        sata; sdc  WDC WD10EZEX-08RKKA0      sata
- OS: Linux 6.8.0-149-generic; GPU driver: 580.196.07; CUDA (driver supports up to): 13.0
- Strata: project 0.1.61, commit c7757280; engine 0.1.61
- GPU detail (after the run, near idle): power_limit_w=250.00, power_draw_w=87.62, pcie=gen2 x16, pstate=P0, temp_c=85
- Background workloads: not recorded (GPU power limit/draw read above)

## Model and configuration

- Model and quantization: qwen3.8-flash-next-q2_0
- Context: 262144 tokens; parallel slots: 1
- Settings: the install's own configuration, unchanged; thinking off for the suite; temperature 0

```text
strata --pack q2_0 --native Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00001-of-00002.gguf --ple-gguf Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-00002-of-00002.gguf --expert-profile expert-profile.bin --expert-cache auto --prefill auto --spec 4 --mtp rt --max-context 262144 --kv int8 --ple-io ram --kv-resident 32768 --vision --vram-reserve-mib 1024 --control-vector-scaled Qwen3.8-Flash-Next-experimental-speed-projection.gguf:1.0 --control-vector-layer-range 4 44 --cvec-mode project --cvec-dir per-layer --pcie-frac 1.00 --spec-min-p 0.30 --pool-workers 6 --aux-cpus auto --adapt-every 1 --adapt-swaps 80 --adapt-decay 0.97
```

Environment of the config: `STRATA_ADAPT_NOWAIT=1`, `STRATA_ADAPT_LAG=2`, `STRATA_SIDE_MIXER=2`, `STRATA_FUSE_WAIT=2`, `STRATA_B6_MMVQ_ROWS=1`, `STRATA_FUSE_DECODE=1`, `STRATA_GR_UP75=1`, `STRATA_DENSE_F32=1`, `STRATA_SM61_TABLE=0`

## Method

Run by `python tools/strata_bench.py --runs 1` against the HTTP API of a Strata server (started by the benchmark from the install configuration); model loading is not timed. One warm-up chat and a 1K prompt are discarded first. Every prompt starts with a unique tag, so the conversation cache cannot help the fresh-prompt tests.

- short chat: the three questions of `tools/ab_engine.py`, up to 100 new tokens, 1 runs
- 4K / 16K prompts: generated word lists sized by a calibration request, 24 new tokens, 1 fresh prompts each
- agent session: system prompt and four tools, then 5 turns that each add about 1500 words of a project file and continue from the model's own earlier answers (the way agent clients resend a conversation), 64 new tokens per turn, 1 sessions; the cache numbers come from the answer's usage (`cached_tokens`) and timings (`prompt_n`)
- concurrency (when run): N requests sent at the same moment, total tokens over the wall time of the burst, latency over all requests

## Results

| Configuration | Actual prompt tokens | Reused tokens | Generated tokens | Runs | Prompt tok/s median and range | Decode tok/s median and range | TTFT seconds median and range |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| short chat | 46 (43-51) | 0 | 100 (100-100) | 3 | not measured | 32.2 (30.7-37.6) | 1.05 (1.03-1.13) |
| 4K prompt, fresh | 4019 (4019-4019) | 0 (0-0) | 24 cap | 1 | 442.7 (442.7-442.7) | not measured | 9.13 (9.13-9.13) |
| 16K prompt, fresh | 16058 (16058-16058) | 0 (0-0) | 24 cap | 1 | 487.2 (487.2-487.2) | not measured | 33.04 (33.04-33.04) |
| agent session, follow-up turns | 13109 (13109-13109) at the last turn | see below | up to 64 | 1 | see below | 29.9 (17.7-41.2) | 7.26 (4.55-7.78) |

Ranges are the lowest and highest of the runs; `Runs` counts requests that returned a token.

### Agent session (conversation cache)

Cache hit over the follow-up turns: 69.1 % (69.1-69.1); earlier-turn tokens read again per session: 5 (5-5) (earlier turns that the cache did not hold; the 12324 (12324-12324) new tokens of the files are read once); first turn (nothing cached) first token: 3.37 s (3.37-3.37).

| Turn (run 1) | Prompt tokens | Reused | Read | Prompt tok/s | First token (s) | Decode tok/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 609 | 0 | 609 | 184.2 | 3.367 | 22.0 |
| 1 | 3423 | 618 | 2805 | 389.8 | 7.26 | 29.9 |
| 2 | 4956 | 3486 | 1470 | 327.3 | 4.549 | 33.8 |
| 3 | 8184 | 5019 | 3165 | 410.1 | 7.779 | 41.2 |
| 4 | 10249 | 8218 | 2031 | 362.3 | 5.666 | 27.8 |
| 5 | 13109 | 10251 | 2858 | 375.8 | 7.67 | 17.7 |

Per-request data: `results.json`. Engine log lines from the start: `engine-log-excerpt.txt` (when this run started the server).

## Correctness and limitations

Not measured: this is a speed suite. The conversation uses the model's own replies, so token counts differ a little between runs. Machine details come from the server, `nvidia-smi`/`rocm-smi` and the OS; background load is not recorded. Total time of the suite: 107 s.
