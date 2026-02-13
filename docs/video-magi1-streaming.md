# VideoDiffusion (MAGI-1)

This is the canonical runbook for MAGI-1 on Prime Intellect.

## Canonical Files

- `VideoDiffusion/setup.sh` — bootstraps MAGI-1 dependencies and flash-attn/flashinfer policy.
- `VideoDiffusion/download_weights.sh` — fetches checkpoint, VAE, and T5 weights.
- `VideoDiffusion/test_single_chunk.sh` — one-shot smoke test entrypoint.
- `VideoDiffusion/realtime_magi_stream.py` — live MJPEG stream server entrypoint.
- `scripts/prime/resolve_ssh.sh` — shared Prime SSH resolver.

## Default remote workflow

1. Provision pod and set `config/prime.env`.
2. Prepare runtime and deps:

   ```bash
   cd VideoDiffusion
   bash setup.sh
   ```

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

## Copy local for review

Pod output lives in:

`/root/neurodiffusion/VideoDiffusion/<OUTPUT_FILENAME>`

Example (non-quant smoke):

```bash
scp -P <PRIME_SSH_PORT> <PRIME_SSH_USER>@<PRIME_SSH_HOST>:/root/neurodiffusion/VideoDiffusion/magi_dynamic_nonquant.mp4 "$HOME/Downloads/magi_dynamic_nonquant.mp4"
```

## Execution behavior

- `test_single_chunk.sh` defaults to one-GPU smoke (`VIDEO_MAGE_NPROC=1`, `CUDA_VISIBLE_DEVICES=0`).
- `VIDEO_MAGE_FP8` values:
  - `auto` (default): enable fp8 only when an SM90-capable GPU is detected.
  - `0/off/no/false`: force fp8 off.
  - `1/on/yes/true`: force fp8 on.
- `VIDEO_MAGE_NPROC=auto` is supported and maps to the number of devices in `VIDEO_MAGE_VISIBLE_DEVICES`.
- Optional cost/throughput overrides (applied by `test_single_chunk.sh` without editing vendor configs):
  - `VIDEO_MAGE_NUM_STEPS`
  - `VIDEO_MAGE_NUM_FRAMES` (use `24` for exactly one chunk)
  - `VIDEO_MAGE_VIDEO_SIZE_H`, `VIDEO_MAGE_VIDEO_SIZE_W` (must be divisible by `16`)
  - `VIDEO_MAGE_WINDOW_SIZE`

## Chunked generation and prompt hot-swap

MAGI-1 is a chunked autoregressive denoising video model: it generates video in **fixed 24-frame chunks**, where each new chunk conditions on previously generated chunks (paper Figure 1, arXiv:2505.13211). This makes streaming natural, and it also defines the prompt update granularity: **prompt changes apply at chunk boundaries, not per-frame**.

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
- `MAGI_WINDOW_SIZE` (recommended: `1` for tight prompt hot-swap) — larger values can improve throughput but make prompt changes feel less immediate because multiple chunks may be in-flight.
- `MAGI_NUM_STEPS`, `MAGI_VIDEO_SIZE_H`, `MAGI_VIDEO_SIZE_W`, `MAGI_NUM_FRAMES` — optional overrides applied by the stream server at startup (testing only; avoids editing vendor configs).

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

## Real-time sizing (TTFC/TPOC)

The paper frames “real-time streaming” using two latency metrics:

- **TTFC** (Time To First Chunk): time until the first 24-frame chunk is ready.
- **TPOC** (Time Per Output Chunk): time to generate each subsequent 24-frame chunk.

For uninterrupted playback at 24 fps, each chunk spans 1 second of video (24 frames). So a practical real-time target is:

- `TPOC <= 1.0s` (sustainability)
- `TTFC` as low as possible (responsiveness)

### Measuring in this repo

`realtime_magi_stream.py` logs per-chunk generation time and an effective FPS estimate:

- `[producer] Chunk N generated in X.XXXs (YY.YY fps)`

To sustain 24 fps streaming, you want `X.XXXs <= 1.0s` on steady-state chunks.

### Hardware guidance (paper-backed + Prime availability)

Paper-backed baseline:

- The paper (arXiv:2505.13211) describes achieving real-time streaming for the **24B** model on a **3-node, 24× H100** setup (with a heterogeneous serving pipeline).
- This repo’s scripts are optimized for single-host bring-up. Multi-node orchestration is not automated here; treat paper numbers as a sizing target, not a drop-in guarantee.

Prime availability is dynamic. Re-run:

```bash
prime availability list --gpu-type H100_80GB --regions eu_north
prime availability list --gpu-type H100_80GB --regions united_states --gpu-count 24
```

Snapshot (as observed on 2026-02-13):

- `eu_north` (FI):
  - 1× H100 80GB (Spot): ~$0.80/hr
  - 2× H100 80GB (Spot): ~$1.60/hr
  - 1× H100 80GB (On-demand): ~$2.29/hr
  - 2× H100 80GB (On-demand): ~$4.58/hr
- `united_states`:
  - 24× H100 80GB (dc_roan): ~$47.76/hr (SXM5)
  - 8× H100 80GB (primecompute spot): ~$8.00/hr

Back-of-envelope cost math (using the snapshot rates above):

- 1× H100 (Spot, `eu_north`): ~$0.13 per 10 minutes
- 24× H100 (`united_states`): ~$7.96 per 10 minutes

For most operators:

- Start with 1× H100 (Spot) in `eu_north` for prompt-reactive bring-up and measure chunk time.
- If you cannot reach `TPOC <= 1s`, reduce resolution/steps first. Only then scale GPUs.

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
- If output is mostly static, increase motion cues in prompt (tracking move, traffic, flickering lights, weather, moving crowds, subtle camera jitter).

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
- Stop or terminate immediately after successful smoke:

```bash
prime pods stop <POD_ID>
# Or (recommended when you're done and want to end spend completely):
prime pods terminate <POD_ID> --yes
```

## Compatibility notes

- If you see `TypeError: flex_flash_attn_func() got an unexpected keyword argument 'max_seqlen_k'`, your MagiAttention
  checkout is missing a compatibility arg required by current MAGI-1. `VideoDiffusion/setup.sh` applies an automatic
  patch on install; rerun `bash setup.sh` if you hit this on a fresh pod.

- Legacy VAST.ai notes are in `docs/legacy/`.
- Onboarding, execution, and runbook flow should use:
  - `docs/image-streaming.md`
  - `docs/video-magi1-streaming.md`
  - `docs/prime-intellect.md`
