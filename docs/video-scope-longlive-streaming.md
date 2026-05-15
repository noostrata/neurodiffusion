# Daydream Scope + LongLive Streaming

_Last updated: 2026-05-15_

This is the prepared no-live-run path for using Daydream Scope with the LongLive realtime video pipeline.
It is designed for the final OpenBCI EEG control target, but this document intentionally stops before any paid GPU launch or model download.

## Current status

Implemented local preparation:

1. model selector accepts `VIDEO_MODEL=scope` and `VIDEO_MODEL=longlive` as aliases for the Scope runtime;
2. Scope setup, model download, server launch, and pipeline-load scripts exist under `VideoDiffusion/`;
3. a stdlib Scope REST client can load/poll `/api/v1/pipeline/*`;
4. a stdlib OSC client can drive Scope runtime parameters such as `/scope/prompt`;
5. the EEG session runner has a `scope` sink for live neurofeedback control;
6. a fake Scope HTTP+OSC server is covered by the no-cost EEG selftest.

Not yet validated:

1. real Scope dependency build on a GPU host;
2. LongLive model download;
3. WebRTC video display on a remote instance;
4. real OpenBCI hardware input;
5. actual Scope/LongLive FPS or prompt-change latency on Vast.

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

# Download LongLive models after setup.
bash VideoDiffusion/download_scope_models.sh

# Start the Scope server.
VIDEO_MODEL=scope bash VideoDiffusion/run_video_stream.sh

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
DAYDREAM_SCOPE_MODELS_DIR=VideoDiffusion/.cache/daydream-scope/models
DAYDREAM_SCOPE_LOGS_DIR=VideoDiffusion/.cache/daydream-scope/logs
DAYDREAM_SCOPE_PLUGINS_DIR=VideoDiffusion/.cache/daydream-scope/plugins
```

Use `SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh` when you only want to clone Scope and write the ignored runtime env file without installing heavy dependencies.

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
The EEG process does not try to own WebRTC; it sends control updates over OSC while the Scope UI or a browser WebRTC client receives video.

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

For first live Scope/LongLive validation, prefer cheap `RTX 4090 24GB`, `RTX 5090 32GB`, or `L40S 48GB`-class offers before H100/H200.
Do not create an instance unless the user explicitly authorizes a paid run.

## First future live-run checklist

1. Query Scope offers and choose a cost target.
2. Provision one Vast instance with port `8000` exposed.
3. Sync the repo to the instance.
4. Run `VIDEO_MODEL=scope bash VideoDiffusion/setup_video_runtime.sh`.
5. Run `bash VideoDiffusion/download_scope_models.sh`.
6. Start `VIDEO_MODEL=scope bash VideoDiffusion/run_video_stream.sh`.
7. Open Scope UI/WebRTC output on port `8000`.
8. Run `bash VideoDiffusion/load_scope_longlive.sh`.
9. Run mock EEG into `--sink scope`.
10. Record latency notes and logs.
11. Tear down the instance and verify `vastai show instances --raw`.

## Sources

- Daydream Scope quickstart: https://docs.daydream.live/scope/getting-started/quickstart
- Scope API load pipeline: https://docs.daydream.live/scope/reference/api/load-pipeline
- Scope API parameters: https://docs.daydream.live/scope/reference/api/parameters
- Scope OSC guide: https://docs.daydream.live/scope/guides/osc
- Scope LongLive pipeline: https://docs.daydream.live/scope/reference/pipelines/longlive
- Scope system requirements: https://docs.daydream.live/scope/reference/system-requirements
- LongLive repo: https://github.com/NVlabs/LongLive
