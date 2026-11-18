# Community benchmark on Quadro P6000

Measured on 2026-11-06 with `tools/strata_bench.py` (suite 1, 3 runs per test, medians with ranges). Speeds are the engine's own timings; first-token times are measured by the client over HTTP. Speed only: no correctness check was run.

## Hardware and software

- GPU and VRAM: Quadro P6000, 24 GiB VRAM
- CPU: Intel(R) Xeon(R) CPU           X5670  @ 2.93GHz (12 cores, 24 threads); installed RAM: 94.4 GiB; storage: sda  Patriot Burst Elite 120GB ata; sdb  WDC WD10EZEX-08RKKA0      ata; sdc  WD Green 2.5 480GB        ata
- OS: Linux 6.8.0-147-generic; GPU driver: 580.196.07; CUDA (driver supports up to): 13.0
- Strata: project 0.1.57, commit 9f7d977d; engine 0.1.57
- GPU detail (after the run, near idle): power_limit_w=250.00, power_draw_w=87.44, pcie=gen2 x16, pstate=P0, temp_c=83
- Background workloads: not recorded (GPU power limit/draw read above)

## Model and configuration

- Model and quantization: qwen3.8-flash-next-iq2_xs
- Context: 262144 tokens; parallel slots: 1
- Settings: the install's own configuration, unchanged; thinking off for the suite; temperature 0

```text
strata --pack iq2_xs --native Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf --ple-gguf Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf --expert-profile expert-profile.bin --expert-cache auto --prefill auto --spec 4 --mtp rt --max-context 262144 --kv int8 --ple-io ram --kv-resident 32768 --vision --control-vector-scaled Qwen3.8-Flash-Next-experimental-speed-projection.gguf:1.0 --control-vector-layer-range 4 44 --cvec-mode project --cvec-dir per-layer --spec-min-p 0.70 --pcie-frac 1.00 --adapt-every 1 --adapt-swaps 160 --adapt-decay 0.97 --vram-reserve-mib 1024 --aux-cpus auto
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
| short chat | 46 (43-51) | 0 | 100 (100-100) | 9 | not measured | 43.9 (41.0-48.9) | 0.97 (0.92-1.06) |
| 4K prompt, fresh | 4019 (4019-4019) | 0 (0-0) | 24 cap | 3 | 399.7 (397.1-401.4) | not measured | 10.10 (10.06-10.17) |
| 16K prompt, fresh | 16058 (16058-16058) | 0 (0-0) | 24 cap | 3 | 458.1 (456.5-458.3) | not measured | 35.13 (35.11-35.24) |
| agent session, follow-up turns | 13366 (13361-13372) at the last turn | see below | up to 64 | 3 | see below | 44.5 (35.6-52.8) | 7.93 (4.94-8.57) |

Ranges are the lowest and highest of the runs; `Runs` counts requests that returned a token.

### Agent session (conversation cache)

Cache hit over the follow-up turns: 69.6 % (69.6-69.6); earlier-turn tokens read again per session: 3 (1-4) (earlier turns that the cache did not hold; the 12512 (12507-12512) new tokens of the files are read once); first turn (nothing cached) first token: 4.24 s (3.97-4.33).

| Turn (run 1) | Prompt tokens | Reused | Read | Prompt tok/s | First token (s) | Decode tok/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 609 | 0 | 609 | 155.6 | 3.968 | 25.5 |
| 1 | 3612 | 621 | 2991 | 354.7 | 8.487 | 35.6 |
| 2 | 5145 | 3675 | 1470 | 295.9 | 5.023 | 37.0 |
| 3 | 8389 | 5208 | 3181 | 383.0 | 8.367 | 44.6 |
| 4 | 10612 | 8448 | 2164 | 335.0 | 6.524 | 40.7 |
| 5 | 13366 | 10656 | 2710 | 342.9 | 7.967 | 41.6 |

Per-request data: `results.json`. Engine log lines from the start: `engine-log-excerpt.txt` (when this run started the server).

## Correctness and limitations

Not measured: this is a speed suite. The conversation uses the model's own replies, so token counts differ a little between runs. Machine details come from the server, `nvidia-smi`/`rocm-smi` and the OS; background load is not recorded. Total time of the suite: 321 s.
