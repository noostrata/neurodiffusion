# VideoDiffusion (MAGI-1)

Canonical source of truth:

- `docs/video-magi1-streaming.md`
- `docs/cloudflare-r2.md` (artifact/cache persistence)

This file is a fast operator summary for the `VideoDiffusion/` folder.

## Run order

```bash
cd /root/neurodiffusion/VideoDiffusion
bash setup.sh
bash download_weights.sh
# Use `hf auth login` before download if needed.
bash ./test_single_chunk.sh
python realtime_magi_stream.py
```

For repeated runs, fastest boot path is:

1. Prime custom image with dependencies preinstalled.
2. Restore wheel/env caches from Cloudflare R2.
3. Run only delta setup and generation.
4. Push outputs/reports back to R2, then terminate pod.

## Smoke profiles

Cheapest proof-of-life (1 chunk):

```bash
VIDEO_MAGE_PROMPT="Slow dolly shot through a busy cyberpunk alley at night, neon signs flickering, light rain, passing cars and pedestrians moving" \
VIDEO_MAGE_OUTPUT=magi_try.mp4 \
VIDEO_MAGE_FP8=auto \
VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_quant_config.json \
VIDEO_MAGE_VISIBLE_DEVICES=0 \
VIDEO_MAGE_NPROC=1 \
VIDEO_MAGE_NUM_FRAMES=24 \
VIDEO_MAGE_NUM_STEPS=8 \
VIDEO_MAGE_WINDOW_SIZE=1 \
VIDEO_MAGE_VIDEO_SIZE_H=384 \
VIDEO_MAGE_VIDEO_SIZE_W=384 \
bash ./test_single_chunk.sh
```

Reliable non-quant smoke (SM80/SM86 friendly):

```bash
VIDEO_MAGE_WEIGHT_VARIANT=4.5B_distill \
VIDEO_MAGE_FP8=0 \
VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_config.json \
VIDEO_MAGE_VISIBLE_DEVICES=0 \
VIDEO_MAGE_NPROC=1 \
VIDEO_MAGE_PROMPT="Slow dolly shot through a busy cyberpunk alley at night, neon signs flickering, light rain, passing cars and pedestrians moving" \
VIDEO_MAGE_OUTPUT=magi_dynamic_nonquant.mp4 \
bash ./test_single_chunk.sh
```

4-second dynamic shot:

```bash
VIDEO_MAGE_PROMPT="Handheld tracking shot through a dense cyberpunk market at night, neon reflections in wet pavement, moving crowd, animated holograms, drifting steam, parallax signage, passing bikes, cinematic motion blur" \
VIDEO_MAGE_OUTPUT=magi_dynamic_4s.mp4 \
VIDEO_MAGE_FP8=auto \
VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_quant_config.json \
VIDEO_MAGE_VISIBLE_DEVICES=0 \
VIDEO_MAGE_NPROC=1 \
VIDEO_MAGE_NUM_FRAMES=96 \
VIDEO_MAGE_NUM_STEPS=12 \
VIDEO_MAGE_WINDOW_SIZE=1 \
VIDEO_MAGE_VIDEO_SIZE_H=512 \
VIDEO_MAGE_VIDEO_SIZE_W=512 \
bash ./test_single_chunk.sh
```

## Runtime contract

- MAGI-1 is chunk autoregressive with fixed 24-frame chunks.
- Prompt changes apply at chunk boundaries (not per frame).
- Geometry rule: `VIDEO_MAGE_VIDEO_SIZE_H` and `VIDEO_MAGE_VIDEO_SIZE_W` must be divisible by `16`.
- Cost default: single GPU (`VIDEO_MAGE_NPROC=1`, `VIDEO_MAGE_VISIBLE_DEVICES=0`).

## Scripted 30-second prompt-injection run

This repo includes a budget-guarded end-to-end script that:

1. Calibrates `TPOC` with a ladder (`1 -> 3 -> 4` GPUs when available).
2. Selects the smallest rung with steady-state `p90 TPOC <= 1.0s`.
3. Runs a 30-second (`720` frame) cyberpunk script schedule with chunk-boundary prompt updates.
4. Records MP4 output and writes JSON/CSV reports.

```bash
cd /root/neurodiffusion/VideoDiffusion
HOURLY_RATE_USD=0.6068 \
BUDGET_USD=15 \
CUDA_VISIBLE_DEVICES=0,1,2,3 \
bash ./test_scripted_30s.sh
```

Key artifacts:

- `VideoDiffusion/magi_scripted_30s.mp4`
- `VideoDiffusion/.tmp/*_script_injection_report.json`
- `VideoDiffusion/.tmp/*_script_injection_report.csv`
- `VideoDiffusion/.tmp/*_summary.json`

Script schedule source:

- `VideoDiffusion/prompt_schedules/cyberpunk_30s_hybrid.csv`

## Prime-first lifecycle runner (GPU-type aware)

`run_scripted_30s_prime.sh` adds a full Prime lifecycle around the scripted run:

1. Query live offers by GPU type/count/region from `scripts/prime/magi_gpu_policies.json`.
2. Deterministically select an offer for the requested tier (`4.5b` or `24b`).
3. Provision pod.
4. Run scripted 30s test remotely.
5. Pull artifacts and terminate pod.

Example:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode lifecycle \
  --tier 4.5b \
  --budget-usd 15 \
  --regions eu_north,eu_east,eu_west,united_states
```

In-pod mode (called by lifecycle runner):

```bash
cd /root/neurodiffusion
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode in-pod \
  --tier 4.5b \
  --hourly-rate-usd 0.6068 \
  --devices 0,1,2,3
```

## Prime GPU matrix runner

Use `run_prime_gpu_matrix.sh` to run multiple Prime GPU-type candidates under one total budget:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_prime_gpu_matrix.sh \
  --tier 4.5b \
  --budget-usd 15 \
  --slice-usd 3 \
  --regions eu_north,eu_east,eu_west,united_states
```

Matrix artifacts:

- `VideoDiffusion/.tmp/magi_matrix_<tier>.json`
- `VideoDiffusion/.tmp/magi_matrix_<tier>.csv`

## Streaming profile for prompt-reactive behavior

```bash
export CUDA_VISIBLE_DEVICES=0
export MAGI_WINDOW_SIZE=1
export QUEUE_LEN=96
export DROP_OLD_ON_PROMPT=1
export JPEG_QUALITY=75
python realtime_magi_stream.py
```

Prompt update:

```bash
curl -sS -X POST http://localhost:8000/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Neon rain over a crowded cyberpunk avenue, moving traffic, drifting steam"}'
```

Automated schedule runner:

```bash
python run_prompt_schedule.py \
  --url http://localhost:8000 \
  --schedule-csv prompt_schedules/cyberpunk_30s_hybrid.csv \
  --poll 0.25 \
  --timeout 180 \
  --report-json .tmp/prompt_schedule_report.json \
  --report-csv .tmp/prompt_schedule_report.csv
```

## Multi-GPU examples

One-shot generation:

```bash
VIDEO_MAGE_VISIBLE_DEVICES=0,1 \
VIDEO_MAGE_NPROC=2 \
bash ./test_single_chunk.sh
```

Streaming:

```bash
export CUDA_VISIBLE_DEVICES=0,1
export MAGI_CP_SIZE=2
export MAGI_PP_SIZE=1
torchrun --standalone --nproc_per_node=2 realtime_magi_stream.py
```

## Validation checks

```bash
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,duration \
  -of default=noprint_wrappers=1:nokey=0 /root/neurodiffusion/VideoDiffusion/<OUTPUT_FILE>
ffmpeg -hide_banner -i /root/neurodiffusion/VideoDiffusion/<OUTPUT_FILE> -vf mpdecimate -f null -
```

If the result looks static but `ffprobe` reports valid frame count/duration, that is usually prompt motion weakness, not a broken MP4.

## Dependency behavior (`setup.sh`)

`setup.sh` performs:

1. MAGI requirements install excluding `flash-attn` and `flashinfer-python`.
2. `flash-attn` wheel-first install, constrained source fallback only if needed.
3. `flashinfer-python` prebuilt install when available, source fallback otherwise.
4. MagiAttention compatibility patch for `flex_flash_attn_func(..., max_seqlen_k=...)`.

Tunable vars:

- `FLASH_ATTN_VERSION`
- `FLASH_ATTN_MAX_JOBS`
- `FLASH_ATTN_NVCC_THREADS`
- `FLASH_ATTN_SKIP_SM90`
- `MAGI_ATTENTION_SKIP_SM90`
- `TORCH_CUDA_ARCH_LIST`
- `FLASH_ATTN_FORCE_SOURCE`
- `FLASH_ATTN_ALLOW_SOURCE_BUILD`
- `MAGI_ATTENTION_SKIP_MAGI_ATTN_COMM_BUILD`
- `MAGI_ATTENTION_SKIP_FFA_UTILS_BUILD`

Low-compile-footprint defaults on non-Hopper:

```bash
export FLASH_ATTN_MAX_JOBS=1
export FLASH_ATTN_NVCC_THREADS=1
export FLASH_ATTN_SKIP_SM90=1
export MAGI_ATTENTION_SKIP_SM90=1
export MAGI_ATTENTION_SKIP_MAGI_ATTN_COMM_BUILD=1
export MAGI_ATTENTION_SKIP_FFA_UTILS_BUILD=1
bash setup.sh
```
