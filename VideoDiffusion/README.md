# VideoDiffusion (MAGI-1)

Canonical docs: `docs/video-magi1-streaming.md`

## Run order

```bash
cd VideoDiffusion
bash setup.sh
bash download_weights.sh
# Run 'hf auth login' before download if needed
bash ./test_single_chunk.sh
python realtime_magi_stream.py  # chunk-wise prompt hot-swap (24-frame chunks)
```

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

If you override `VIDEO_MAGE_VIDEO_SIZE_H/W`, keep both values divisible by `16`.

For the lowest-cost reliable smoke path:

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

Quantized baseline smoke:

```bash
VIDEO_MAGE_FP8=0 \
VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_quant_config.json \
VIDEO_MAGE_VISIBLE_DEVICES=0 \
VIDEO_MAGE_NPROC=1 \
VIDEO_MAGE_PROMPT="Neon city, cinematic cyberpunk alleyway at dusk" \
VIDEO_MAGE_OUTPUT=magi_try.mp4 \
bash ./test_single_chunk.sh
```

Validation checks (output file in `VideoDiffusion/`):

```bash
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,duration \
  -of default=noprint_wrappers=1:nokey=0 VideoDiffusion/<OUTPUT_FILE>
ffmpeg -hide_banner -i VideoDiffusion/<OUTPUT_FILE> -vf mpdecimate -f null -
```

## Dependency behavior

`setup.sh` now installs dependencies in three phases:

1. Install MAGI-1 requirements excluding `flash-attn` and `flashinfer-python`.
2. Install `flash-attn` via a wheel-first flow:
   - first try `--only-binary :all:` (fast path)
   - if no wheel matches, fallback to a constrained source build.
3. Install `flashinfer-python` prebuilt when available, else source fallback.

Default envs that can be tuned:

- `FLASH_ATTN_VERSION` (default: `2.4.2`)
- `FLASH_ATTN_MAX_JOBS` (default: `2`)
- `FLASH_ATTN_NVCC_THREADS` (default: `2`)
- `FLASH_ATTN_SKIP_SM90` (default: `AUTO`) — set `1` to skip `compute_90` compile on non-Hopper GPUs.
- `MAGI_ATTENTION_SKIP_SM90` (default: `AUTO`) — set `1` to skip MagiAttention `_sm90` kernels; `AUTO` follows `TORCH_CUDA_ARCH_LIST`.
- `TORCH_CUDA_ARCH_LIST` (default: auto-detected from torch GPU arch list)
- `FLASH_ATTN_FORCE_SOURCE` (optional, default: `0`) — set `1` to skip wheel probe and force source build.
- `FLASH_ATTN_ALLOW_SOURCE_BUILD` (optional, default: `1`) — set `0` to fail fast if wheel is missing.

Tune these to reduce compile footprint on first run:

```bash
export FLASH_ATTN_MAX_JOBS=1
export FLASH_ATTN_NVCC_THREADS=1
export MAGI_ATTENTION_SKIP_SM90=1
bash setup.sh
```

`test_single_chunk.sh` defaults to one-GPU settings for cost control.
