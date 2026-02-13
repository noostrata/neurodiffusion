# AGENTS.md (neurodiffusion)

This repository is intentionally operator-first: scripts should be deterministic, repeatable, and safe on a fresh Prime Intellect pod.

## Canonical Workflow Sources

- `docs/image-streaming.md` is the ImageDiffusion source of truth.
- `docs/video-magi1-streaming.md` is the VideoDiffusion source of truth.
- `docs/prime-intellect.md` is the Prime Intellect provisioning source of truth.
- `docs/prime/how_keys.md` is the key/token hygiene source of truth.
- `docs/legacy/` contains historic VAST.ai notes only. New work must not depend on these.

## Repository Layout (Current Focus)

- `ImageDiffusion/` — SD-Turbo image streaming runtime.
- `VideoDiffusion/` — MAGI-1 video setup, weights flow, test, and stream.
- `scripts/prime/` — shared Prime connection resolver.
- `config/` — templates and local, ignored overrides.
- `docs/` — operator documentation and contracts.

## Mandatory Security Rules

1. Never commit secrets or credentials.
2. Never commit pod-specific hostnames, IPs, ports, or access tokens.
3. Keep vendor repos, checkpoints, and generated media in `.gitignore` scope.
4. Use `config/prime.env` only for local run settings and keep it ignored.

## Prime Intellect Contract

- Provider is configured in `.prime/config.json` (outside repo).
- Scripts resolve SSH from:
  - explicit `PRIME_SSH_HOST`/`PRIME_SSH_USER`/`PRIME_SSH_PORT` when present
  - or `PRIME_POD_ID` via `prime pods status <POD_ID> -o json`
- `prime` CLI JSON output is part of an external contract. If parsing breaks, update `scripts/prime/resolve_ssh.sh` first.

## Required Script Conventions

- Use `set -euo pipefail`.
- Keep scripts idempotent where practical.
- Prefer explicit environment variables over hardcoded constants.
- Avoid manual SSH host strings in tracked files.
- Keep non-interactive defaults for CI/automation compatibility.
- Fail early with clear messages and `stderr` output.

## Image Diffusion Run Discipline

1. Create `config/prime.env` from `config/prime.env.example`.
2. Set `PRIME_POD_ID` and `PRIME_SSH_KEY_PATH`.
3. Run `bash ImageDiffusion/remote_setup.sh`.
4. Run `bash ImageDiffusion/start_stream_server.sh`.
5. Run `bash ImageDiffusion/tunnel_to_stream.sh`.
6. Open `http://localhost:8888/`.

## Video Diffusion Run Discipline

1. Create `config/prime.env` first.
2. `cd VideoDiffusion && bash setup.sh`.
3. `setup.sh` installs `flash-attn` with this policy:
   - attempt wheel-only install first,
   - fallback to constrained source build only when no prebuilt wheel matches,
   - tune build cost with `FLASH_ATTN_MAX_JOBS` and `FLASH_ATTN_NVCC_THREADS` as needed.
   - applies a small MagiAttention compatibility patch so MAGI-1 can call `flex_flash_attn_func(..., max_seqlen_k=...)` on fresh pods.
4. `bash download_weights.sh` (with HF auth first).
5. Use one of the validated smoke profiles below (default one-GPU for cost; override `VIDEO_MAGE_NPROC` for throughput).
6. Validate output frames before scaling.
7. Start stream with `python realtime_magi_stream.py` when smoke test succeeds.

Streaming contract:

- MAGI-1 generates in fixed 24-frame chunks; prompt updates are applied at chunk boundaries (not per-frame).
- Real-time playback at 24 fps requires sustaining `Time Per Output Chunk (TPOC) <= 1s` on steady-state chunks.
- Canonical sizing/latency details live in `docs/video-magi1-streaming.md`.

`VideoDiffusion/test_single_chunk.sh` defaults to one-GPU (`nproc=1`, `CUDA_VISIBLE_DEVICES=0`) and supports scaling via `VIDEO_MAGE_NPROC`/`VIDEO_MAGE_VISIBLE_DEVICES`:

- `example/4.5B/4.5B_distill_quant_config.json` for quantized flow.
- `example/4.5B/4.5B_distill_config.json` for the reliable non-quant flow used for motion checks on SM80/SM86.
- a short local render budget
- output defaults to `VideoDiffusion/magi_try.mp4` unless `VIDEO_MAGE_OUTPUT` is set.

### Latest Validated Profiles

- Ultra-cheap proof-of-life (1 chunk):

  ```bash
  cd VideoDiffusion
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

- Non-quant (reliable smoke + motion profile):

  ```bash
  cd VideoDiffusion
  VIDEO_MAGE_WEIGHT_VARIANT=4.5B_distill bash download_weights.sh
  VIDEO_MAGE_FP8=0 \
  VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_config.json \
  VIDEO_MAGE_PROMPT="Slow dolly shot through a busy cyberpunk alley at night, neon signs flickering, light rain, passing cars and pedestrians moving" \
  VIDEO_MAGE_OUTPUT=magi_dynamic_nonquant.mp4 \
  VIDEO_MAGE_VISIBLE_DEVICES=0 \
  VIDEO_MAGE_NPROC=1 \
  bash ./test_single_chunk.sh
  ```

- Quant (fallback compatibility smoke):

  ```bash
  VIDEO_MAGE_FP8=auto \
  VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_quant_config.json \
  VIDEO_MAGE_PROMPT="Neon city, cinematic cyberpunk alleyway at dusk" \
  VIDEO_MAGE_OUTPUT=magi_try.mp4 \
  VIDEO_MAGE_VISIBLE_DEVICES=0 \
  VIDEO_MAGE_NPROC=1 \
  bash ./test_single_chunk.sh
  ```

For A6000/SM86-class pods, keep `VIDEO_MAGE_FP8=0` (or rely on `auto` in `test_single_chunk.sh`) for deterministic smoke completion.

### Video validation checks

- Confirm that output has expected length/frame count:

  ```bash
  ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames,duration \
    -of default=noprint_wrappers=1:nokey=0 VideoDiffusion/magi_dynamic_nonquant.mp4
  ```

- Detect near-static results:

  ```bash
  ffmpeg -hide_banner -i VideoDiffusion/magi_dynamic_nonquant.mp4 -vf mpdecimate -f null -
  ```

  If most input frames are dropped, switch to an explicit motion prompt.

Do not combine `4.5B_distill_config.json` with quant checkpoints (`4.5B_distill_quant/*`) unless you have intentionally remapped all paths.

## Update Workflow (When You Change Infra)

Any workflow change must update in lockstep:

1. Update implementation script in `ImageDiffusion/` or `VideoDiffusion/`.
2. Update the relevant source-of-truth doc in `docs/`.
3. Update `docs/prime-intellect.md` if provider/cost behavior changes.
4. Keep all provider-specific legacy guidance in `docs/legacy/` only.

## Validation Gate (Minimum)

Run before handing over any branch:

- `bash -n ImageDiffusion/*.sh scripts/prime/*.sh VideoDiffusion/*.sh`
- `python3 -m py_compile ImageDiffusion/realtime_stream.py VideoDiffusion/realtime_magi_stream.py`
- `bash -lc "prime pods status <PRIME_POD_ID>"` (or equivalent health check)

## Cost Control

- Keep pods alive only while testing and stop immediately once smoke tests pass.
- Default to one-GPU pathways for smoke tests; scale up explicitly via environment variables.

## Legacy Archive Rule

- New instructions must be written under `docs/`.
- `docs/legacy/` is historical context only and should not be referenced by onboarding docs.
