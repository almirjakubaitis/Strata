# Community benchmark on Quadro P6000

Measured on 2026-10-28 with `tools/strata_bench.py` (suite 1, 3 runs per test, medians with ranges). Speeds are the engine's own timings; first-token times are measured by the client over HTTP. Speed only: no correctness check was run.

## Hardware and software

- GPU and VRAM: Quadro P6000, 24 GiB VRAM
- CPU: Intel(R) Xeon(R) CPU           X5670  @ 2.93GHz (12 cores, 24 threads); installed RAM: 94.4 GiB; storage: sda  Patriot Burst Elite 120GB ata; sdb  WDC WD10EZEX-08RKKA0      ata; sdc  WD Green 2.5 480GB        ata
- OS: Linux 6.8.0-147-generic; GPU driver: 580.196.07; CUDA (driver supports up to): 13.0
- Strata: project 0.1.53, commit 46c152a1; engine 0.1.53
- GPU detail (after the run, near idle): power_limit_w=250.00, power_draw_w=88.70, pcie=gen2 x16, pstate=P0, temp_c=83
- Background workloads: not recorded (GPU power limit/draw read above)

## Model and configuration

- Model and quantization: qwen3.8-flash-next-coder-iq1_m
- Context: 262144 tokens; parallel slots: 1
- Settings: the install's own configuration, unchanged; thinking off for the suite; temperature 0

```text
strata --pack coder-iq1_m --native Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf --ple-gguf Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf --expert-profile expert-profile-coder.bin --expert-cache auto --prefill auto --spec 4 --mtp rt --max-context 262144 --kv int8 --ple-io ram --kv-resident 32768 --vision --vram-reserve-mib 700 --control-vector-scaled Qwen3.8-Flash-Next-experimental-speed-projection.gguf:1.0 --control-vector-layer-range 4 44 --cvec-mode project --cvec-dir per-layer --pcie-frac 1.00 --spec-min-p 0.70 --adapt-every 1 --adapt-swaps 160 --adapt-decay 0.97
```

Environment of the config: `STRATA_ADAPT_NOWAIT=1`, `STRATA_ADAPT_LAG=2`, `STRATA_SIDE_MIXER=2`, `STRATA_FUSE_WAIT=2`, `STRATA_B6_MMVQ_ROWS=1`, `STRATA_FUSE_DECODE=1`, `STRATA_GR_UP75=1`, `STRATA_DENSE_F32=1`

## Method

Run by `python tools/strata_bench.py` against the HTTP API of a Strata server (already running); model loading is not timed. One warm-up chat and a 1K prompt are discarded first. Every prompt starts with a unique tag, so the conversation cache cannot help the fresh-prompt tests.

- short chat: the three questions of `tools/ab_engine.py`, up to 100 new tokens, 3 runs
- 4K / 16K prompts: generated word lists sized by a calibration request, 24 new tokens, 3 fresh prompts each
- agent session: system prompt and four tools, then 5 turns that each add about 1500 words of a project file and continue from the model's own earlier answers (the way agent clients resend a conversation), 64 new tokens per turn, 3 sessions; the cache numbers come from the answer's usage (`cached_tokens`) and timings (`prompt_n`)
- concurrency (when run): N requests sent at the same moment, total tokens over the wall time of the burst, latency over all requests

## Results

| Configuration | Actual prompt tokens | Reused tokens | Generated tokens | Runs | Prompt tok/s median and range | Decode tok/s median and range | TTFT seconds median and range |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| short chat | 46 (43-51) | 0 | 100 (100-100) | 9 | not measured | 33.2 (27.8-42.7) | 1.17 (1.06-1.44) |
| 4K prompt, fresh | 4019 (4019-4019) | 0 (0-0) | 24 cap | 3 | 430.6 (426.5-433.9) | not measured | 9.38 (9.31-9.47) |
| 16K prompt, fresh | 16058 (16058-16058) | 0 (0-0) | 24 cap | 3 | 473.9 (471.3-486.0) | not measured | 33.97 (33.12-34.15) |
| agent session, follow-up turns | 12907 (12906-12944) at the last turn | see below | up to 64 | 3 | see below | 39.2 (31.5-50.6) | 6.46 (4.01-8.54) |

Ranges are the lowest and highest of the runs; `Runs` counts requests that returned a token.

### Agent session (conversation cache)

Cache hit over the follow-up turns: 69.3 % (69.3-69.3); earlier-turn tokens read again per session: 74 (73-74) (earlier turns that the cache did not hold; the 12063 (12063-12064) new tokens of the files are read once); first turn (nothing cached) first token: 3.16 s (2.96-3.40).

| Turn (run 1) | Prompt tokens | Reused | Read | Prompt tok/s | First token (s) | Decode tok/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 609 | 0 | 609 | 210.0 | 2.963 | 24.1 |
| 1 | 3358 | 629 | 2729 | 417.1 | 6.616 | 31.5 |
| 2 | 4891 | 3422 | 1469 | 357.0 | 4.179 | 32.2 |
| 3 | 8135 | 4884 | 3251 | 383.6 | 8.543 | 36.7 |
| 4 | 10202 | 8197 | 2005 | 389.2 | 5.216 | 39.1 |
| 5 | 12906 | 10223 | 2683 | 415.7 | 6.522 | 38.3 |

Per-request data: `results.json`. Engine log lines from the start: `engine-log-excerpt.txt` (when this run started the server).

## Correctness and limitations

Not measured: this is a speed suite. The conversation uses the model's own replies, so token counts differ a little between runs. Machine details come from the server, `nvidia-smi`/`rocm-smi` and the OS; background load is not recorded. Total time of the suite: 307 s.
