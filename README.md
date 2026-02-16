# neurodiffusion

Prime Intellect-first repository for image/video diffusion workflows with a single remote provider model.

## What this repo contains

- `ImageDiffusion/` — SD-Turbo real-time image streaming (MJPEG).
- `VideoDiffusion/` — MAGI-1 text-to-video stack and stream server (chunk-wise prompt hot-swap).
- `scripts/prime/` — Prime offer query/selection, pod lifecycle, and SSH resolver scripts.
- `docs/` — canonical operator documentation.
- `config/` — local templates and ignored overrides.

## First setup

1. Install and configure Prime CLI.
2. Create `config/prime.env` from `config/prime.env.example`.
3. Source Cloudflare R2 credentials for artifact/cache workflow:
   - `source /Users/xenochain/agents/secrets/r2_full_access.env`
4. Follow `docs/prime-intellect.md` to launch a pod.
5. Validate SSH once: `prime pods ssh <POD_ID>`.

## Fastest cold-start path (recommended)

Yes, the fastest practical workflow is to combine:

1. a prebuilt Prime custom image with MAGI dependencies already installed
2. Cloudflare R2 for reusable wheel/cache bundles and output persistence

Operationally:

1. Build image once and reuse for pods.
2. Keep R2 `wheelhouse/`, `env-cache/`, and `runs/` prefixes.
3. Pull cache bundle on pod boot, run test, push outputs to R2, terminate pod.

Canonical storage contract:

- `docs/cloudflare-r2.md`

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

4. For higher-quality motion checks, follow `docs/video-magi1-streaming.md` (non-quant profile).
5. Terminate the pod immediately after validation:
   - `prime pods terminate <POD_ID> --yes`

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

### Image

- `bash ImageDiffusion/remote_setup.sh`
- `bash ImageDiffusion/start_stream_server.sh`
- `bash ImageDiffusion/tunnel_to_stream.sh`

### Video

- `bash VideoDiffusion/setup.sh`
- `bash VideoDiffusion/download_weights.sh`
- `bash VideoDiffusion/test_single_chunk.sh` (default one-GPU, scalable via `VIDEO_MAGE_NPROC`/`VIDEO_MAGE_VISIBLE_DEVICES`)
- `python VideoDiffusion/realtime_magi_stream.py` (prompt changes apply at **24-frame chunk boundaries**; see `docs/video-magi1-streaming.md`)
- `bash VideoDiffusion/test_scripted_30s.sh` (budget-guarded 30s scripted prompt injection run; requires `HOURLY_RATE_USD`)
- `bash VideoDiffusion/run_scripted_30s_prime.sh --mode lifecycle --tier 4.5b` (Prime discovery -> select -> provision -> remote run -> terminate)
- `bash VideoDiffusion/run_prime_gpu_matrix.sh --tier 4.5b --budget-usd 15` (systematic multi-GPU-type matrix run)
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
  HOURLY_RATE_USD=0.6068 \
  BUDGET_USD=15 \
  CUDA_VISIBLE_DEVICES=0,1,2,3 \
  bash ./test_scripted_30s.sh
  ```
- Prime lifecycle example (no manual pod commands):
  ```bash
  cd /Users/xenochain/Code/neurodiffusion
  bash VideoDiffusion/run_scripted_30s_prime.sh \
    --mode lifecycle \
    --tier 4.5b \
    --budget-usd 15 \
    --regions eu_north,eu_east,eu_west,united_states
  ```

## Reference docs

- `docs/prime-intellect.md`
- `docs/prime/how_keys.md`
- `docs/cloudflare-r2.md`
- `docs/accelerate.md`
- `docs/image-streaming.md`
- `docs/video-magi1-streaming.md`
- `docs/video-magi1-scaling-testing.md`
- `docs/video-magi1-observations.md`
- `docs/security.md`
- `docs/references.md`

## Prime billing note

As of `prime` CLI `v0.5.36`, numeric credit balance is not exposed by `prime whoami` or `prime teams list`.
Use the Prime billing dashboard for exact credits:

- `https://app.primeintellect.ai/dashboard/billing`

## Output convention

- Render artifacts (including `*.mp4`) are gitignored.
- Keep generated artifacts in `~/Downloads` or a dedicated validation folder.
