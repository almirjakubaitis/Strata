# Community benchmark on Quadro P6000

Measured on 2026-10-30 with `tools/strata_bench.py` (suite 1, 3 runs per test, medians with ranges). Speeds are the engine's own timings; first-token times are measured by the client over HTTP. Speed only: no correctness check was run.

## Hardware and software

- GPU and VRAM: Quadro P6000, 24 GiB VRAM
- CPU: Intel(R) Xeon(R) CPU           X5670  @ 2.93GHz (12 cores, 24 threads); installed RAM: 94.4 GiB; storage: not measured
- OS: Linux 6.8.0-147-generic; GPU driver: 580.196.07; CUDA: 13.0
- Strata: project 0.1.48.1, commit 7ddc17a3; engine 0.1.48.1
- Background workloads and power limits: not recorded

## Model and configuration

- Model and quantization: qwen3.8-flash-next-iq2_xs
- Context: 262144 tokens; parallel slots: 2
- Settings: the install's own configuration, unchanged; thinking off for the suite; temperature 0

```text
strata --pack iq2_xs --native Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf --ple-gguf Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf --expert-profile expert-profile.bin --expert-cache auto --prefill auto --spec 4 --mtp rt --max-context 262144 --kv int8 --ple-io ram --kv-resident 32768 --vision --control-vector-scaled Qwen3.8-Flash-Next-experimental-speed-projection.gguf:1.0 --control-vector-layer-range 4 44 --cvec-mode project --cvec-dir per-layer --spec-min-p 0.50 --pool-workers 5 --pcie-frac 1.00 --adapt-every 1 --adapt-swaps 80 --adapt-decay 0.97 --vram-reserve-mib 1024 --aux-cpus auto
```

Environment of the config: `STRATA_ADAPT_NOWAIT=1`, `STRATA_ADAPT_LAG=2`, `STRATA_SIDE_MIXER=2`, `STRATA_FUSE_WAIT=2`, `STRATA_B6_MMVQ_ROWS=1`, `STRATA_FUSE_DECODE=1`, `STRATA_GR_UP75=1`, `STRATA_DENSE_F32=1`

## Method

Run by `python tools/strata_bench.py` against the HTTP API of a Strata server (started by the benchmark from the install configuration); model loading is not timed. One warm-up chat and a 1K prompt are discarded first. Every prompt starts with a unique tag, so the conversation cache cannot help the fresh-prompt tests.

- short chat: the three questions of `tools/ab_engine.py`, up to 100 new tokens, 3 runs
- 4K / 16K prompts: generated word lists sized by a calibration request, 24 new tokens, 3 fresh prompts each
- agent session: system prompt and four tools, then 5 turns that each add about 1500 words of a project file and continue from the model's own earlier answers (the way agent clients resend a conversation), 64 new tokens per turn, 3 sessions; the cache numbers come from the answer's usage (`cached_tokens`) and timings (`prompt_n`)
- concurrency (when run): N requests sent at the same moment, total tokens over the wall time of the burst, latency over all requests

## Results

| Configuration | Actual prompt tokens | Reused tokens | Generated tokens | Runs | Prompt tok/s median and range | Decode tok/s median and range | TTFT seconds median and range |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| short chat | 46 (43-51) | 0 | 100 (100-100) | 9 | not measured | 28.9 (21.6-31.5) | 1.32 (1.21-1.61) |
| 4K prompt, fresh | 4019 (4019-4019) | 0 (0-0) | 24 cap | 3 | 407.6 (399.9-408.6) | not measured | 9.93 (9.89-10.10) |
| 16K prompt, fresh | 16058 (16058-16058) | 0 (0-0) | 24 cap | 3 | 457.6 (455.2-465.8) | not measured | 35.17 (34.55-35.36) |
| agent session, follow-up turns | 14606 (14589-14625) at the last turn | see below | up to 64 | 3 | see below | 33.8 (22.6-42.3) | 8.22 (5.56-10.40) |

Ranges are the lowest and highest of the runs; `Runs` counts requests that returned a token.

### Agent session (conversation cache)

Cache hit over the follow-up turns: 69.5 % (69.4-69.5); earlier-turn tokens read again per session: 73 (73-74) (earlier turns that the cache did not hold; the 13729 (13729-13730) new tokens of the files are read once); first turn (nothing cached) first token: 4.75 s (4.64-4.89).

| Turn (run 1) | Prompt tokens | Reused | Read | Prompt tok/s | First token (s) | Decode tok/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 609 | 0 | 609 | 133.2 | 4.636 | 20.1 |
| 1 | 4110 | 642 | 3468 | 335.7 | 10.398 | 22.6 |
| 2 | 5643 | 4103 | 1540 | 244.5 | 6.35 | 29.7 |
| 3 | 9076 | 5706 | 3370 | 340.1 | 9.968 | 30.8 |
| 4 | 11841 | 9133 | 2708 | 323.2 | 8.445 | 32.0 |
| 5 | 14606 | 11889 | 2717 | 333.2 | 8.216 | 27.5 |

Per-request data: `results.json`. Engine log lines from the start: `engine-log-excerpt.txt` (when this run started the server).

## Correctness and limitations

Not measured: this is a speed suite. The conversation uses the model's own replies, so token counts differ a little between runs. Machine details come from the server, `nvidia-smi`/`rocm-smi` and the OS; background load and power limits are not recorded. Total time of the suite: 365 s.
