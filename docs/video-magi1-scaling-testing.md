# MAGI-1 Scaling (Testing Phase)

_Last validated: 2026-02-18_

This repository supports chunk-wise prompt hot-swap (24-frame chunks). This guide is a strict testing plan to:

- reduce chunk latency (`TPOC`)
- verify prompt changes apply on chunk boundaries
- keep spend predictable during scaling experiments

Canonical runtime behavior remains in `docs/video-magi1-streaming.md`.
Canonical cost math remains in `docs/budget-analysis.md`.

## Core metrics and acceptance targets

- **TTFC**: Time To First Chunk
- **TPOC**: Time Per Output Chunk (steady-state)
- **Prompt hot-swap latency**: `POST /prompt` to first chunk generated with the new prompt

Real-time playback at 24 fps requires:

- chunk size fixed at 24 frames -> 1 chunk = 1 second
- steady-state target: `TPOC <= 1.0s`

Interactive prompt control target:

- prompt update visible by the very next chunk boundary (no deep queue backlog)

## Preflight checklist (before scaling)

1. Pod is healthy:
   - `prime pods status <POD_ID> -o json`
2. Setup completed:
   - `cd /root/neurodiffusion/VideoDiffusion && bash setup.sh`
3. Weights aligned with config:
   - quant config -> quant weights
   - non-quant config -> non-quant weights
4. Geometry is valid:
   - `video_size_h % 16 == 0`
   - `video_size_w % 16 == 0`

## Cold-start minimization (before any benchmark)

To keep scaling measurements clean (and cheaper), minimize setup overhead first:

1. Prefer Prime custom image/template with MAGI deps preinstalled.
2. Restore wheel/env cache from Cloudflare R2 (`docs/cloudflare-r2.md`).
3. Run a short warmup chunk before recording `TTFC`/`TPOC`.
4. For MAGI tuple publish with `--include-weights`, use real-file weights source:
   - `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/.`
   - avoid symlink-only `MAGI-1/downloads/` publish source.

Without this, first-run compile/network overhead can dominate timing and hide actual inference scaling behavior.

## Baseline prompt-reactive stream profile

Start with one GPU and a small queue so prompt changes are visible quickly.

```bash
cd /root/neurodiffusion/VideoDiffusion

export CUDA_VISIBLE_DEVICES=0
export MAGI_WINDOW_SIZE=1
export QUEUE_LEN=96
export DROP_OLD_ON_PROMPT=1
export JPEG_QUALITY=75

# Optional low-cost compute caps for baseline:
export MAGI_VIDEO_SIZE_H=384
export MAGI_VIDEO_SIZE_W=384
export MAGI_NUM_STEPS=8
export MAGI_NUM_FRAMES=24

python realtime_magi_stream.py 2>&1 | tee /tmp/magi_stream.log
```

Local benchmark (through SSH tunnel to `localhost:8000`):

```bash
python VideoDiffusion/bench_prompt_hot_swap.py --url http://localhost:8000 --rounds 2
```

## Controlled scale matrix

Run in this order. Change one axis at a time.

| Phase | GPUs | Resolution | Steps | Frames | Goal |
| --- | --- | --- | --- | --- | --- |
| A | 1 | 384x384 | 8 | 24 | pipeline proof + baseline `TPOC` |
| B | 1 | 512x512 | 12 | 96 | dynamic multi-chunk quality check |
| C | 2 | 640x640 | 16 | 192 | complexity/throughput check |
| D | 4+ | same as C | same | same | only if C misses `TPOC <= 1s` |

### Tier-specific calibration ladder (enforced by `test_scripted_30s.sh`)

Before final 30-second render, run 6-chunk calibration with tier policy:

1. `4.5B` tier ladder: `1 -> 3 -> 4` GPUs
2. `24B` tier ladder: `4 -> 8` GPUs

Selection rule:

- choose the smallest rung with steady-state `p90 TPOC <= 1.0s`
- if none pass, fallback to the highest tested rung and mark latency target as unmet
- if all runnable rungs fail timing collection, run fails with a calibration-timeout diagnostic (tune `CALIB_TIMEOUT_S` / `CALIB_CHUNKS`)

Latest empirical baseline (`2026-02-18`, `A100 80GB x1`, `384x384`, `8` steps):

- steady-state `p90 TPOC` observed around `6.2s`
- cue application succeeded eventually (`18/18`) but drifted up to `+6` chunks
- this profile is functional for low-cost testing, but not acceptable for near-real-time control
- same profile is validated for non-stream full-length rendering (`720` frames / `30.0s`) via `test_single_chunk.sh`, suitable for low-cost quality checks while latency tuning continues

## First-principles GPU estimate

Measure single-GPU steady-state chunk time (`T1`) for your target profile, then estimate:

- `N_required = ceil(T1 / (1.0 * eta))`
- use `eta=0.70` to `0.85` (parallel efficiency range)

Conservative example (`eta=0.75`):

- `T1=1.6s` -> `N_required=3`
- `T1=2.4s` -> `N_required=4`
- `T1=3.8s` -> `N_required=6`

If queue depth keeps growing at `N_required`, test one step higher GPU count.

## Pricing snapshot (dynamic market)

Always re-query before create:

```bash
prime availability list --gpu-type H100_80GB --regions eu_north -o json
prime availability list --gpu-type RTX4090_24GB --regions eu_north -o json
```

Live sample on 2026-02-16 (lowest observed listing per query):

- `eu_north`, `RTX4090_24GB`, `gpu-count=1`: `$0.6068/h`
- `eu_north`, `H100_80GB`, `gpu-count=1`: `$0.8015/h` (spot)
- `eu_north`, `H100_80GB`, `gpu-count=1`: `$2.29/h` (non-spot)
- `united_states`, `H100_80GB`, `gpu-count=8`: `$23.92/h` (sample listing)

## Budget planning (`$5` test envelope)

Approximate max runtime from the live sample:

- 1x RTX4090 (`$0.6068/h`): `~8.24h`
- 1x H100 spot (`$0.8015/h`): `~6.24h`
- 1x H100 non-spot (`$2.29/h`): `~2.18h`
- 8x H100 (`$23.92/h`, sampled in `united_states`): `~12.5m`

Testing-phase rule:

1. Do setup once.
2. Run short timed experiments (10-20 minutes each).
3. Terminate pod after each batch.

## Budget guard for scripted 30s (`$15` envelope)

`test_scripted_30s.sh` enforces a hard runtime cap:

- `max_runtime_sec = floor((BUDGET_USD * 0.90 / HOURLY_RATE_USD) * 3600)`

Behavior:

1. A watchdog aborts the run at `max_runtime_sec`.
2. Run status is set to `BUDGET_ABORT`.
3. Summary/report artifacts are still written to `VideoDiffusion/.tmp/`.

## Prime-first orchestration entrypoints

Lifecycle runner:

```bash
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode lifecycle \
  --tier 4.5b \
  --budget-usd 15 \
  --selection-goal realtime \
  --min-gpu-count 4 \
  --max-provision-retries 4 \
  --restore-mode auto \
  --runtime-tag <runtime_tag>
```

Selection defaults:

- `--selection-goal realtime` (default): enforces tier `realtime_min_nproc` from policy.
- `--selection-goal cost`: cheapest offer above tier `min_viable_nproc`.
- `--min-gpu-count <N>`: hard lower bound override when you need a specific rung floor.
- `--max-provision-retries <N>`: max total provision attempts with auto failover if selected availability IDs go stale before `prime pods create`.
- retry/provision telemetry is persisted in `VideoDiffusion/.tmp/magi_lifecycle_telemetry_<run_tag>.jsonl`.

Matrix runner:

```bash
bash VideoDiffusion/run_prime_gpu_matrix.sh \
  --tier 24b \
  --budget-usd 15 \
  --slice-usd 3 \
  --restore-mode auto \
  --runtime-tag <runtime_tag>
```

Matrix reports:

- `VideoDiffusion/.tmp/magi_matrix_<tier>.json`
- `VideoDiffusion/.tmp/magi_matrix_<tier>.csv`

## Multi-GPU single-node runtime

MAGI uses distributed execution. For stream experiments:

```bash
export CUDA_VISIBLE_DEVICES=0,1
export MAGI_CP_SIZE=2
export MAGI_PP_SIZE=1
torchrun --standalone --nproc_per_node=2 realtime_magi_stream.py
```

If `/stats` stays at `chunk_idx=-1` across calibration timeouts on multi-GPU runs:

1. retry with `MAGI_CP_SIZE=1` and `MAGI_PP_SIZE=1` first (diagnostic baseline),
2. then increase `MAGI_CP_SIZE` again after confirming chunk production resumes.

For one-shot clip generation:

```bash
VIDEO_MAGE_VISIBLE_DEVICES=0,1 \
VIDEO_MAGE_NPROC=2 \
bash ./test_single_chunk.sh
```

## Knobs that move TPOC fastest

Apply in this order before adding GPUs:

1. Lower `num_steps`
2. Lower resolution
3. Keep `MAGI_WINDOW_SIZE=1` for prompt-reactive behavior
4. Use fp8/quant only when hardware + config pairing is stable
   - For scripted stream runs, prefer `MAGI_FP8=auto` (default) or force `MAGI_FP8=0` on SM80/SM86 if startup is unstable.
5. Reduce stream encode pressure (`JPEG_QUALITY`, queue size)

## Data collection and decision rule

Use stream logs to extract chunk times:

```bash
rg -n "\\[producer\\] Chunk .* total=" /tmp/magi_stream.log
```

Decision:

- If steady-state `TPOC <= 1.0s` and prompt latency is acceptable: lock this profile.
- If not: reduce compute first, then increase GPU count and retest.

Scripted 30s artifacts to inspect:

- `VideoDiffusion/.tmp/*_calibration.json`
- `VideoDiffusion/.tmp/*_script_injection_report.json`
- `VideoDiffusion/.tmp/*_summary.json`

Persist benchmark artifacts to R2 after each run:

- upload JSON/CSV/MP4 into `neurodiffusion/runs/<run_id>/`
- keep local `.tmp` only as short-lived workspace cache

## Cost discipline

- Never leave pods running between test sessions.
- End spend immediately:
  - `prime pods terminate <POD_ID> --yes`
