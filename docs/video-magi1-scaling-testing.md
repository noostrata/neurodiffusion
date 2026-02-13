# MAGI-1 Scaling (Testing Phase)

This repo supports **chunk-wise prompt hot-swap** (24-frame chunks). This doc is a pragmatic test design to:

- make MAGI chunk generation faster (lower `TPOC`)
- verify prompt changes apply between chunks (not per-frame)
- keep costs bounded (short tests, stop pods immediately)

Canonical runtime behavior is documented in `docs/video-magi1-streaming.md`.

## Metrics (what we measure)

- **TTFC** (Time To First Chunk): time until the first 24-frame chunk is produced.
- **TPOC** (Time Per Output Chunk): time to produce each subsequent 24-frame chunk.
- **Prompt hot-swap latency**: time from `POST /prompt` until `/stats` reports a chunk generated with the new prompt.

Real-time playback at 24 fps needs `TPOC <= 1s` in steady state.

## Test matrix (what we vary)

Vary one axis at a time:

- Hardware: GPU type + count (start small)
- Inference config: resolution + steps + quant/fp8
- Stream buffering: `QUEUE_LEN`, `DROP_OLD_ON_PROMPT`, `JPEG_QUALITY`

## Baseline: prompt-reactive stream setup

On the pod (inside the MAGI env):

```bash
cd /root/neurodiffusion/VideoDiffusion

# Keep latency tight: small buffer, drop old frames after prompt change.
export QUEUE_LEN=96
export DROP_OLD_ON_PROMPT=1
export JPEG_QUALITY=75

# Keep hot-swap deterministic: one chunk in flight.
export MAGI_WINDOW_SIZE=1

# Optional: lower compute for testing.
# NOTE: keep H/W divisible by 16 (e.g., 384x384) to avoid shape mismatches.
# export MAGI_VIDEO_SIZE_H=384
# export MAGI_VIDEO_SIZE_W=384
# export MAGI_NUM_STEPS=8

# Use all visible GPUs (single-node).
export CUDA_VISIBLE_DEVICES=0

python realtime_magi_stream.py
```

On your local machine (through your SSH tunnel to `localhost:8000`):

```bash
python VideoDiffusion/bench_prompt_hot_swap.py --url http://localhost:8000 --rounds 2
```

## Scaling in Northern Europe (Prime `eu_north`)

As of 2026-02-13, `eu_north` offered (spot):

- 1× H100 80GB (SXM5): ~$0.80/hr
- 2× H100 80GB (SXM5): ~$1.60/hr
- 8× RTX4090 24GB (PCIe): ~$4.74/hr

Check fresh availability before provisioning:

```bash
prime availability list --gpu-type H100_80GB --regions eu_north
prime availability list --gpu-type RTX4090_24GB --regions eu_north --gpu-count 8
```

### Recommended scale-up sequence (testing)

1. **1× H100 (spot)**: verify setup + measure baseline `TPOC` and hot-swap latency.
2. **2× H100 (spot)**: rerun the exact same test and compare.
3. **8× RTX4090** (optional): only if the model/config fits VRAM and you want throughput experiments.

If you need 8+ H100 or 24× H100 (paper-scale real-time for 24B), you will likely need a different region/provider offering that topology.

### Multi-GPU note (single node)

MAGI-1 uses `torch.distributed`. For multi-GPU streaming on a single host, prefer `torchrun`:

```bash
export CUDA_VISIBLE_DEVICES=0,1
export MAGI_CP_SIZE=2
export MAGI_PP_SIZE=1
torchrun --standalone --nproc_per_node=2 realtime_magi_stream.py
```

## Knobs that move `TPOC`

Always prefer reducing compute before buying more GPUs:

- Reduce resolution (360p/480p vs 720p).
- Reduce `num_steps` (quality vs speed).
- Use Hopper-friendly quant/fp8 when available (H100 is SM90).
- Keep stream encode overhead small (`JPEG_QUALITY`, smaller `QUEUE_LEN`).

## Cost discipline

- Do not leave pods running between tests.
- Terminate pods immediately when a test finishes:
  - `prime pods terminate <POD_ID> --yes`
