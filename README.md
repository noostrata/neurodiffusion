# neurodiffusion

Vast.ai-current repository for image/video diffusion workflows with Cloudflare R2 persistence.
Prime Intellect scripts remain for historical compatibility, but new provider work should target Vast.

## What this repo contains

- `ImageDiffusion/` — SD-Turbo real-time image streaming (MJPEG).
- `VideoDiffusion/` — model-selectable video stack (`VIDEO_MODEL=magi|krea|scope|longlive`) with real-time steering paths.
- `scripts/vast/` — Vast offer query/selection, instance lifecycle, and SSH resolver scripts.
- `scripts/prime/` — legacy Prime offer query/selection, pod lifecycle, and SSH resolver scripts.
- `scripts/cloudflare/` — R2 bootstrap + repo/runtime bundle publish helpers.
- `docs/` — canonical operator documentation.
- `config/` — local templates and ignored overrides.

## First setup

1. Install and configure the Vast CLI: `vastai set api-key <KEY>`.
2. Create `config/vast.env` from `config/vast.env.example`.
3. Source Cloudflare R2 credentials for artifact/cache workflow:
   - `source /Users/xenochain/agents/secrets/r2_full_access.env`
4. Bootstrap Cloudflare R2 layout once:
   - `bash scripts/cloudflare/bootstrap_r2.sh`
5. Follow `docs/vastai.md` to search offers and launch an instance.
6. Validate SSH once via `bash scripts/vast/resolve_ssh.sh`.

## Fastest cold-start path (recommended)

Yes, the fastest practical workflow is to combine:

1. a reusable Vast Docker SSH image/runtime with MAGI dependencies already installed
2. Cloudflare R2 for runtime tuples, optional image artifacts, and output persistence

Operationally:

1. Build image once and reuse for pods.
2. Keep R2 `wheelhouse/`, `env-cache/`, `weights/`, `images/`, and `runs/` prefixes.
3. Publish runtime tuples with:
   - `bash scripts/cloudflare/publish_everything_r2.sh --video-model <magi|krea> --attn-backend <auto|sage|flash|sdpa> --runtime-tag <runtime_tag> --tiers <csv> --include-weights --include-image`
4. Restore on pod boot with automatic fallback:
   - `bash VideoDiffusion/restore_r2_prebuild_model.sh --model <magi|krea> --mode auto --runtime-tag <runtime_tag> --apply-venv-target <venv_target> --apply-weights-target <weights_target>`
5. Run test, upload artifacts to R2, terminate pod.

Latest validated MAGI tuple publish (`2026-02-18`):

- `runtime_tag`: `hopper_sm80_py310_torch240_cu124_20260217_prebuild1`
- `env_archive`: `3,924,169,961` bytes
- `weights_archive`: `18,617,611,111` bytes
- manifest: `neurodiffusion/manifests/runtime-tuples/hopper_sm80_py310_torch240_cu124_20260217_prebuild1/latest.json`

Latest historical runtime validation notes (`2026-02-18`, Prime `A100 80GB x1`, tuned low-cost profile):

- tuple restore now works on fresh pods after bootstrap self-heal fixes (`boto3` + missing `python3-venv` fallback path)
- scripted prompt injection applied all 18 cues in-order (chunk-boundary updates confirmed)
- measured steady-state latency remained far from real-time on one GPU (`steady p90 TPOC ~6.2s`)
- strict cue-fidelity gate (`target-or-next chunk`) failed for this one-GPU profile even though all cues eventually applied
- `magi_scripted_30s_validation_4p5b_30s_small_fix3_20260218_021110.mp4` is a debug short run (`96` frames, `4.0s`) because that run used `MAGI_NUM_FRAMES=96`
- separate calibration/final-frame bleed bug is fixed; `VideoDiffusion/test_scripted_30s.sh` now preserves final target frame count separately from calibration frame count
- direct non-stream one-shot render is now validated on the same `A100 80GB x1` path:
  - output: `/Users/xenochain/Downloads/magi_try.mp4`
  - validation: `720` frames, `30.0s`, `24 fps`, `384x384`
  - `mpdecimate` retained `718` frames, confirming real motion (not a single still image)

Important MAGI publish detail:

- `download_weights.sh` normalizes `MAGI-1/downloads/` as symlinks.
- For full-file tuple uploads, publish with:
  - `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/. bash VideoDiffusion/publish_r2_prebuild.sh --runtime-tag <runtime_tag> --tiers 4.5b,24b --include-weights --allow-missing-image`

Single command to push repo/runtime assets currently available on this machine:

- `bash scripts/cloudflare/publish_everything_r2.sh --video-model <magi|krea> --runtime-tag <runtime_tag> --tiers <csv> --include-weights --include-image`

Canonical storage contract:

- `docs/cloudflare-r2.md`
- `docs/budget-analysis.md`

## Budget planning (canonical)

For storage vs compute budgeting (provider disk vs R2 monthly costs, and `$15` run-envelope math), use:

- `docs/budget-analysis.md`

## Fast start (recommended)

1. Follow the canonical runbooks in `docs/` (single source of truth).
2. For a one-time image workflow, run:
   - `bash ImageDiffusion/remote_setup.sh`
   - `bash ImageDiffusion/start_stream_server.sh`
   - `bash ImageDiffusion/tunnel_to_stream.sh`
   - Open `http://localhost:8888/`
3. For the cheapest MAGI-1 proof-of-life (1 chunk, low steps):
   ```bash
   cd VideoDiffusion
   bash setup.sh
   bash download_weights.sh
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
   - Output appears at `/root/neurodiffusion/VideoDiffusion/magi_try.mp4`
   - Copy to local:
     `scp -P <PORT> <PRIME_SSH_USER>@<PRIME_SSH_HOST>:/root/neurodiffusion/VideoDiffusion/magi_try.mp4 "$HOME/Downloads/magi_try.mp4"`
   - Confirm it's a real video:
     ```bash
     ffprobe -v error -count_frames -select_streams v:0 \
       -show_entries stream=nb_read_frames,duration \
       -of default=noprint_wrappers=1:nokey=0 "$HOME/Downloads/magi_try.mp4"
     ```

4. For a cheap full-length pretty render (30s):
   ```bash
   cd VideoDiffusion
   VIDEO_MAGE_WEIGHT_VARIANT=4.5B_distill bash download_weights.sh
   VIDEO_MAGE_FP8=0 \
   VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_config.json \
   VIDEO_MAGE_PROMPT="Cinematic cyberpunk night city, rain reflections, moving traffic, drifting steam, expressive camera motion" \
   VIDEO_MAGE_OUTPUT=magi_try.mp4 \
   VIDEO_MAGE_VISIBLE_DEVICES=0 \
   VIDEO_MAGE_NPROC=1 \
   VIDEO_MAGE_NUM_FRAMES=720 \
   VIDEO_MAGE_NUM_STEPS=8 \
   VIDEO_MAGE_WINDOW_SIZE=1 \
   VIDEO_MAGE_VIDEO_SIZE_H=384 \
   VIDEO_MAGE_VIDEO_SIZE_W=384 \
   bash ./test_single_chunk.sh
   ```
5. For higher-quality motion checks, follow `docs/video-magi1-streaming.md` (non-quant profile).
6. Destroy the Vast instance immediately after validation:
   - `VAST_INSTANCE_ID=<instance_id> bash scripts/vast/terminate_instance.sh`

## Dynamic Video Playbook (Practical)

MAGI-1 generates in **24-frame chunks**. For dynamic prompt control, think in chunks:

- 24 frames = 1 chunk = 1 second at 24 fps
- 96 frames = 4 chunks = ~4 seconds
- 192 frames = 8 chunks = ~8 seconds

For interactive prompt testing, keep one chunk and low steps. For richer scenes, scale frames/steps first, then GPUs.

### Profile A: Interactive proof (cheapest)

- Goal: confirm pipeline + prompt responsiveness with minimal spend.
- Typical settings:
  - `VIDEO_MAGE_NUM_FRAMES=24`
  - `VIDEO_MAGE_NUM_STEPS=8`
  - `VIDEO_MAGE_VIDEO_SIZE_H=384`
  - `VIDEO_MAGE_VIDEO_SIZE_W=384`

### Profile B: Short dynamic shot (better motion context)

- Goal: produce multi-chunk motion and camera dynamics.
- Typical settings:
  - `VIDEO_MAGE_NUM_FRAMES=96`
  - `VIDEO_MAGE_NUM_STEPS=12`
  - `VIDEO_MAGE_VIDEO_SIZE_H=512`
  - `VIDEO_MAGE_VIDEO_SIZE_W=512`

### Profile C: Complex cinematic pass (quality-first)

- Goal: richer temporal structure and scene complexity.
- Typical settings:
  - `VIDEO_MAGE_NUM_FRAMES=192`
  - `VIDEO_MAGE_NUM_STEPS=16`
  - `VIDEO_MAGE_VIDEO_SIZE_H=640`
  - `VIDEO_MAGE_VIDEO_SIZE_W=640`
  - `VIDEO_MAGE_VISIBLE_DEVICES=0,1`
  - `VIDEO_MAGE_NPROC=2`

Notes:

- Keep `VIDEO_MAGE_VIDEO_SIZE_H/W` divisible by `16`.
- Prefer frame counts divisible by `24` to align with chunk boundaries.
- First generation on a fresh pod can be slower due kernel JIT/compile warmup.

## Multi-GPU Strategy (Cost-Aware)

- Scale order:
  1. Reduce `steps`/resolution to hit target latency.
  2. Increase GPU count only if latency target still misses.
  3. Re-measure `TPOC` after each change.
- Smoke test scaling:
  - `VIDEO_MAGE_VISIBLE_DEVICES=0,1 VIDEO_MAGE_NPROC=2 bash VideoDiffusion/test_single_chunk.sh`
  - `VIDEO_MAGE_VISIBLE_DEVICES=0,1,2,3 VIDEO_MAGE_NPROC=4 bash VideoDiffusion/test_single_chunk.sh`
- Stream scaling:
  - `torchrun --standalone --nproc_per_node=<N> VideoDiffusion/realtime_magi_stream.py`
  - set `MAGI_CP_SIZE=<N>`, `MAGI_PP_SIZE=1` for single-node context parallel experiments.

## One-command targets

### Validation

- `bash scripts/check.sh` — repo-owned shell/Python syntax, provider offer selftests, and JSON contract checks.

### Vast

- `python3 scripts/vast/query_video_offers.py --model <magi|krea|scope>`
- `python3 scripts/vast/select_video_offer.py --scan-json <scan.json> --selection-goal <realtime|cost> --print-env`
- `VAST_OFFER_ID=<offer_id> bash scripts/vast/provision_video_instance.sh`
- `eval "$(bash scripts/vast/resolve_ssh.sh)"`
- `VAST_INSTANCE_ID=<instance_id> bash scripts/vast/terminate_instance.sh`

### Image

- `bash ImageDiffusion/remote_setup.sh`
- `bash ImageDiffusion/start_stream_server.sh`
- `bash ImageDiffusion/tunnel_to_stream.sh`

### Video

- unified setup (model-dispatched):
  - `VIDEO_MODEL=<magi|krea|scope|longlive> ATTN_BACKEND=<auto|sage|flash|sdpa> bash VideoDiffusion/setup_video_runtime.sh`
- unified stream launcher:
  - `VIDEO_MODEL=<magi|krea|scope|longlive> ATTN_BACKEND=<auto|sage|flash|sdpa> bash VideoDiffusion/run_video_stream.sh`
- Scope + LongLive no-live-run preparation:
  - `SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh` (clone/env only)
  - `bash VideoDiffusion/download_scope_models.sh` (future GPU host model fetch)
  - `bash VideoDiffusion/load_scope_longlive.sh` (load pipeline after Scope server is up)
  - `python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py --board mock --mock-scenario alternating --policy balancer --sink scope --duration-s 20`
- `bash VideoDiffusion/setup.sh`
- `bash VideoDiffusion/download_weights.sh`
- `bash VideoDiffusion/test_single_chunk.sh` (default one-GPU, scalable via `VIDEO_MAGE_NPROC`/`VIDEO_MAGE_VISIBLE_DEVICES`)
- `python VideoDiffusion/realtime_magi_stream.py` (prompt changes apply at **24-frame chunk boundaries**; see `docs/video-magi1-streaming.md`)
- `bash VideoDiffusion/test_scripted_30s.sh` (budget-guarded 30s scripted prompt injection run; requires `HOURLY_RATE_USD`)
- multi-GPU smoke example:
  ```bash
  VIDEO_MAGE_PROMPT="Neon city, cinematic cyberpunk alleyway at dusk" \
  VIDEO_MAGE_OUTPUT=magi_try.mp4 \
  VIDEO_MAGE_VISIBLE_DEVICES=0,1 \
  VIDEO_MAGE_NPROC=2 \
  bash VideoDiffusion/test_single_chunk.sh
  ```
- scripted 30s example:
  ```bash
  cd VideoDiffusion
  HOURLY_RATE_USD=<HOURLY_RATE_USD_FROM_SELECTED_OFFER> \
  BUDGET_USD=15 \
  CUDA_VISIBLE_DEVICES=0,1,2,3 \
  bash ./test_scripted_30s.sh
  ```
- Legacy Prime lifecycle example (historical only; prefer `scripts/vast/` for current work):
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
  - telemetry log: `VideoDiffusion/.tmp/magi_lifecycle_telemetry_<run_tag>.jsonl`

## Reference docs

- `docs/vastai.md`
- `docs/prime-intellect.md` (legacy)
- `docs/prime/how_keys.md`
- `docs/cloudflare-r2.md`
- `docs/accelerate.md`
- `docs/budget-analysis.md`
- `docs/image-streaming.md`
- `docs/video-magi1-streaming.md`
- `docs/video-krea-streaming.md`
- `docs/video-scope-longlive-streaming.md`
- `docs/video-realtime-steering.md`
- `docs/video-magi1-scaling-testing.md`
- `docs/video-magi1-observations.md`
- `docs/security.md`
- `docs/references.md`

## Legacy Prime Billing Note

Prime notes below are retained only for interpreting historical run logs.
As of `prime` CLI `v0.5.36`, numeric credit balance was not exposed by `prime whoami` or `prime teams list`.
Historical Prime credits required the Prime billing dashboard:

- `https://app.primeintellect.ai/dashboard/billing`

## Output convention

- Render artifacts (including `*.mp4`) are gitignored.
- Keep generated artifacts in `~/Downloads` or a dedicated validation folder.
