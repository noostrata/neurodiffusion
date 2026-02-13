# neurodiffusion

Prime Intellect-first repository for image/video diffusion workflows with a single remote provider model.

## What this repo contains

- `ImageDiffusion/` — SD-Turbo real-time image streaming (MJPEG).
- `VideoDiffusion/` — MAGI-1 text-to-video stack and stream server (chunk-wise prompt hot-swap).
- `scripts/prime/` — shared Prime SSH resolver.
- `docs/` — canonical operator documentation.
- `config/` — local templates and ignored overrides.

## First setup

1. Install and configure Prime CLI.
2. Create `config/prime.env` from `config/prime.env.example`.
3. Follow `docs/prime-intellect.md` to launch a pod.
4. Validate SSH once: `prime pods ssh <POD_ID>`.

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
5. Stop/terminate the pod immediately after validation.

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
- multi-GPU smoke example:
  ```bash
  VIDEO_MAGE_PROMPT="Neon city, cinematic cyberpunk alleyway at dusk" \
  VIDEO_MAGE_OUTPUT=magi_try.mp4 \
  VIDEO_MAGE_VISIBLE_DEVICES=0,1 \
  VIDEO_MAGE_NPROC=2 \
  bash VideoDiffusion/test_single_chunk.sh
  ```

## Reference docs

- `docs/prime-intellect.md`
- `docs/prime/how_keys.md`
- `docs/image-streaming.md`
- `docs/video-magi1-streaming.md`
- `docs/security.md`
- `docs/references.md`

## Output convention

- Render artifacts (including `*.mp4`) are gitignored.
- Keep generated artifacts in `~/Downloads` or a dedicated validation folder.
