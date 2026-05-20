# Daydream Scope + LongLive Streaming

_Last updated: 2026-05-15_

This is the operator path for using Daydream Scope with the LongLive realtime video pipeline.
It is designed for the final OpenBCI EEG control target: Scope owns WebRTC/video, while the EEG process owns OSC control updates.
For one-stream multi-GPU LongLive2 work, use `docs/video-longlive2-sp-streaming.md`; that path is not a Scope REST pipeline today.

## Current status

Validated:

1. model selector accepts `VIDEO_MODEL=scope` and `VIDEO_MODEL=longlive` as aliases for the Scope runtime;
2. Scope setup, model download, server launch, and pipeline-load scripts exist under `VideoDiffusion/`;
3. a stdlib Scope REST client can load/poll `/api/v1/pipeline/*`;
4. a stdlib OSC client can drive Scope runtime parameters such as `/scope/prompt`;
5. the EEG session runner has a `scope` sink for live neurofeedback control;
6. a fake Scope HTTP+OSC server is covered by the no-cost EEG selftest;
7. a B200 Vast run sustained realtime WebRTC receive with synthetic EEG steering.

Still not validated:

1. real OpenBCI hardware input;
2. cheaper `RTX 5090` / `L40S` Scope throughput;
3. long-duration gallery/session stability beyond the 90s synthetic EEG run.
4. LongLive2 sequence-parallel inference; that is a separate direct-backend plan, not a Scope LongLive result.

Latest empirical reference:

- `docs/video-scope-longlive-observations.md`
- runtime tuple: `scope_auto_py312_torch2.9.1_cu128_sm100`
- recorded local video: `/Users/xenochain/Downloads/scope_b200_20260515T194707Z_webrtc_recording_after_text_patch.mp4`
- latest cheap-GPU result: `RTX 4090 x1` generated coherent output but failed realtime at `11.310 fps` for `320x576`.

## Why Scope + LongLive

Scope is the control surface and serving layer.
LongLive is the first realtime backend because it is a Wan2.1 1.3B autoregressive pipeline with smoother prompt switching and long-session continuity.
Scope documents LongLive as a built-in pipeline with about `20GB` estimated VRAM and recommends a `24GB` GPU minimum.

This gives a cheaper first realtime target than Krea Realtime 14B.
Krea remains useful later for quality, but LongLive is the practical path for EEG-driven live art.

## Runtime scripts

Repository entry points:

```bash
cd /Users/xenochain/Code/neurodiffusion

# Clone/build Scope locally on a GPU host.
VIDEO_MODEL=scope bash VideoDiffusion/setup_video_runtime.sh

# Or call the Scope setup directly.
bash VideoDiffusion/setup_scope.sh

# Download LongLive models after setup. For LongLive this uses the repo
# deterministic downloader because Scope's upstream downloader returned no
# artifacts in the 2026-05-15 B200 run.
bash VideoDiffusion/download_scope_models.sh

# Start the Scope server without auto-loading LongLive.
SCOPE_AUTO_LOAD=0 VIDEO_MODEL=scope bash VideoDiffusion/run_video_stream.sh

# Request LongLive pipeline load after the server is reachable.
bash VideoDiffusion/load_scope_longlive.sh
```

No local paid work is performed by these scripts.
They only operate on the current machine or the already-provisioned host where they are run.

Important environment variables:

```bash
SCOPE_REPO_REF=main
SCOPE_SRC_DIR=VideoDiffusion/.vendors/daydream-scope
SCOPE_PIPELINE=longlive
SCOPE_PORT=8000
SCOPE_AUTO_LOAD=0
SCOPE_APPLY_PATCHES=1
DAYDREAM_SCOPE_MODELS_DIR=VideoDiffusion/.cache/daydream-scope/models
DAYDREAM_SCOPE_LOGS_DIR=VideoDiffusion/.cache/daydream-scope/logs
DAYDREAM_SCOPE_PLUGINS_DIR=VideoDiffusion/.cache/daydream-scope/plugins
```

Use `SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh` when you only want to clone Scope and write the ignored runtime env file without installing heavy dependencies.
Use `SCOPE_INCLUDE_VACE=1 bash VideoDiffusion/download_scope_models.sh` only when you intend to load VACE; the validated realtime text path keeps VACE disabled.

Scope patches:

1. `setup_scope.sh` applies `VideoDiffusion/patches/daydream-scope/*.patch` by default.
2. The current patch keeps the WebRTC video track alive for text-to-video sessions with no incoming browser video source.
3. Set `SCOPE_APPLY_PATCHES=0` only when intentionally testing unmodified upstream Scope.

## R2 Fast Boot

The reusable Scope/LongLive prebuild is a tuple cache, not a warm model process.
It stores the Scope uv env and the LongLive/Wan model cache in R2.
It cannot store a loaded GPU model; a fresh instance still needs Scope server start and explicit pipeline load.

Validated tuple:

```text
scope_auto_py312_torch2.9.1_cu128_sm100
```

Fast restore on a fresh Vast host:

```bash
cd /workspace/neurodiffusion
SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh
bash VideoDiffusion/restore_r2_prebuild_model.sh \
  --model scope \
  --mode tuple \
  --runtime-tag scope_auto_py312_torch2.9.1_cu128_sm100 \
  --apply-weights-target VideoDiffusion/.cache/daydream-scope
SCOPE_AUTO_LOAD=0 bash VideoDiffusion/run_scope_server.sh --host 0.0.0.0 --port 8000 -N
SCOPE_VACE_ENABLED=false bash VideoDiffusion/load_scope_longlive.sh
```

For the next tuple publish, prefer a faster archive setting for model cache:

```bash
bash VideoDiffusion/publish_r2_prebuild_model.sh \
  --model scope \
  --runtime-tag scope_auto_py312_torch2.9.1_cu128_sm100 \
  --include-weights \
  --env-compression zstd \
  --weights-compression none
```

Use `--env-compression gzip` if `zstd` is not installed.
Plain tar for weights is intentional: the large model shards are already compressed and gzip adds boot-pipeline wall time for little size gain.

## Scope API contract

Scope is controlled through two surfaces:

1. REST for pipeline lifecycle:
   - `POST /api/v1/pipeline/load`
   - `GET /api/v1/pipeline/status`
2. OSC for low-latency runtime parameter updates:
   - `/scope/prompt`
   - `/scope/noise_scale`
   - `/scope/manage_cache`
   - `/scope/reset_cache`
   - `/scope/transition_steps`
   - `/scope/interpolation_method`

The repo client lives at:

```bash
VideoDiffusion/eeg_control/scope_client.py
VideoDiffusion/scope_pipeline.py
```

Manual status/load examples:

```bash
python3 VideoDiffusion/scope_pipeline.py \
  --base-url http://127.0.0.1:8000 \
  status

python3 VideoDiffusion/scope_pipeline.py \
  --base-url http://127.0.0.1:8000 \
  load-longlive \
  --height 320 \
  --width 576 \
  --seed 42 \
  --vae-type wan \
  --vace-enabled false \
  --wait
```

Video display remains Scope/WebRTC-native.
The EEG process does not try to own WebRTC; it sends control updates over OSC while the Scope UI or a browser/WebRTC client receives video.

Headless WebRTC benchmark/capture:

```bash
python3 VideoDiffusion/scope_webrtc_benchmark.py \
  --base-url http://127.0.0.1:8000 \
  --pipeline-id longlive \
  --duration-s 30 \
  --output-video VideoDiffusion/.tmp/scope_webrtc_capture.mp4 \
  --frames-dir VideoDiffusion/.tmp/scope_frames
```

This client is for automated validation and local artifact capture.
It is not the EEG control loop.

## EEG control path

Use the systematic runner:

```bash
python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board mock \
  --mock-scenario alternating \
  --policy balancer \
  --sink stdout \
  --sink jsonl \
  --sink scope \
  --scope-osc-host 127.0.0.1 \
  --scope-osc-port 8000 \
  --scope-transition-steps 6 \
  --duration-s 60
```

Policy semantics are unchanged:

1. `balancer`: low arousal/alpha dominance pushes frantic visuals; high arousal/beta dominance pushes relaxing visuals.
2. `reward`: low arousal is rewarded with calmer visuals.
3. `mirror`: visuals mirror the estimated state.
4. `inversion`: state mapping is intentionally surreal/contradictory.

The Scope sink sends stable emitted commands only.
The existing cooldown and consecutive-window gate still prevents EEG noise from thrashing prompts.

## Fake local test

No GPU, Scope checkout, model weights, or OpenBCI hardware is needed for this:

```bash
python3 VideoDiffusion/eeg_control/fake_scope_server.py \
  --host 127.0.0.1 \
  --port 8000

python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board mock \
  --mock-scenario alternating \
  --policy balancer \
  --sink stdout \
  --sink scope \
  --scope-osc-host 127.0.0.1 \
  --scope-osc-port 8000 \
  --duration-s 20
```

Use `--http-port` and `--osc-port` instead of `--port` when testing split REST and OSC bindings.

The integrated selftest covers the same contract:

```bash
python3 VideoDiffusion/eeg_control/selftest.py
```

Validated locally on 2026-05-15:

1. `VideoDiffusion/load_scope_longlive.sh` successfully loaded fake `longlive` against `fake_scope_server.py`.
2. `run_neurofeedback_session.py --sink scope` sent the expected OSC sequence:
   - `/scope/manage_cache true`
   - `/scope/noise_scale <float>`
   - `/scope/transition_steps 6`
   - `/scope/interpolation_method linear`
   - `/scope/prompt <policy prompt>`
3. No real Scope server, model weights, GPU, OpenBCI board, or paid instance was used.

## Vast preparation

Scope/LongLive offer discovery is no-spend:

```bash
python3 scripts/vast/query_video_offers.py \
  --model scope \
  --out-json VideoDiffusion/.tmp/vast_video_offer_scan_scope.json \
  --out-csv VideoDiffusion/.tmp/vast_video_offer_scan_scope.csv

python3 scripts/vast/select_video_offer.py \
  --scan-json VideoDiffusion/.tmp/vast_video_offer_scan_scope.json \
  --selection-goal cost \
  --print-env
```

For follow-up Scope/LongLive realtime validation, prefer `RTX 5090 32GB`, `L40S 48GB`, H100/H200, or B200-class offers.
`RTX 4090 24GB` is now an explicit protocol/quality-check tier only, because it failed realtime at both `320x576` and `256x448`.
Do not create an instance unless the user explicitly authorizes a paid run.
The default Scope offer query requires `cuda_max_good>=12.8` because the current tuple is CUDA `12.8`.

## Same-instance Vast sweep

Preferred edge-finding entry point after choosing a GPU tier:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scope_longlive_vast_sweep.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --max-dph 8.00 \
  --max-gpu-count 1 \
  --duration-s 30 \
  --resolutions 320x576,336x592,352x576,368x640
```

The sweep runner is the cost/time optimization path:

1. creates one paid instance;
2. selects one-GPU offers by default; use `--max-gpu-count 0` only when intentionally allowing multi-GPU listings;
3. restores the Scope tuple once;
4. starts one Scope server;
5. reloads LongLive at each requested resolution;
6. runs WebRTC capture and synthetic EEG for every resolution;
7. pulls all artifacts locally before teardown;
8. writes per-resolution `run_report.json`, `artifact_qa.json`, and `contact_sheet.jpg`;
9. writes aggregate `sweep_report.json` and `sweep_report.md`.

Use this when the question is the maximum realtime resolution on one selected GPU.

## Systematic Vast matrix

Preferred cross-GPU paid validation entry point:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scope_longlive_vast_matrix.sh \
  --create-instance \
  --max-budget-usd 20.14 \
  --max-attempts 10 \
  --duration-s 30
```

No-paid planning and parser check:

```bash
bash VideoDiffusion/run_scope_longlive_vast_matrix.sh \
  --offline-plan \
  --plan-only \
  --max-budget-usd 20.14
```

Default matrix behavior:

1. Safe default is no paid compute; `--create-instance` is required for paid attempts.
2. Each paid attempt re-queries/selects a fresh Vast offer, then delegates to `VideoDiffusion/run_scope_longlive_vast_smoke.sh`.
3. Default tier order is `cheap_mid` (`RTX 5090`, `L40S`, `RTX 6000`, `A6000`), `hopper` (`H100`, `H200`, `GH200`), then `b200_known_good`.
4. `rtx4090_lowres` remains available only when passed explicitly with `--tiers rtx4090_lowres`.
5. Full tiers test `320x576`; if that passes, they test edge/upscale probes `336x592`, `352x576`, `368x640`, then `480x832`; if it fails, they test `256x448` and `192x320`.
6. Tier rate ceilings are `$2.50/h` for cheap-mid, `$8.00/h` for Hopper, `$8.00/h` for B200, and `$1.50/h` for 4090 low-res.
7. Default budget guard is conservative: `--budget-estimate-s 1800` per planned paid attempt, `--max-attempt-wall-clock-s 2400`, and `--max-wall-clock-s 14400`.
8. `--per-attempt-fixed-cost-usd` defaults to `1.00` so the budget guard accounts for transfer/storage overhead in addition to GPU time.
9. `--min-credit-reserve-usd` can keep a Vast credit reserve before paid creates; add `--require-credit-check` when the run must stop if credit cannot be queried.
10. `--max-gpu-count` defaults to `1` for Scope/LongLive so a one-stream run does not accidentally pick multi-GPU offers.
11. By default, the matrix stops larger upscale probes after the first failed upscale; add `--continue-after-upscale-fail` for exhaustive probing.
12. Output is written under `/Users/xenochain/Downloads/<matrix_run_id>/matrix_report.{json,csv,md}` plus `invoice_report.json` and per-attempt MP4/frame/log artifacts.
13. The matrix does not keep instances by default; use `--keep-instance` only for intentional interactive debugging.
14. Smoke reports include `phase_report.json`, `artifact_qa.json`, contact sheets, and `[scope-vast-ts]` UTC phase markers for setup/restore/load/capture/pullback telemetry.

Use this runner when the goal is to keep going across GPUs/resolutions instead of stopping after one failed offer.

## One-command Vast smoke

Single-attempt paid validation entry point:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scope_longlive_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --max-dph 8.00 \
  --max-gpu-count 1 \
  --duration-s 30
```

Lower-resolution probe when testing whether a cheap GPU has any realtime operating point:

```bash
bash VideoDiffusion/run_scope_longlive_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'RTX.?4090' \
  --max-dph 1.50 \
  --height 192 \
  --width 320 \
  --duration-s 30
```

Safe behavior:

1. Without `--create-instance`, the script requires `VAST_INSTANCE_ID` and will not create paid compute.
2. With `--create-instance`, it queries/selects an offer, provisions a Vast SSH instance, and destroys that instance on exit unless `--keep-instance` is passed.
3. The R2 secret is copied to the instance only for tuple restore and removed during cleanup.
4. Output video, sampled frames, logs, `run_report.json`, `phase_report.json`, `artifact_qa.json`, and `contact_sheet.jpg` are pulled/written under `/Users/xenochain/Downloads/<run_id>/`.
5. A flat video copy is also written to `/Users/xenochain/Downloads/<run_id>_webrtc_capture.mp4`.

Acceptance gate:

1. WebRTC receives frames.
2. Receive FPS is `>=24`.
3. First frame latency after benchmark start is `<=2s`.
4. Synthetic EEG sends at least one Scope OSC update.
5. Local MP4 exists and is non-empty.

For B200-published tuple reuse on cheaper GPUs, the script defaults `SCOPE_VAST_ALLOW_RUNTIME_GPU_MISMATCH=1`.
That is intentional for Scope because the tuple mostly stores a uv env and model cache, not MAGI-style arch-specific custom kernels.
If a cheaper card fails restore/runtime, rerun with `--download-fallback` to rebuild the model cache path on that host.

## Validated Vast live-run checklist

1. Query Scope offers and choose a cost target.
2. Provision one Vast instance with port `8000` exposed.
3. Sync the repo to the instance.
4. Prefer `bash VideoDiffusion/run_scope_longlive_vast_sweep.sh --create-instance` for same-GPU resolution testing, or `bash VideoDiffusion/run_scope_longlive_vast_smoke.sh --create-instance` for one validation point.
5. If running manually, run `SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh` and restore the R2 tuple with `--apply-weights-target VideoDiffusion/.cache/daydream-scope`, or run full `VIDEO_MODEL=scope bash VideoDiffusion/setup_video_runtime.sh` when rebuilding from scratch.
6. Run `bash VideoDiffusion/download_scope_models.sh` only if the R2 model cache was not restored or intentionally needs refresh.
7. Start `SCOPE_AUTO_LOAD=0 VIDEO_MODEL=scope bash VideoDiffusion/run_video_stream.sh`.
8. Run `SCOPE_VACE_ENABLED=false bash VideoDiffusion/load_scope_longlive.sh`.
9. Run `VideoDiffusion/scope_webrtc_benchmark.py` or open Scope UI/WebRTC output on port `8000`.
10. Run mock EEG into `--sink scope`.
11. Record latency notes, output video, sampled frames, and logs.
12. Pull local video/log artifacts.
13. Tear down the instance and verify `vastai show instances --raw`.

## Latest B200 Results

Observed on 2026-05-15:

1. LongLive loaded at `320x576`, no VACE, in about `19s` after server start.
2. 90s WebRTC receive: `2203` frames, `24.868 fps`, first frame `1.507s`.
3. 30s recorded WebRTC capture: `743` frames, `25.040 fps`, first frame `0.579s`.
4. Synthetic EEG `balancer` policy sent Scope OSC updates successfully during generation.
5. Local MP4: `/Users/xenochain/Downloads/scope_b200_20260515T194707Z_webrtc_recording_after_text_patch.mp4`.
6. R2 tuple: `scope_auto_py312_torch2.9.1_cu128_sm100`.
7. Current fresh-instance lower bound after tuple restore is still server start plus load: about `7s + 19s` in the B200 run, before WebRTC first-frame latency.

## Latest RTX 4090 Result

Observed on 2026-05-20:

1. `RTX 4090 x1` at `320x576` generated coherent neon tunnel output.
2. WebRTC receive: `322` frames, `11.310 fps`, first frame `2.480s`.
3. Synthetic EEG emitted `3` state changes during the run.
4. Local MP4: `/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T190833Z_webrtc_capture.mp4`.
5. Local frame: `/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T190833Z_frame_000024.png`.
6. Result: fail for realtime at `320x576`; keep 4090 only for protocol/quality checks or a future lower-resolution experiment.

## Latest H200 Matrix Result

Observed on 2026-05-20:

1. `H200` passed `320x576`: `737` frames, `25.376 fps`, first frame `1.338s`.
2. `H200` failed `368x640`: `600` frames, `20.835 fps`, first frame `1.506s`.
3. `H200` failed `480x832`: `348` frames, `12.171 fps`, first frame `1.793s`.
4. `RTX 4090` failed `256x448`: `333` frames, `12.912 fps`, first frame `4.693s`.
5. All runs pulled local videos and sampled coherent frames.
6. Final active Vast instances: `[]`.
7. H200 throughput was about `4.8-4.9 MPix/s`, so current `24 fps` probes should target `<=200k px/frame` before display upscaling.

## Latest H200 Edge Sweep Result

Observed on 2026-05-20:

1. Same-instance sweep run root: `/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T211512Z/`.
2. `320x576` passed: `748` frames, `25.768 fps`, first frame `1.384s`.
3. `336x592` passed: `730` frames, `24.757 fps`, first frame `0.856s`.
4. `352x576` passed: `736` frames, `24.835 fps`, first frame `0.721s`.
5. `368x640` failed FPS: `660` frames, `22.175 fps`, first frame `0.749s`.
6. Best validated realtime point is now `352x576`.
7. The run selected `H200 x2`; selector defaults now enforce `--max-gpu-count 1` for future one-stream Scope sweeps.

## Sources

- Daydream Scope quickstart: https://docs.daydream.live/scope/getting-started/quickstart
- Scope API load pipeline: https://docs.daydream.live/scope/reference/api/load-pipeline
- Scope API parameters: https://docs.daydream.live/scope/reference/api/parameters
- Scope OSC guide: https://docs.daydream.live/scope/guides/osc
- Scope LongLive pipeline: https://docs.daydream.live/scope/reference/pipelines/longlive
- Scope system requirements: https://docs.daydream.live/scope/reference/system-requirements
- LongLive repo: https://github.com/NVlabs/LongLive
