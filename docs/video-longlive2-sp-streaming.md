# LongLive2 Sequence-Parallel Runbook

_Last updated: 2026-05-21_

This is the planning runbook for a one-stream, multi-GPU LongLive2 path.
The objective is one live video stream whose generation state is split across two or more GPUs, not two independent Scope streams.

## Status

Current status: local plumbing implemented and no-cost validated; no paid LongLive2 GPU run has been launched from this repo yet.

LongLive2 is a separate experimental lane from Daydream Scope + LongLive:

1. Scope + LongLive remains the validated one-GPU realtime baseline.
2. LongLive2 is the candidate for one-stream multi-GPU inference because upstream exposes sequence-parallel inference through `inference_sp.py`.
3. LongLive2 does not currently run through Scope REST/OSC.
4. EEG integration starts as an offline prompt-block schedule because upstream LongLive2 currently exposes an offline inference entry point, not a Scope-style live OSC/WebRTC server.

## Source Snapshot

Primary upstream sources checked on 2026-05-21:

1. NVLabs LongLive repo: https://github.com/NVlabs/LongLive
2. LongLive2 project page: https://nvlabs.github.io/LongLive/LongLive2/
3. LongLive2 paper: https://arxiv.org/abs/2605.18739
4. LongLive2 BF16 Hugging Face model card: https://huggingface.co/Efficient-Large-Model/LongLive-2.0-5B
5. LongLive2 NVFP4 S4 Hugging Face model card: https://huggingface.co/Efficient-Large-Model/LongLive-2.0-5B-NVFP4-S4
6. LongLive2 NVFP4 S2 Hugging Face model card: https://huggingface.co/Efficient-Large-Model/LongLive-2.0-5B-NVFP4-S2
7. LongLive 1.0 paper: https://arxiv.org/abs/2509.22622

Repository state observed:

1. Upstream `main` commit: `536d1b9a3563b078bea378aa968416543fd9d669`.
2. Upstream `v1.0` branch keeps the original LongLive 1.0 path.
3. Upstream `main` includes `inference.py`, `inference_sp.py`, `configs/inference.yaml`, `configs/inference_sp.yaml`, and `configs/nvfp4/inference_nvfp4.yaml`.
4. `configs/inference_sp.yaml` documents Ulysses sequence-parallel inference with `torchrun --nproc_per_node=4 inference_sp.py --config_path configs/inference_sp.yaml`.
5. `inference_sp.py` computes valid SP sizes from `gcd(model_num_heads, num_frame_per_block)`. With the shipped values `model_num_heads=24` and `num_frame_per_block=8`, valid `sp_size` values include `1`, `2`, `4`, and `8`. The repo target for one-stream two-card testing is therefore `sp_size=2`, `dp_size=1`, `--nproc_per_node=2`.

Upstream capability claims:

1. LongLive2 supports sequence-parallel inference.
2. LongLive2 supports NVFP4 W4A4 inference, FP4 KV-cache quantization, multi-shot attention sinks, and asynchronous/streaming VAE decode.
3. The paper reports up to `1.84x` inference speedup and `45.7 FPS` for LongLive2-5B in the reported 2-step setup.
4. The project page reports `19.4GB` peak memory with NVFP4 KV cache and `45.7 FPS` on GB200 with 2-step generation.

## Paper-Derived Constraints

LongLive 1.0 is the interaction design reference:

1. It uses a causal frame-level AR design so inference can reuse KV cache instead of recomputing full bidirectional context.
2. Prompt switching is not just "send a new prompt"; the paper identifies two failure modes: dropping cache gives abrupt visual discontinuity, while retaining stale cache can ignore the new prompt.
3. KV-recache is the proposed fix: rebuild cache at the prompt boundary from already generated visual context plus the new prompt.
4. Streaming long tuning matters because train-short/test-long AR models accumulate error; the model must be exposed to its own generated history during training.
5. Short-window attention plus frame sink is the speed/consistency tradeoff: keep a rolling local KV window and retain first-frame/chunk sink tokens as persistent global anchors.
6. The reported LongLive 1.0 reference is `20.7 FPS` on one H100 and up to `240s` on one H100, but this repo's validated Scope/LongLive path is a separate implementation with lower resolution ceilings so far.

LongLive2 changes the infrastructure target:

1. Training uses Balanced SP: clean-history and noisy-target chunks are paired per rank so work is not clean-heavy/noisy-heavy on different GPUs.
2. Inference supports sequence parallelism through Ulysses SP. This is the code path we use for one-stream multi-GPU testing.
3. NVFP4 is not merely post-training compression in the paper; the best quality story is training/inference alignment. Direct PTQ is called out as lower quality, so repo docs should not imply that arbitrary BF16 checkpoints can be cheaply PTQ'd into the same quality tier.
4. Blackwell is the native full NVFP4 performance target. On non-Blackwell GPUs, the paper points to SP inference as the practical way to recover speed.
5. Asynchronous/streaming VAE decode is part of end-to-end FPS. Model-only FPS is not sufficient for our acceptance gate.
6. The upstream SP script disables `kv_quant` under Ulysses SP today. Therefore the first Hopper two-card smoke is BF16 SP, not NVFP4+KV quant.

Implementation consequences in this repo:

1. `VIDEO_MODEL=longlive2` is a direct backend, not a `longlive` Scope alias.
2. EEG schedules are compiled to LongLive2 prompt chunks through the upstream `MultiTextConcatDataset` directory format.
3. Prompt updates are block/chunk-level for the offline runner. Live EEG requires a future persistent runner that can recache/apply prompt changes at native boundaries.
4. The first valid two-card test is `sp_size=2`, `dp_size=1`, `--nproc_per_node=2`; data parallelism is not a one-stream result.
5. The default native latent shape remains `44x80` for `704x1280` output at `F=128` or `F=384`; arbitrary 1080p/4K should not be assumed.

## First-Principles Target

For one live stream, two GPUs only help if they reduce latency inside one generation state.

Data parallelism is not the target because it produces multiple independent samples.
The target is sequence parallelism:

```text
EEG state
  -> prompt/runtime controller
  -> one LongLive2 AR video state
  -> sequence-parallel DiT inference across GPU ranks
  -> rank 0 output assembly / VAE / video sink
  -> one local MP4 or one live WebRTC stream
```

The practical success metric is not "both GPUs exist".
The success metric is lower end-to-end seconds per generated frame or higher receive FPS for the same output quality and resolution.

## Runtime Lanes

### Lane A: BF16 SP Proof

Purpose: prove one-stream distributed inference with the least specialized environment.

Expected tuple:

```text
longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1
```

Use this lane first on `H100 x2`, `H200 x2`, or another reliable Hopper two-GPU Vast offer.

Upstream environment:

1. Python `3.10`.
2. PyTorch `2.8.0`.
3. TorchVision `0.23.0`.
4. CUDA `12.8`.
5. `flash-attn --no-build-isolation`.

Initial launch shape:

```bash
torchrun --standalone --nnodes=1 --nproc_per_node=2 \
  inference_sp.py \
  --config_path configs/inference_sp.yaml
```

Required config edits:

1. `sp_size: 2`
2. `dp_size: 1`
3. `data.data_path: <prompt file or prompt folder>`
4. `checkpoints.generator_ckpt: <BF16 generator checkpoint>`
5. `checkpoints.lora_ckpt: <optional DMD LoRA checkpoint>`
6. `output_folder: <run output dir>`
7. conservative first run: low `num_output_frames`, low resolution, one prompt

### Lane B: NVFP4 S2 Maximum-Performance Path

Purpose: chase maximum FPS and resolution after the distributed path works.

Expected tuple families:

```text
longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm100_prebuild1
longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm120_prebuild1
```

Use this lane on Blackwell-class hosts first:

1. B200 / GB200 / GB300: build with `CUDA_ARCHS=100`.
2. RTX 50/60 class: build with `CUDA_ARCHS=120` only if Vast offers are reliable and CUDA `12.8` support is clean.

Upstream environment:

1. Python `3.12`.
2. PyTorch `2.10.0+cu128`.
3. TorchVision `0.25.0+cu128`.
4. FlashAttention `2.8.3` from source.
5. local `fouroversix` build.
6. local `utils/kernel` FP4 KV-cache dequant extension build.
7. optional TransformerEngine path only when intentionally using TE runtime quantization.

Preferred first NVFP4 model artifact:

```text
Efficient-Large-Model/LongLive-2.0-5B-NVFP4-S2
```

Use `inference.sampling_steps: 2` for the S2 checkpoint unless the model card changes.

## Implemented Repo Plumbing

This repo now has a separate `VIDEO_MODEL=longlive2` family, not a Scope alias.

Implemented files:

1. `VideoDiffusion/setup_longlive2.sh`
   - clones `https://github.com/NVlabs/LongLive` into `VideoDiffusion/.vendors/LongLive2`;
   - pin `LONGLIVE2_REPO_REF` by commit, defaulting to the researched commit until deliberately refreshed;
   - creates an ignored runtime env file under `VideoDiffusion/.longlive2_runtime.env`;
   - supports `--skip-build` for cheap clone/config steps;
   - supports BF16 and NVFP4 profile setup, including FourOverSix and pinned flash-attention source build for NVFP4.
2. `VideoDiffusion/download_longlive2_models.sh`
   - downloads BF16, NVFP4 S4, or NVFP4 S2 checkpoints into ignored cache paths;
   - optionally downloads Wan2.2-TI2V-5B base assets;
   - writes a sanitized model manifest without tokens, hostnames, or secret env.
3. `VideoDiffusion/longlive2_config.py`
   - generates patched inference configs;
   - sets `sp_size`, `dp_size`, prompt path, checkpoint paths, output folder, frame count, sampling steps, and resolution shape;
   - rejects impossible SP settings before paid launch;
   - converts EEG schedule CSV or repeated `--shot-prompt` inputs into the upstream prompt-folder layout.
4. `VideoDiffusion/run_longlive2_sp_offline.sh`
   - runs an offline render through `torchrun`;
   - supports `sp_size * dp_size` process count;
   - writes config, launch plan, torchrun log, GPU telemetry, report JSON, artifact QA, and contact sheet.
5. `VideoDiffusion/run_longlive2_sp_vast_smoke.sh`
   - provisions a two-GPU Vast host only when `--create-instance` is passed;
   - selects offers with `--min-gpu-count 2 --max-gpu-count 2`;
   - restores R2 tuple when available;
   - build/download fallback only when explicitly allowed;
   - runs one short SP inference;
   - pulls local MP4, logs, config, phase telemetry, and GPU telemetry;
   - tears down by default.
6. `VideoDiffusion/longlive2_run_report.py`
   - parses torchrun logs for SP group layout;
   - parses per-GPU utilization;
   - reads `ffprobe` metadata when output exists;
   - generates contact sheet and nonblank artifact QA when possible.
7. R2 dispatch updates:
   - `--model longlive2` is supported in `VideoDiffusion/publish_r2_prebuild_model.sh`;
   - `--model longlive2` is supported in `VideoDiffusion/restore_r2_prebuild_model.sh`;
   - default tuple tiers are `longlive2-bf16-sp-hopper,longlive2-nvfp4-blackwell`.
8. Vast selector updates:
   - `scripts/vast/query_video_offers.py --model longlive2` targets two-GPU datacenter CUDA 12.8 hosts;
   - `scripts/vast/select_video_offer.py` handles `sm90`, `sm100`, and `sm120` runtime tags;
   - SP smoke defaults to two GPUs and logs GPU names plus telemetry.

No-cost validation commands:

```bash
python3 VideoDiffusion/longlive2_config.py selftest
python3 VideoDiffusion/longlive2_run_report.py selftest
bash VideoDiffusion/run_longlive2_sp_offline.sh --dry-run --frames 16 \
  --shot-prompt "A calm luminous ocean breathes slowly." \
  --shot-prompt "A frantic neon tunnel accelerates." \
  --shot-duration 1 \
  --shot-duration 1
```

## R2 Tuple Boundary

R2 can store:

1. LongLive2 vendor checkout or repo bundle reference.
2. Python environment archive.
3. prebuilt wheels and compiled local extensions.
4. HF model cache and explicit checkpoint directories.
5. merged BF16 generator checkpoints.
6. materialized FourOverSix NVFP4 checkpoints.
7. run outputs and reports.

R2 cannot store:

1. a live NCCL process group;
2. GPU-resident model state;
3. a warmed WebRTC session;
4. host-specific kernel autotune state unless it is explicitly written to a reusable cache and verified portable.

Suggested R2 layout:

```text
neurodiffusion/env-cache/<longlive2_runtime_tag>/
neurodiffusion/weights/<longlive2_runtime_tag>/
neurodiffusion/wheelhouse/<longlive2_runtime_tag>/
neurodiffusion/manifests/runtime-tuples/<longlive2_runtime_tag>/latest.json
neurodiffusion/runs/<run_id>/
neurodiffusion/benchmarks/longlive2_sp/
```

Publish only after a paid host proves that the environment imports, the extensions load, and a minimal render completes.

## Test Plan

### No-Cost Local Tests

These can run without GPU hardware:

1. config generation selftest for `sp_size=2`, `dp_size=1`;
2. invalid SP selftest, for example `sp_size=3` should fail because it does not divide `gcd(24, 8)`;
3. prompt-folder generator selftest for single-shot and multi-shot layouts;
4. dry-run launch command test that prints the exact `torchrun` command without executing it;
5. R2 manifest dry-run with fake paths;
6. report parser selftest using captured or synthetic torchrun logs;
7. teardown parser selftest for Vast instance IDs.

### Paid GPU Test 1: BF16 SP Bring-Up

Goal: prove one stream uses two ranks.

Constraints:

1. `--min-gpu-count 2 --max-gpu-count 2`.
2. `--max-attempt-wall-clock-s` around `1800` for first smoke.
3. `--destroy-on-exit` default true.
4. pull local output before teardown.

Acceptance:

1. `torchrun` starts two ranks.
2. logs show SP mode enabled with `sp_size=2`.
3. both GPUs show nontrivial utilization during denoising.
4. one MP4 is written by rank 0.
5. `ffprobe` confirms duration, resolution, frame count, and fps.
6. sampled frames are nonblank.
7. final `vastai show instances --raw` returns `[]`.

### Paid GPU Test 2: One-GPU vs Two-GPU Speedup

Goal: prove that sequence parallelism improves one stream, not just throughput accounting.

Run the same prompt/config in this order:

1. `sp_size=1`, `--nproc_per_node=1`, one GPU visible.
2. `sp_size=2`, `--nproc_per_node=2`, two GPUs visible.

Record:

1. wall-clock generation time;
2. frames/sec from output metadata;
3. GPU utilization and VRAM;
4. NCCL or communication warnings;
5. visual QA contact sheets;
6. total cost and wall-clock alive time.

Decision rule:

1. continue two-GPU work if speedup is `>=1.3x`;
2. make two-GPU SP a preferred path only if speedup is `>=1.6x` and cost per realtime frame is competitive with the best one-GPU Scope baseline;
3. abandon two-GPU SP for live work if speedup is marginal or unstable, while keeping it as an offline render option.

### Paid GPU Test 3: NVFP4 S2 Performance

Goal: maximize realtime FPS and resolution.

Start with B200/GB200 before cheaper RTX 50/60 offers because the upstream NVFP4 path documents `CUDA_ARCHS=100` explicitly.
Only test RTX 50/60 after the SM100 lane is validated or if budget demands a cheaper Blackwell attempt.

Acceptance:

1. NVFP4 extensions import.
2. FP4 KV dequant extension imports.
3. S2 checkpoint loads with `sampling_steps: 2`.
4. output quality is not obviously degraded relative to BF16/4-step for the same prompt.
5. throughput is high enough to justify the higher setup complexity.

## Live EEG Integration Plan

Do not wire EEG directly into `inference_sp.py` first.
The upstream script is an offline entry point that reads prompt files and writes video.

Integration stages:

1. Offline EEG schedule:
   - synthetic EEG state changes write a prompt folder;
   - LongLive2 generates a multi-shot video;
   - this tests alpha/beta policy language without a live stream.
2. Persistent Python runner:
   - import `CausalDiffusionInferencePipelineSP`;
   - keep the pipeline alive after load;
   - accept state changes through a queue or local HTTP/OSC bridge;
   - apply prompt changes at LongLive2 chunk boundaries.
3. Live output:
   - rank 0 owns video assembly and WebRTC or local display output;
   - nonzero ranks only participate in distributed inference;
   - EEG loop sends low-rate stable state updates with cooldown, same policy as Scope.

The live runner is the real art-system deliverable.
The offline `torchrun` smoke is only the proof that the model/runtime is viable.

## Performance Strategy

Default order:

1. prove BF16 SP works on a two-GPU Hopper host;
2. publish the BF16 SP tuple to R2;
3. test one-GPU vs two-GPU speedup;
4. test NVFP4 S2 on SM100;
5. publish the NVFP4 S2 tuple to R2;
6. build a persistent runner only after a distributed inference lane has useful speedup.

Quality knobs:

1. BF16/4-step is the quality reference.
2. NVFP4/2-step is the speed reference.
3. Use the same prompt, seed, frame count, and resolution for A/B runs.
4. Keep contact sheets and short local MP4s for visual inspection.
5. Do not promote a speed path if prompt adherence or temporal coherence visibly collapses.

Cost knobs:

1. prefer same-instance sweeps after a host is paid for;
2. cap first smoke wall-clock aggressively;
3. stop immediately after a failed import/build unless the error is clearly fixable within the current budget;
4. publish successful env/model tuples before terminating the builder instance;
5. never keep an instance alive just to preserve a loaded model unless the user explicitly asks.

## Done State

Local plumbing is done when:

1. no-cost local selftests pass;
2. `bash scripts/check.sh` passes;
3. a dry-run LongLive2 SP plan emits a deterministic two-GPU launch command;
4. docs list the exact scripts and boundaries.

First paid validation is done when:

1. a paid BF16 two-GPU smoke produces one local MP4 and a run report;
2. per-GPU telemetry proves both cards were used;
3. the instance is destroyed and active instances are checked;
4. the reusable tuple is published to R2 if the environment is worth preserving;
5. docs record the exact run root, timings, spend, and artifact paths.
