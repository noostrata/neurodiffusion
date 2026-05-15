# VideoDiffusion (Krea Realtime)

_Last updated: 2026-02-18_

This is the canonical Krea realtime runbook for this repository.

## Scope and contract

1. This repo keeps all MAGI-1 flows unchanged.
2. Krea is added as a model-selectable realtime steering path.
3. Unified interface is:
   - `VIDEO_MODEL=magi|krea`
   - `ATTN_BACKEND=auto|sage|flash|sdpa`

## Canonical files

- `VideoDiffusion/setup_video_runtime.sh` — model-dispatched setup entrypoint.
- `VideoDiffusion/setup_krea.sh` — Krea checkout + venv + backend-aware dependency setup.
- `VideoDiffusion/download_krea_weights.sh` — Hugging Face snapshot pull for Krea weights.
- `VideoDiffusion/run_krea_server.sh` — Krea realtime server launcher.
- `VideoDiffusion/run_video_stream.sh` — unified runtime launcher (`magi` or `krea`).
- `VideoDiffusion/publish_r2_prebuild_model.sh` — model-aware runtime tuple publish.
- `VideoDiffusion/restore_r2_prebuild_model.sh` — model-aware runtime tuple restore.
- `scripts/prime/krea_gpu_policies.json` — Krea GPU candidate policy.
- `scripts/prime/query_video_offers.py` — policy-aware availability scan.
- `scripts/prime/select_video_offer.py` — deterministic offer selection.
- `scripts/prime/build_video_runtime_remote.sh` — remote setup/build/publish orchestration on Prime.

## Attention backend policy

`ATTN_BACKEND=auto` resolves with this rule:

1. `B200 -> flash`
2. `H100/H200/GH200/L40S/RTX-Ada/RTX5xxx/A6000 -> sage`
3. otherwise `sdpa`

Manual override:

- `ATTN_BACKEND=flash`
- `ATTN_BACKEND=sage`
- `ATTN_BACKEND=sdpa`

Notes:

1. FlashAttention is not mandatory for Krea.
2. FlashAttention is preferred on B200 for top-end throughput.
3. SDPA fallback is intentionally retained for reliability.
4. If `FLASH_ATTN_ALLOW_SOURCE_BUILD=1`, setup auto-installs `python3.11-dev` and `ninja-build` before compiling `flash-attn`.

## Recommended GPU targets for realtime steering

Ranked for this repo’s steering objective:

1. `B200_180GB x1` + `flash`
2. `H100_80GB x1` + `sage`
3. `GH200_96GB x1` or `H200_141GB x1` + `sage`
4. `L40S_48GB x1`, `RTX6000Ada_48GB x1`, or `A6000_48GB x1` + `sage`

Default practical start: `H100_80GB x1` with `ATTN_BACKEND=auto`.

## Local setup and run

```bash
cd /Users/xenochain/Code/neurodiffusion/VideoDiffusion

# 1) Setup runtime
VIDEO_MODEL=krea \
ATTN_BACKEND=auto \
bash setup_video_runtime.sh

# 2) Download model weights (set your HF repo id)
KREA_MODEL_REPO_ID=<hf_org_or_user>/<repo_name> \
KREA_MODEL_REVISION=main \
bash download_krea_weights.sh

# 3) Start realtime server
VIDEO_MODEL=krea \
ATTN_BACKEND=auto \
bash run_video_stream.sh
```

Optional backend pin:

```bash
VIDEO_MODEL=krea ATTN_BACKEND=flash bash run_video_stream.sh
```

## Prime offer selection (model-aware)

```bash
cd /Users/xenochain/Code/neurodiffusion

python3 scripts/prime/query_video_offers.py \
  --model krea \
  --tier realtime

python3 scripts/prime/select_video_offer.py \
  --model krea \
  --scan-json VideoDiffusion/.tmp/video_offer_scan_krea_realtime.json \
  --selection-goal realtime \
  --print-env
```

## Prime remote build and publish (Krea)

```bash
cd /Users/xenochain/Code/neurodiffusion

VIDEO_MODEL=krea \
ATTN_BACKEND=auto \
KREA_MODEL_REPO_ID=<hf_org_or_user>/<repo_name> \
VIDEO_REMOTE_PUBLISH_PREBUILD=1 \
bash scripts/prime/build_video_runtime_remote.sh
```

This does:

1. sync repo to pod
2. optional restore from R2 runtime tag
3. setup Krea runtime
4. optional weights download
5. publish runtime tuple to R2

Flash tuple pattern from an SDPA restore seed:

```bash
VIDEO_MODEL=krea \
ATTN_BACKEND=flash \
VIDEO_RUNTIME_TAG=krea_flash_py311_torch2.8.0_cu128_sm100 \
VIDEO_REMOTE_RESTORE_TAG=krea_sdpa_py311_torch2.8.0_cu128_sm100 \
VIDEO_REMOTE_RESTORE_MODE=tuple \
FLASH_ATTN_ALLOW_SOURCE_BUILD=1 \
FLASH_ATTN_MAX_JOBS=8 \
FLASH_ATTN_NVCC_THREADS=2 \
VIDEO_REMOTE_DOWNLOAD_WEIGHTS=0 \
VIDEO_REMOTE_INCLUDE_WEIGHTS=0 \
bash scripts/prime/build_video_runtime_remote.sh
```

`VIDEO_REMOTE_RESTORE_TAG` lets you restore one tuple and publish another in one pod workflow.

## R2 publish/restore examples

Publish:

```bash
bash scripts/cloudflare/publish_everything_r2.sh \
  --video-model krea \
  --attn-backend auto \
  --runtime-tag <runtime_tag> \
  --tiers krea-b200-flashattn,krea-hopper-sage,krea-ampere-sage-or-sdpa \
  --include-weights
```

Restore:

```bash
bash VideoDiffusion/restore_r2_prebuild_model.sh \
  --model krea \
  --mode auto \
  --runtime-tag <runtime_tag> \
  --apply-venv-target /root/neurodiffusion/VideoDiffusion/.venv-krea \
  --apply-weights-target /root/neurodiffusion/VideoDiffusion/.cache/krea
```

## Steering defaults

1. Keep denoising steps low (`4-6`) for responsiveness.
2. Keep one GPU per realtime stream as default.
3. Scale by stream count/pod count before single-stream multi-GPU.

## License/commercial warning

Krea upstream release is currently under a non-commercial license (`CC BY-NC-SA 4.0`).
Confirm legal fit before production/commercial deployment.
