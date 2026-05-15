# VideoDiffusion

Canonical source of truth:

- `docs/video-magi1-streaming.md`
- `docs/video-scope-longlive-streaming.md`
- `docs/video-krea-streaming.md`
- `docs/eeg-openbci-control.md`
- `docs/cloudflare-r2.md` (artifact/cache persistence)
- `docs/budget-analysis.md` (cost model and `$15` run-envelope math)

This file is a fast operator summary for the `VideoDiffusion/` folder.
The model-dispatched entry points are:

```bash
VIDEO_MODEL=<magi|krea|scope|longlive> bash setup_video_runtime.sh
VIDEO_MODEL=<magi|krea|scope|longlive> bash run_video_stream.sh
```

Runtime lock artifacts in this folder:

- `requirements-magi.lock.txt` (repo-managed Python dependency lock layer)
- `apt-magi.lock.txt` (OS package lock layer)
- `runtime-manifest.schema.json` (runtime tuple manifest contract)
- `requirements-eeg.txt` (optional local OpenBCI/BrainFlow/LSL control dependencies)

## Scope + LongLive run order

No-paid local prep:

```bash
cd /Users/xenochain/Code/neurodiffusion
SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh
python3 VideoDiffusion/eeg_control/selftest.py
```

Future GPU host run order:

```bash
cd /root/neurodiffusion/VideoDiffusion
VIDEO_MODEL=scope bash setup_video_runtime.sh
bash download_scope_models.sh
VIDEO_MODEL=scope bash run_video_stream.sh
bash load_scope_longlive.sh
```

EEG control for Scope uses OSC:

```bash
python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board mock \
  --mock-scenario alternating \
  --policy balancer \
  --sink scope \
  --duration-s 60
```

See `docs/video-scope-longlive-streaming.md`.

## MAGI run order

```bash
cd /root/neurodiffusion/VideoDiffusion
bash setup.sh
bash download_weights.sh
# Use `hf auth login` before download if needed.
bash ./test_single_chunk.sh
python realtime_magi_stream.py
```

Offline OpenBCI/EEG prompt control lives in `eeg_control/` and should be tested against the fake local control server before any paid GPU run:

```bash
python3 VideoDiffusion/eeg_control/fake_video_control_server.py --port 8765
python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py --board mock --url http://127.0.0.1:8765 --duration-s 30
```

Use the systematic state -> policy -> sink runner for art modes:

```bash
python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board mock \
  --mock-scenario alternating \
  --policy balancer \
  --sink stdout \
  --sink jsonl \
  --duration-s 60
```

See `docs/eeg-openbci-control.md`.

For repeated runs, fastest boot path is:

1. Prime custom image with dependencies preinstalled.
2. Bootstrap and restore wheel/env caches from Cloudflare R2 (`bash /Users/xenochain/Code/neurodiffusion/scripts/cloudflare/bootstrap_r2.sh`).
3. Publish tuple/image caches after setup.
   - MAGI full-file weights publish (recommended):
     - `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/. bash publish_r2_prebuild.sh --runtime-tag <runtime_tag> --tiers 4.5b,24b --include-weights --allow-missing-image`
   - If `WEIGHTS_DIR` is left at default `MAGI-1/downloads`, symlink-only archives can occur.
4. Restore by runtime tag on fresh pods with automatic image->tuple fallback:
   - `bash restore_r2_prebuild.sh --mode auto --runtime-tag <runtime_tag> --tier 4.5b --apply-venv-target /root/neurodiffusion/VideoDiffusion/.venv --apply-weights-target /root/neurodiffusion/VideoDiffusion/MAGI-1`
5. Run only delta setup and generation.
6. Push outputs/reports back to R2, then terminate pod.

Note: publish/restore scripts require `AGENT_S3_*` credentials exported in the shell when running on pods.

Latest validated MAGI tuple (`2026-02-18`):

- `runtime_tag`: `hopper_sm80_py310_torch240_cu124_20260217_prebuild1`
- R2 env archive size: `3,924,169,961` bytes
- R2 weights archive size: `18,617,611,111` bytes

Latest scripted-stream validation (`2026-02-18`, Prime `A100 80GB x1`, tuned `384x384`, `8` steps):

- chunk-boundary prompt injection confirmed end-to-end (`18/18` cues applied)
- observed prompt-application lag on single GPU was high (up to `+6` chunks), so strict fidelity gate failed
- observed steady-state `p90 TPOC` around `6.2s` (not near-real-time)
- generated artifact: `VideoDiffusion/magi_scripted_30s_validation_4p5b_30s_small_fix3_20260218_021110.mp4` (`96` frames, `4.0s`, debug short profile with `MAGI_NUM_FRAMES=96`)
- separate direct one-shot validation produced a full clip:
  - `/Users/xenochain/Downloads/magi_try.mp4`
  - `720` frames, `30.0s`, `24 fps`, `384x384`
  - `mpdecimate` retained `718` frames (real motion confirmed)

Critical workflow hotfixes now in code:

- `restore_r2_prebuild.sh` now self-heals missing `boto3` environments via `bootstrap_r2.sh`
- `bootstrap_r2.sh` now repairs broken helper venvs and falls back to `python3-pip` install path when `python3-venv` is unavailable
- `run_magi_remote.sh` no longer syncs entire remote `.tmp` tree; it pulls run-tag artifacts only
- `run_magi_remote.sh` fixed temp-archive creation (`mktemp` portability bug)
- `realtime_magi_stream.py` prompt update now uses `copy_` under `torch.inference_mode()` to avoid PyTorch inference-mode in-place errors
- `test_scripted_30s.sh` now keeps final target frame count separate from calibration frame count
- `run_magi_remote.sh` now names non-720-frame outputs as `magi_scripted_<frames>f_<run_tag>.mp4` to avoid mislabeled `30s` artifacts

Repo-level one-command R2 publish (code bundle + runtime tuple when present):

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/cloudflare/publish_everything_r2.sh \
  --runtime-tag <runtime_tag> \
  --tiers 4.5b,24b \
  --include-weights \
  --include-image
```

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

Validated low-cost pretty 30s (single GPU one-shot):

```bash
VIDEO_MAGE_WEIGHT_VARIANT=4.5B_distill \
VIDEO_MAGE_FP8=0 \
VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_config.json \
VIDEO_MAGE_VISIBLE_DEVICES=0 \
VIDEO_MAGE_NPROC=1 \
VIDEO_MAGE_PROMPT="Cinematic cyberpunk night city, rain reflections, moving traffic, drifting steam, expressive camera motion" \
VIDEO_MAGE_OUTPUT=magi_try.mp4 \
VIDEO_MAGE_NUM_FRAMES=720 \
VIDEO_MAGE_NUM_STEPS=8 \
VIDEO_MAGE_WINDOW_SIZE=1 \
VIDEO_MAGE_VIDEO_SIZE_H=384 \
VIDEO_MAGE_VIDEO_SIZE_W=384 \
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
HOURLY_RATE_USD=<HOURLY_RATE_USD_FROM_SELECTED_OFFER> \
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
4. Restore runtime from Cloudflare (`--restore-mode auto|tuple|image`).
5. Run scripted 30s test remotely.
6. Pull artifacts, upload run bundle to R2, and terminate pod.

Example:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode lifecycle \
  --tier 4.5b \
  --budget-usd 15 \
  --selection-goal realtime \
  --min-gpu-count 4 \
  --max-provision-retries 4 \
  --restore-mode auto \
  --runtime-tag <runtime_tag> \
  --regions eu_north,eu_east,eu_west,united_states
```

Selection knobs:

- `--selection-goal realtime` (default): enforce policy `realtime_min_nproc`.
- `--selection-goal cost`: cheapest offer above `min_viable_nproc`.
- `--min-gpu-count <N>`: raise minimum GPU count floor.
- `--max-provision-retries <N>`: max total provision attempts; on each failure, re-query/reselect while excluding failed `availability_id` values (default `4`).
- retry telemetry is emitted at `VideoDiffusion/.tmp/magi_lifecycle_telemetry_<run_tag>.jsonl`.

In-pod mode (called by lifecycle runner):

```bash
cd /root/neurodiffusion
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode in-pod \
  --tier 4.5b \
  --hourly-rate-usd <HOURLY_RATE_USD_FROM_SELECTED_OFFER> \
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
  --restore-mode auto \
  --runtime-tag <runtime_tag> \
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
