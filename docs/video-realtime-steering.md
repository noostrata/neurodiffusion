# Realtime Steering Architecture

_Last updated: 2026-05-20_

This document is the cross-model policy for realtime inference with realtime steering in this repo.

## Objective

1. Primary objective: interactive steering responsiveness.
2. Secondary objective: long-horizon cinematic coherence.
3. Keep Scope/LongLive, Krea, and MAGI-1 supported in one codebase.

## Ranking metric

Use this weighted score per candidate stack:

`RTS Score = 0.40*Quality + 0.30*SteeringLatency + 0.20*Stability + 0.10*CostEfficiency`

Definitions:

- `Quality`: motion fidelity + visual consistency at matched latency.
- `SteeringLatency`: prompt-change to visible-change delay.
- `Stability`: startup/build reliability + runtime resilience.
- `CostEfficiency`: throughput achieved per dollar.

## Ranked deployment targets

| Rank | Stack | Why | Indicative hourly rate |
| --- | --- | --- | ---: |
| 1 | Scope + LongLive on B200/Hopper, with `RTX 5090/L40S` candidates | Best proven realtime EEG target; Scope-native control; B200 already passed `320x576` | dynamic Vast rates |
| 2 | LongLive2 sequence-parallel direct backend | Best researched path for one stream across two GPUs; not yet validated in this repo | likely two-GPU Vast rates |
| 3 | Scope + StreamDiffusion V2 / RewardForcing | Same Scope control surface, useful follow-on A/B backends | similar 24GB tier |
| 4 | Causal Forcing++ direct backend | Strong 1-step/2-step AR research path; needs custom adapter | unknown |
| 5 | Krea Realtime 14B | Higher quality, heavier runtime; test after Scope control is proven | `~0.94+` 5090, B200 much higher |
| 6 | MAGI-1 4.5B/24B | Async or chunked high-quality background renderer | A100/Hopper dependent |

## Attention/backend policy

1. On `B200`: prefer `flash`.
2. On `H100/H200/GH200/L40S/RTX-Ada/RTX5xxx`: prefer `sage`.
3. Keep `flash` optional outside B200.
4. Keep `sdpa` fallback always available.

## Scaling policy

1. Krea defaults to `1 GPU = 1 realtime stream`.
2. Scale Krea with pod count/stream count first.
3. Use single-stream multi-GPU only after proving real speedup on the exact path; LongLive2 SP is the current candidate.
4. MAGI uses the existing calibration ladder for strict chunk-time targets.

## Runtime defaults for steering

1. Scope/LongLive: use OSC for prompt/runtime updates; keep transition steps low (`4-8`) for visible smooth changes.
2. Krea: low denoising steps (`4-6`) for fast steering response.
3. MAGI: keep `MAGI_WINDOW_SIZE=1`, small queue, prompt-drop-old enabled.
3. Respect native update boundaries:
   - Scope: next generated chunk/frame cadence through OSC/WebRTC runtime parameters.
   - Krea: denoise iteration cadence.
   - MAGI: 24-frame chunk boundaries.

## Build/cache strategy on Vast + R2

Model tuple families:

1. `krea-b200-flashattn`
2. `krea-hopper-sage`
3. `krea-ampere-sage-or-sdpa`
4. existing MAGI tuples unchanged (`4.5b`, `24b`)
5. planned LongLive2 tuples: `longlive2_bf16_sp_*`, `longlive2_nvfp4_s2_*`

On pod boot:

1. restore runtime tuple from R2
2. warm runtime
3. start stream server
4. for Scope/LongLive resolution edge-finding on one GPU, use `VideoDiffusion/run_scope_longlive_vast_sweep.sh` so one restore/server start can cover multiple resolutions;
5. for cross-GPU Scope/LongLive matrix validation, use `VideoDiffusion/run_scope_longlive_vast_matrix.sh` so offer retries, teardown, and local artifact pullback are recorded.

## Public interface contract

Global selectors:

1. `VIDEO_MODEL=magi|krea|scope|longlive`
2. `ATTN_BACKEND=auto|sage|flash|sdpa`

Entry points:

1. setup: `VideoDiffusion/setup_video_runtime.sh`
2. launch: `VideoDiffusion/run_video_stream.sh`
3. publish: `VideoDiffusion/publish_r2_prebuild_model.sh`
4. restore: `VideoDiffusion/restore_r2_prebuild_model.sh`

Scope-specific controls:

1. setup: `VideoDiffusion/setup_scope.sh`
2. model download: `VideoDiffusion/download_scope_models.sh`
3. server launch: `VideoDiffusion/run_scope_server.sh`
4. pipeline load/status: `VideoDiffusion/load_scope_longlive.sh` and `VideoDiffusion/scope_pipeline.py`
5. EEG sink: `python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py --sink scope`

## Acceptance tests

1. No-cost selftests pass, including fake Scope OSC prompt delivery and the Scope/Vast matrix selftest.
2. Scope/LongLive cold setup reaches pipeline `loaded`.
3. Sweep or matrix run proves at least one tier at `>=24 fps`, first frame `<=2s`, synthetic EEG OSC updates, local MP4 pullback, `phase_report.json`, and artifact QA. Current best validated Scope/LongLive point is `352x576` on H200-class hardware.
4. For LongLive2 SP, a two-GPU offline smoke must show two active ranks, one output stream, per-GPU utilization, local MP4 pullback, and teardown proof before any live EEG work.
5. Steering latency run (20 EEG-triggered changes) reports acceptable prompt-to-visible-change `p50/p90`.
6. 30-minute soak has no OOM/restart.
7. Equal-latency quality A/B confirms selected tier/backend beats baseline.
8. Backend fallback test (`sage/flash` unavailable) still serves where applicable.

## Assumptions

1. One pod serves one realtime stream by default.
2. Vast pricing and availability are dynamic; re-query before provisioning.
3. Scope UI/WebRTC owns video display; EEG owns control through OSC.
4. FlashAttention for Krea is not mandatory; it is the preferred top-performance backend on B200.
