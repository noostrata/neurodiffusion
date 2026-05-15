# VideoDiffusion (MAGI-1)

This is the canonical runbook for MAGI-1 on Vast.ai.
Prime Intellect sections in this file are legacy context only.

## Canonical Files

- `VideoDiffusion/setup.sh` — bootstraps MAGI-1 dependencies and flash-attn/flashinfer policy.
- `VideoDiffusion/download_weights.sh` — fetches checkpoint, VAE, and T5 weights.
- `VideoDiffusion/test_single_chunk.sh` — one-shot smoke test entrypoint.
- `VideoDiffusion/run_magi_vast_smoke.sh` — Vast attach/restore/smoke/pullback wrapper.
- `VideoDiffusion/realtime_magi_stream.py` — live MJPEG stream server entrypoint.
- `VideoDiffusion/run_prompt_schedule.py` — chunk-aligned prompt schedule injector + JSON/CSV reporting.
- `VideoDiffusion/test_scripted_30s.sh` — budget-guarded 30s scripted run orchestrator.
- `VideoDiffusion/run_scripted_30s_prime.sh` — Prime lifecycle wrapper (`lifecycle` + `in-pod` modes).
- `VideoDiffusion/run_prime_gpu_matrix.sh` — multi-GPU-type matrix runner under total budget.
- `VideoDiffusion/requirements-magi.lock.txt`, `VideoDiffusion/apt-magi.lock.txt`, `VideoDiffusion/runtime-manifest.schema.json` — deterministic dependency + runtime manifest contracts.
- `scripts/vast/query_video_offers.py` — Vast offer discovery.
- `scripts/vast/select_video_offer.py` — deterministic Vast offer selector with runtime-tag architecture filtering.
- `scripts/vast/provision_video_instance.sh` — instance create + ready poll.
- `scripts/vast/resolve_ssh.sh` — shared Vast SSH resolver.
- `scripts/vast/terminate_instance.sh` — idempotent Vast destroy helper.
- `docs/cloudflare-r2.md` — canonical cache/artifact storage contract.
- `docs/budget-analysis.md` — canonical budget model and storage/compute cost tables.

## Fast path for repeated runs

To minimize cold-start time on fresh pods:

1. Select a GPU family that matches the R2 runtime tuple architecture.
   - current tuple `hopper_sm80_py310_torch240_cu124_20260217_prebuild1` is `sm80`, so use A100-class hosts.
   - do not use this tuple on H100/H200; publish an `sm90` tuple first.
2. Keep Cloudflare R2 cache prefixes for wheels/env bundles:
   - `neurodiffusion/wheelhouse/`
   - `neurodiffusion/env-cache/`
   - `neurodiffusion/images/`
3. Pull cache bundle first, then run only incremental setup.
4. Push run artifacts (`mp4`, reports, logs) to `neurodiffusion/runs/<run_id>/`.
5. Use tuple publish/restore scripts:
   - publish (MAGI full-file weights): `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/. bash VideoDiffusion/publish_r2_prebuild.sh --runtime-tag <runtime_tag> --tiers 4.5b,24b --include-weights --allow-missing-image`
   - restore: `bash VideoDiffusion/restore_r2_prebuild.sh --mode auto --runtime-tag <runtime_tag> --tier 4.5b --apply-venv-target /root/neurodiffusion/VideoDiffusion/.venv --apply-weights-target /root/neurodiffusion/VideoDiffusion/MAGI-1`
6. Prefer `VideoDiffusion/run_magi_vast_smoke.sh` for attach-mode smoke tests because it enforces tuple/GPU compatibility, waits for SSH auth, installs missing smoke-time system deps, repairs restored venv shebangs, runs detached, pulls logs/MP4, and optionally destroys the instance.

Publish caveat:

- `download_weights.sh` creates symlinks under `MAGI-1/downloads/`.
- If publish points to symlink-only `MAGI-1/downloads/`, `weights_archive` can be incomplete.
- Use `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/.` (or an equivalent real-files staged directory).

If a matching tuple is not available, keep `setup.sh` as fallback and publish a new tuple before making that GPU class the default fast path.

## Default remote workflow

1. Query and select a compatible Vast offer.

   ```bash
   python3 scripts/vast/query_video_offers.py \
     --model magi \
     --gpu-name-regex 'A100' \
     --out-json VideoDiffusion/.tmp/vast_video_offer_scan_magi_a100.json \
     --out-csv VideoDiffusion/.tmp/vast_video_offer_scan_magi_a100.csv

   python3 scripts/vast/select_video_offer.py \
     --scan-json VideoDiffusion/.tmp/vast_video_offer_scan_magi_a100.json \
     --selection-goal cost \
     --runtime-tag hopper_sm80_py310_torch240_cu124_20260217_prebuild1 \
     --print-env
   ```

2. Provision or attach to the selected Vast instance, then run the fast smoke wrapper:

   ```bash
   VAST_INSTANCE_ID=<instance_id> \
   MAGI_VAST_DESTROY_ON_EXIT=1 \
   bash VideoDiffusion/run_magi_vast_smoke.sh
   ```

Manual fallback:

1. Provision instance and set `config/vast.env`.
2. Prepare runtime and deps:

   ```bash
   cd VideoDiffusion
   bash setup.sh
   ```

   If using a restored env cache, this step should be near-noop or skipped intentionally.
   If you skip bootstrap/setup intentionally, make sure `ffmpeg` and `ffprobe` are installed before scripted runs.

3. Authenticate before downloads if needed:

   ```bash
   hf auth login
   # or: huggingface-cli login
   ```

4. Download weights:

   - Quantized baseline (default):

     ```bash
     bash download_weights.sh
     ```

   - Non-quantized smoke path (recommended for consistent motion smoke on SM80/SM86-class cards):

     ```bash
     VIDEO_MAGE_WEIGHT_VARIANT=4.5B_distill bash download_weights.sh
     ```

   `download_weights.sh` also normalizes the weight layout expected by upstream MAGI-1 example configs
   by creating symlinks under `VideoDiffusion/MAGI-1/downloads/` (no large copies).

5. Run a validated one-GPU smoke test.

## Known-working one-gpu commands

### 0) Ultra-cheap proof-of-life (1 chunk, low steps)

This is the recommended first validation for cost control.

Notes:

- `VIDEO_MAGE_VIDEO_SIZE_H/W` must be divisible by **16** (VAE/patching constraints). If you see shape mismatch errors,
  revert to defaults or use `384x384`, `512x512`, `640x640`, etc.

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

### 1) Reliable non-quantized motion smoke (recommended)

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

### 2) Quantized smoke baseline

```bash
VIDEO_MAGE_FP8=0 \
VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_quant_config.json \
VIDEO_MAGE_VISIBLE_DEVICES=0 \
VIDEO_MAGE_NPROC=1 \
VIDEO_MAGE_PROMPT="Neon city, cinematic cyberpunk alleyway at dusk" \
VIDEO_MAGE_OUTPUT=magi_try.mp4 \
bash ./test_single_chunk.sh
```

## Longer dynamic profiles (validated operating shapes)

Use these after a one-chunk smoke succeeds.

## Offline EEG Prompt Control

OpenBCI EEG control should be developed offline first. The local controller in `VideoDiffusion/eeg_control/` can drive a fake MAGI-compatible `/prompt` and `/stats` server with mock EEG before any Vast spend:

```bash
python3 VideoDiffusion/eeg_control/fake_video_control_server.py --port 8765
python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py \
  --board mock \
  --mock-scenario alternating \
  --url http://127.0.0.1:8765 \
  --duration-s 30
```

Use `docs/eeg-openbci-control.md` for the OpenBCI/Cyton, BrainFlow synthetic-board, LSL, calibration, and live-MAGI handoff workflow.

### 3) 4-second dynamic shot (4 chunks)

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

### 4) 8-second complex shot (8 chunks, throughput-oriented)

```bash
VIDEO_MAGE_PROMPT="Slow aerial descent into a rainy megacity boulevard at dusk, layered traffic flow, pedestrians with umbrellas, volumetric fog, flickering billboards, depth-rich parallax, long-lens cinematic movement" \
VIDEO_MAGE_OUTPUT=magi_complex_8s.mp4 \
VIDEO_MAGE_FP8=auto \
VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_quant_config.json \
VIDEO_MAGE_VISIBLE_DEVICES=0,1 \
VIDEO_MAGE_NPROC=2 \
VIDEO_MAGE_NUM_FRAMES=192 \
VIDEO_MAGE_NUM_STEPS=16 \
VIDEO_MAGE_WINDOW_SIZE=1 \
VIDEO_MAGE_VIDEO_SIZE_H=640 \
VIDEO_MAGE_VIDEO_SIZE_W=640 \
bash ./test_single_chunk.sh
```

### 5) Cheap full-length pretty clip (30s, validated one-shot)

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

Prompt design rule for motion:

- include camera verb (`tracking`, `dolly`, `aerial descent`)
- include world motion (crowd/traffic/rain/fog/sign flicker)
- include parallax/depth cues
- avoid purely static scene wording

## Copy local for review

Pod output lives in:

`/root/neurodiffusion/VideoDiffusion/<OUTPUT_FILENAME>`

Example (non-quant smoke):

```bash
scp -P <PRIME_SSH_PORT> <PRIME_SSH_USER>@<PRIME_SSH_HOST>:/root/neurodiffusion/VideoDiffusion/magi_dynamic_nonquant.mp4 "$HOME/Downloads/magi_dynamic_nonquant.mp4"
```

## Persist artifacts to Cloudflare R2 (recommended)

Use R2 as durable storage after each run:

1. `source /Users/xenochain/agents/secrets/r2_full_access.env`
2. upload `mp4` + reports from `VideoDiffusion/.tmp/`
3. terminate pod

Canonical contract:

- `docs/cloudflare-r2.md`

## Execution behavior

- `test_single_chunk.sh` defaults to one-GPU smoke (`VIDEO_MAGE_NPROC=1`, `CUDA_VISIBLE_DEVICES=0`).
- `VIDEO_MAGE_FP8` values:
  - `auto` (default): enable fp8 only when an SM90-capable GPU is detected.
  - `0/off/no/false`: force fp8 off.
  - `1/on/yes/true`: force fp8 on.
- `realtime_magi_stream.py` uses the same fp8 override semantics via `MAGI_FP8` (or `VIDEO_MAGE_FP8` fallback):
  - `auto` (default): enable fp8 only on SM90-capable GPUs.
  - `0/off/no/false`: force fp8 off.
  - `1/on/yes/true`: force fp8 on.
- `VIDEO_MAGE_NPROC=auto` is supported and maps to the number of devices in `VIDEO_MAGE_VISIBLE_DEVICES`.
- Optional cost/throughput overrides (applied by `test_single_chunk.sh` without editing vendor configs):
  - `VIDEO_MAGE_NUM_STEPS`
  - `VIDEO_MAGE_NUM_FRAMES` (use `24` for exactly one chunk)
  - `VIDEO_MAGE_VIDEO_SIZE_H`, `VIDEO_MAGE_VIDEO_SIZE_W` (must be divisible by `16`)
  - `VIDEO_MAGE_WINDOW_SIZE`
  - `VIDEO_MAGE_T5_DEVICE` / `MAGI_T5_DEVICE` (`cuda` is faster for smoke on high-VRAM cards; default vendor 4.5B config uses CPU)

## Chunked generation and prompt hot-swap

MAGI-1 is a chunked autoregressive denoising video model. The paper describes chunk-wise autoregressive generation with chunk-wise prompting, and the released MAGI-1 runtime/config path in this repo uses **fixed 24-frame chunks**. This defines the prompt update granularity: **prompt changes apply at chunk boundaries, not per-frame**.

In this repo, `realtime_magi_stream.py` implements exactly that:

- the server reads/broadcasts the current prompt at chunk boundaries and updates the *next* chunk’s text conditioning before generation resumes.
- `/prompt` updates the prompt immediately, and the next chunk boundary applies it.

Practical latency expectations:

- Best case: prompt change appears on the very next chunk (bounded by “time remaining for the current chunk”).
- If the stream has a large buffered backlog, you can see old frames for a while before the new prompt shows up.
  - Use a smaller `QUEUE_LEN` and keep `DROP_OLD_ON_PROMPT=1` to keep interaction tight.

Useful env knobs for prompt-reactive streaming:

- `QUEUE_LEN` (default: `600`) — max buffered JPEG frames. Lower = tighter latency, more drops.
- `DROP_OLD_ON_PROMPT` (default: `1`) — drop buffered frames after a prompt change so the new prompt is visible sooner.
- `JPEG_QUALITY` (default: `85`) — lower quality reduces CPU encode cost and bandwidth.
- `MAGI_INITIAL_PROMPT` (default: `sunset over baltic sea`) — initial sequence prompt before any `/prompt` updates.
- `MAGI_WINDOW_SIZE` (recommended: `1` for tight prompt hot-swap) — larger values can improve throughput but make prompt changes feel less immediate because multiple chunks may be in-flight.
- `MAGI_NUM_STEPS`, `MAGI_VIDEO_SIZE_H`, `MAGI_VIDEO_SIZE_W`, `MAGI_NUM_FRAMES` — optional overrides applied by the stream server at startup (testing only; avoids editing vendor configs).

Stream recorder contract:

- `/stream` emits JPEG-only multipart frames (`multipart/x-mixed-replace`) and should not mix non-image payloads. This keeps ffmpeg recording stable.

### Prompt update (curl)

If the stream is tunneled to `localhost:8000`:

```bash
curl -sS -X POST http://localhost:8000/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Slow dolly shot through a busy cyberpunk alley at night, neon signs flickering, light rain, passing cars and pedestrians moving"}'
```

Optional: poll server-side chunk stats and queue depth:

```bash
curl -sS http://localhost:8000/stats
```

Optional: benchmark prompt hot-swap latency (chunk-boundary responsiveness):

```bash
python VideoDiffusion/bench_prompt_hot_swap.py --url http://localhost:8000 --rounds 2
```

### Scripted prompt injection runner

Run a full cue schedule and emit machine-readable reports:

```bash
python VideoDiffusion/run_prompt_schedule.py \
  --url http://localhost:8000 \
  --schedule-csv VideoDiffusion/prompt_schedules/cyberpunk_30s_hybrid.csv \
  --poll 0.25 \
  --timeout 180 \
  --report-json VideoDiffusion/.tmp/prompt_schedule_report.json \
  --report-csv VideoDiffusion/.tmp/prompt_schedule_report.csv
```

CSV schema:

- `cue_id,start_chunk,end_chunk,prompt`

Report contract:

- JSON fields: `run_id,start_ts,end_ts,config,metrics,cues,status`
- CSV fields: `cue_id,start_chunk,applied_chunk,latency_s,latency_chunks,status`

### Scripted 30s end-to-end workflow

`test_scripted_30s.sh` performs:

1. Calibration ladder (`1 -> 3 -> 4` GPUs where available).
2. Select smallest rung with steady-state `p90 TPOC <= 1.0s`.
3. Run 30-second scripted generation (`720` frames).
4. Record MP4 via ffmpeg.
5. Emit summary + calibration + schedule reports under `VideoDiffusion/.tmp/`.

Launcher/runtime behavior:

- the script auto-prefers `VideoDiffusion/.venv/bin/python` and `VideoDiffusion/.venv/bin/torchrun` when present.
- if a `torchrun` binary is unavailable, it automatically falls back to `python -m torch.distributed.run`.
- budget watchdog now runs as a single Python timer process (no orphaned `sleep`), which prevents SSH teardown hangs after run completion.

```bash
cd VideoDiffusion
HOURLY_RATE_USD=<HOURLY_RATE_USD_FROM_SELECTED_OFFER> \
BUDGET_USD=15 \
CUDA_VISIBLE_DEVICES=0,1,2,3 \
bash ./test_scripted_30s.sh
```

Generated artifacts:

- `VideoDiffusion/magi_scripted_30s.mp4`
- `VideoDiffusion/.tmp/*_script_injection_report.json`
- `VideoDiffusion/.tmp/*_script_injection_report.csv`
- `VideoDiffusion/.tmp/*_calibration.json`
- `VideoDiffusion/.tmp/*_summary.json`

Summary budget fields:

- `hourly_rate_usd`
- `budget_usd`
- `max_runtime_sec`
- `actual_runtime_sec`
- `estimated_spend_usd`
- `termination_status`

Latest empirical 4.5B stream result (`2026-02-18`, Prime `A100 80GB x1`, tuned `384x384`, `8` steps):

- dynamic prompt scheduling is functioning (`18/18` cues applied)
- one-GPU prompt response lag is still high (cue application drift up to `+6` chunks)
- measured steady-state `p90 TPOC` was about `6.2s` (not near-real-time)
- strict cue-fidelity gate (`target chunk or next chunk`) failed on this profile
- separate one-shot non-stream render on the same GPU/profile produced a full clip (`30.0s`, `720` frames, `384x384`) for quality validation use

Latest lifecycle scripted 30s validation (`2026-02-18`, Prime `A100 80GB x1` non-spot, same `384x384` / `8` steps, static 1-cue schedule):

- run status: `OK`
- output: `30.0s`, `720` frames
- steady-state `p90 TPOC`: `10.2052s` (pass with `TARGET_TPOC_S=12`)
- spend estimate from run summary: `$0.1476`

### Prime lifecycle wrapper (recommended for automation)

Run full flow with no manual pod create/terminate commands:

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

Selection tuning:

- default is `--selection-goal realtime` (policy `realtime_min_nproc` floor).
- use `--selection-goal cost` for cheapest possible validation runs.
- optionally force floor with `--min-gpu-count <N>`.
- `--max-provision-retries <N>` sets the max total provision attempts; each failure re-queries/reselects and excludes failed `availability_id` values (`4` by default).
- lifecycle remote execution forwards optional env overrides for cheaper/faster test passes:
  `MAGI_NUM_FRAMES`, `MAGI_NUM_STEPS`, `MAGI_VIDEO_SIZE_H/W`, `MAGI_CONFIG_FILE`, `MAGI_CP_SIZE`, `MAGI_PP_SIZE`, `CALIB_CHUNKS`, `CALIB_TIMEOUT_S`, `QUEUE_LEN`, `JPEG_QUALITY`, and related timing knobs.
- if multi-GPU calibration stalls at `chunk_idx=-1`, run a diagnostic retry with `MAGI_CP_SIZE=1` before re-enabling higher CP sizes.
- lifecycle writes attempt telemetry to `VideoDiffusion/.tmp/magi_lifecycle_telemetry_<run_tag>.jsonl` for postmortems and selection tuning.

For ephemeral pod IP reuse environments:

```bash
PRIME_STRICT_HOST_KEY_CHECKING=no \
PRIME_USER_KNOWN_HOSTS_FILE=/dev/null \
PRIME_GLOBAL_KNOWN_HOSTS_FILE=/dev/null \
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode lifecycle \
  --tier 4.5b \
  --restore-mode auto \
  --runtime-tag <runtime_tag>
```

Lifecycle order:

1. Discover live offers from policy (`scripts/prime/magi_gpu_policies.json`).
2. Deterministically select best offer.
3. Provision pod.
4. Restore runtime from R2 (`--restore-mode auto|tuple|image`).
5. Execute in-pod scripted test.
6. Pull artifacts from `VideoDiffusion/.tmp/remote_<run_tag>/`.
7. Upload run artifacts to `neurodiffusion/runs/<run_tag>/`.
8. Terminate pod via `prime pods terminate <POD_ID> --yes`.

### Prime GPU matrix mode

Systematic multi-type test within one total budget:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_prime_gpu_matrix.sh \
  --tier 24b \
  --budget-usd 15 \
  --slice-usd 3
```

Matrix artifacts:

- `VideoDiffusion/.tmp/magi_matrix_<tier>.json`
- `VideoDiffusion/.tmp/magi_matrix_<tier>.csv`

## Real-time sizing (TTFC/TPOC)

This repo uses two latency metrics from MAGI runtime terminology:

- **TTFC** (Time To First Chunk): time until the first 24-frame chunk is ready.
- **TPOC** (Time Per Output Chunk): time to generate each subsequent 24-frame chunk.

For uninterrupted playback at 24 fps, each chunk spans 1 second of video (24 frames). So a practical real-time target is:

- `TPOC <= 1.0s` (sustainability)
- `TTFC` as low as possible (responsiveness)

### Measuring in this repo

`realtime_magi_stream.py` logs per-chunk generation time and an effective FPS estimate:

- `[producer] Chunk N (local=M) model=...s decode=...s total=X.XXXs (YY.YY fps)`

To sustain 24 fps streaming, you want `X.XXXs <= 1.0s` on steady-state chunks.

### Hardware guidance (upstream MAGI + Prime availability)

Upstream MAGI-1 repository guidance (validated 2026-02-16):

- `4.5B` fast path centers on `RTX4090 x1`.
- `24B` fast path centers on `H100/H800 x8`.
- `24B distill + fp8 quant` path lists `H100/H800 x4`.

Paper + upstream note:

- the MAGI-1 paper states chunk-wise autoregressive streaming and real-time serving goals.
- upstream MAGI model-zoo notes full `24B` real-time generation on a larger `24 x H100` heterogeneous serving setup.

Operator implication:

- for this repo, start with single-node tier policy and measured `TPOC`, then scale by GPU count/type.
- use matrix mode for empirical pass/fail against steady-state `p90 TPOC <= 1.0s`.

Prime availability is dynamic. Re-run:

```bash
prime availability list --gpu-type RTX4090_24GB --gpu-count 1 --regions eu_north -o json
prime availability list --gpu-type H100_80GB --gpu-count 1 --regions eu_north -o json
prime availability list --gpu-type H100_80GB --gpu-count 8 --regions united_states -o json
```

Live sample (2026-02-16, lowest observed listing per query):

- `eu_north`:
  - 1× RTX4090 24GB: `$0.6068/hr`
  - 1× H100 80GB: `$0.8015/hr` (spot)
  - 1× H100 80GB: `$2.29/hr` (non-spot)
- `united_states`:
  - 8× H100 80GB: `$23.92/hr`

Back-of-envelope cost math (using the live sample above):

- 1× RTX4090 (`eu_north`): `~$0.101` per 10 minutes
- 1× H100 (`eu_north`): `~$0.134` per 10 minutes
- 1× H100 non-spot (`eu_north`): `~$0.382` per 10 minutes
- 8× H100 (`united_states`): `~$3.987` per 10 minutes

For most operators:

- Start with 1× H100 or 1× RTX4090 in `eu_north` for prompt-reactive bring-up and measure chunk time.
- If you cannot reach `TPOC <= 1s`, reduce resolution/steps first. Only then scale GPUs.

### First-principles cluster sizing for real-time

Goal: sustain `TPOC <= 1.0s` in steady state.

1. Measure single-GPU steady-state chunk time `T1` with your exact target resolution/steps.
2. Use conservative parallel efficiency `eta` (`0.70` to `0.85`).
3. Estimate required GPUs:
   - `N_required = ceil(T1 / (1.0 * eta))`
4. Validate with `N_required`, then one step above if queue still grows.

Examples with `eta=0.75`:

- If `T1=1.6s` -> `ceil(1.6/0.75)=3` GPUs.
- If `T1=2.4s` -> `ceil(2.4/0.75)=4` GPUs.
- If `T1=3.8s` -> `ceil(3.8/0.75)=6` GPUs.

For testing-phase economics in Northern Europe:

- start on the lowest-cost 1-GPU listing (`H100` or `RTX4090`, whichever is currently cheaper/available).
- if needed, move to a higher GPU count on the same SKU when that count is actually listed.
- if high-count local listings are absent, broaden regions and retest before locking production topology.

## Why the recommended non-quant path exists

On some SM80/SM86-class cards, fp8/quant mixes can trigger extension- or kernel-level fallback behavior depending on installed binaries. In those cases, `VIDEO_MAGE_FP8=0` plus the non-quant checkpoint/config pairing gives a stable, low-cost completion path for smoke verification.

Avoid mixing `VIDEO_MAGE_CONFIG=...distill_config.json` with quantized-only checkpoint trees unless that path layout is explicitly aligned.

## Static output validation

`magi_try.mp4` may still render and be a valid video with very little motion if prompt dynamics are weak. Use both checks:

```bash
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,duration \
  -of default=noprint_wrappers=1:nokey=0 "$HOME/Downloads/magi_dynamic_nonquant.mp4"
ffmpeg -hide_banner -i "$HOME/Downloads/magi_dynamic_nonquant.mp4" -vf mpdecimate -f null -
```

- A valid render should show `nb_read_frames` around `96` and noticeable kept/dropped motion in `mpdecimate`.
- For validated full-length profile, expect `nb_read_frames=720` and `duration=30.0`.
- If output is mostly static, increase motion cues in prompt (tracking move, traffic, flickering lights, weather, moving crowds, subtle camera jitter).
- A static-looking clip is still an MP4 video if frame count and duration are valid; this is usually a prompt/motion issue, not a container/codec issue.

## Flash-attention policy

`setup.sh` follows a fast + constrained fallback strategy:

- Install prebuilt `flash-attn` first (`--only-binary :all:`).
- Fall back to constrained source build only if no compatible wheel exists.
- Tune compile footprint with:
  - `FLASH_ATTN_MAX_JOBS`
  - `FLASH_ATTN_NVCC_THREADS`
  - `FLASH_ATTN_SKIP_SM90`
  - `FLASH_ATTN_FORCE_SOURCE`
  - `FLASH_ATTN_ALLOW_SOURCE_BUILD`
  - `MAGI_ATTENTION_SKIP_SM90`
  - `MAGI_ATTENTION_SKIP_MAGI_ATTN_COMM_BUILD`
  - `MAGI_ATTENTION_SKIP_FFA_UTILS_BUILD`

Cost-oriented defaults for non-Hopper targets:

```bash
export FLASH_ATTN_MAX_JOBS=1
export FLASH_ATTN_NVCC_THREADS=1
export FLASH_ATTN_SKIP_SM90=1
export MAGI_ATTENTION_SKIP_SM90=1
export MAGI_ATTENTION_SKIP_MAGI_ATTN_COMM_BUILD=1
export MAGI_ATTENTION_SKIP_FFA_UTILS_BUILD=1
```

## Scaling

- 2-GPU smoke:
  - `VIDEO_MAGE_VISIBLE_DEVICES=0,1 VIDEO_MAGE_NPROC=2 bash ./test_single_chunk.sh`
- 4-GPU smoke:
  - `VIDEO_MAGE_VISIBLE_DEVICES=0,1,2,3 VIDEO_MAGE_NPROC=4 bash ./test_single_chunk.sh`

Use multi-GPU only for throughput, not first-touch validation.

## Cost control

- Keep pod alive only for setup + smoke + optional stream check.
- Terminate immediately after successful smoke:

```bash
VAST_INSTANCE_ID=<instance_id> bash scripts/vast/terminate_instance.sh
vastai show instances --raw
```

## Compatibility notes

- If you see `TypeError: flex_flash_attn_func() got an unexpected keyword argument 'max_seqlen_k'`, your MagiAttention
  checkout is missing a compatibility arg required by current MAGI-1. `VideoDiffusion/setup.sh` applies an automatic
  patch on install; rerun `bash setup.sh` if you hit this on a fresh pod.

- Legacy VAST.ai notes are in `docs/legacy/`.
- Onboarding, execution, and runbook flow should use:
  - `docs/image-streaming.md`
  - `docs/video-magi1-streaming.md`
  - `docs/video-magi1-observations.md`
  - `docs/prime-intellect.md`
