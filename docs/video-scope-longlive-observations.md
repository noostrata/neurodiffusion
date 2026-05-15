# Scope + LongLive Observations

_Last updated: 2026-05-15_

This is the empirical run log for Daydream Scope + LongLive realtime validation.
Keep this file synchronized with:

1. `docs/video-scope-longlive-streaming.md` for operator steps;
2. `docs/accelerate.md` for cache/build strategy;
3. `docs/cloudflare-r2.md` for tuple/cache artifacts;
4. `docs/budget-analysis.md` for pricing and spend assumptions;
5. `AGENTS.md` for canonical repo operating rules.

## 2026-05-15 B200 realtime validation

Status: complete.

Goal:

1. validate real Scope + LongLive generation on a Vast GPU;
2. drive Scope with synthetic EEG through the repo `scope` sink;
3. measure whether output is realtime enough for live neurofeedback;
4. publish reusable Scope env/model cache artifacts to R2;
5. pull video/log artifacts to the local machine;
6. tear down the paid instance before handoff.

Teardown result:

1. Vast instance `36839023` was destroyed.
2. Final `vastai show instances --raw` returned `[]`.
3. Temporary R2 env file on the instance was removed before teardown.

## Instance

Budget state before launch:

1. Vast credit from CLI before launch: `$10.78216606791537`.
2. User later reported current Vast balance around `$20.14` during the run.
3. Active instances before launch: `[]`.

Selected GPU:

| Field | Value |
| --- | --- |
| Vast offer id | `36083201` |
| Vast instance id | `36839023` |
| GPU | `B200 x1` |
| VRAM | `183359 MB` |
| Hourly rate | `$3.9947916666666656/h` total |
| Location | `Oregon, US` |
| CUDA max good | `13.0` |
| Disk bandwidth | `40755.2 MB/s` |
| Network down/up | `22735.5 / 3310.5 Mbps` |
| Alive window | about `56.8 min` |
| Approx compute spend | about `$3.78` |

Reason for starting on B200:

1. realtime was the primary constraint;
2. B200 was cheaper than the sampled H100 offer while giving much more headroom;
3. large VRAM/IO reduced ambiguity between model bugs and resource pressure;
4. the run could publish a true Blackwell/SM100 tuple instead of reusing the A100 tuple.

Launch command shape:

```bash
VAST_OFFER_ID=36083201 \
VAST_DISK_GB=220 \
VAST_ENV='-p 8000:8000 -p 8000:8000/udp' \
bash scripts/vast/provision_video_instance.sh
```

## Bootstrap

Remote environment:

| Component | Value |
| --- | --- |
| Base image | `pytorch/pytorch:2.7.1-cuda12.8-cudnn9-devel` |
| GPU driver | `580.126.09` |
| Python | `3.11.13` system, Scope uv venv `3.12` |
| Node/npm | Node `22.22.2`, npm `10.9.7` |
| uv | `0.11.14` |
| Scope commit | `2aced4ded3513a76cd35f0dbfb42fbfbf5e98ab0` |

Scope build result:

1. `uv run build` succeeded.
2. frontend build succeeded.
3. npm audit reported vulnerabilities, but build and runtime were not blocked.

## Model Cache

Scope's upstream `uv run download_models --pipeline longlive` returned:

```text
WARNING - No artifacts defined for pipeline: longlive
```

This left the server unable to find `Wan2.1-T2V-1.3B/config.json`.
The workaround was a deterministic Hugging Face cache population from the artifact paths declared in Scope's LongLive schema.

Downloaded no-VACE cache:

| Repo cache dir | Files | Size |
| --- | ---: | ---: |
| `Wan2.1-T2V-1.3B` | `19` | `0.529 GB` |
| `WanVideo_comfy` | `7` | `6.731 GB` |
| `LongLive-1.3B` | `10` | `8.476 GB` |
| `Autoencoders` | `13` | `0.100 GB` |

Repo fix:

1. `VideoDiffusion/download_scope_longlive_models.py` now performs this deterministic download.
2. `VideoDiffusion/download_scope_models.sh` dispatches to it for `SCOPE_PIPELINE=longlive`.
3. `SCOPE_INCLUDE_VACE=1` can include the VACE module; default remains no-VACE for fast text-mode realtime tests.

## Runtime Fixes

Two Scope/WebRTC issues were exposed and fixed in repo-managed wrappers/patches.

### WebRTC offer requires pipeline ids

The first headless WebRTC benchmark connected but Scope logged:

```text
No pipeline IDs provided, cannot start
```

`VideoDiffusion/scope_webrtc_benchmark.py` now sends:

```json
{"pipeline_ids": ["longlive"]}
```

inside `initialParameters`.

### Scope text-mode track keepalive

After adding `pipeline_ids`, Scope started the frame processor but emitted no frames before timeout.
The direct offline pipeline smoke proved the model itself was healthy.
The actual issue was Scope's server-side WebRTC track receive loop: text-to-video has no incoming browser/video source, but the server track still needs to keep polling the local output queue.

Repo fix:

1. `VideoDiffusion/patches/daydream-scope/0001-webrtc-keep-text-mode-video-track-alive.patch`
2. `VideoDiffusion/setup_scope.sh` now applies repo-maintained Scope patches after checkout.

### Avoid unwanted VACE auto-load

Restarting Scope with `PIPELINE=longlive` triggered Scope's default VACE-enabled auto-load, which failed because this fast path intentionally did not download VACE weights.

Repo fix:

1. `VideoDiffusion/run_scope_server.sh` supports `SCOPE_AUTO_LOAD=0`.
2. The validated server start path is now: start Scope with auto-load disabled, then call `VideoDiffusion/load_scope_longlive.sh` with `SCOPE_VACE_ENABLED=false`.

## Performance Results

Validated load:

```bash
SCOPE_AUTO_LOAD=0 SCOPE_PORT=8000 \
  bash VideoDiffusion/run_scope_server.sh --host 0.0.0.0 --port 8000 -N

SCOPE_PORT=8000 \
SCOPE_HEIGHT=320 \
SCOPE_WIDTH=576 \
SCOPE_VACE_ENABLED=false \
  bash VideoDiffusion/load_scope_longlive.sh
```

Server and load timing:

| Step | Observed time |
| --- | ---: |
| Scope server ready after restart | `7s` |
| explicit no-VACE LongLive load | about `19s` |
| GPU memory after load | about `16.3 GB` |

Offline one-chunk smoke:

| Metric | Value |
| --- | ---: |
| Output | `9` frames, `576x320` |
| Pipeline load inside standalone process | `19.864s` |
| First chunk latency | `1.176s` |
| Chunk throughput | `7.651 fps` |
| Output video | `/Users/xenochain/Downloads/scope_b200_20260515T194707Z_offline_longlive_smoke.mp4` |

Realtime WebRTC + synthetic EEG validation:

| Metric | 90s run | 30s recorded run |
| --- | ---: | ---: |
| Frame count | `2203` | `743` |
| Receive FPS | `24.868` | `25.040` |
| First frame latency | `1.507s` | `0.579s` |
| Track error | `null` | `null` |
| Synthetic EEG exit code | `0` | `0` |

Recorded video:

| Field | Value |
| --- | --- |
| Local MP4 | `/Users/xenochain/Downloads/scope_b200_20260515T194707Z_webrtc_recording_after_text_patch.mp4` |
| Duration | `30.959s` |
| Frames | `743` |
| Resolution | `576x320` |
| Nominal FPS | `24` |
| Size | `10517629 bytes` |

Visual inspection:

1. pulled sampled frames to local `VideoDiffusion/.tmp/scope_b200_20260515T194707Z_remote/`;
2. copied representative frame to `/Users/xenochain/Downloads/scope_b200_20260515T194707Z_frame_000180.png`;
3. opened frames `000030`, `000180`, and `000360`;
4. frames were coherent neon tunnel geometry with visible color/shape changes and no blank/noisy/static collapse.

## R2 Tuple

Published and metadata-verified:

| Field | Value |
| --- | --- |
| Runtime tag | `scope_auto_py312_torch2.9.1_cu128_sm100` |
| Prefix | `neurodiffusion` |
| GPU tuple | B200 / SM100 |
| Env archive | `4484945914 bytes` |
| Weights archive | `13718035301 bytes` |
| Metadata verify | `manifest.json` + tuple metadata fetched from R2 |
| Verified profiles | `scope_longlive_b200_webrtc_synthetic_eeg`, `scope_longlive_b200_offline_smoke`, `scope_longlive_b200_text_webrtc_patch` |

Important caveats:

1. The Scope uv venv does not include `pip`; future publish code now uses `uv pip freeze` when `pip` is unavailable.
2. The tuple restores env/cache, but a fresh host still needs the Scope source checkout at `VideoDiffusion/.vendors/daydream-scope`; `setup_scope.sh` applies the repo patch after clone.
3. R2 cannot persist a live GPU-resident loaded model. The reusable fast path is source checkout/patch, tuple restore, server start, and explicit LongLive load.
4. This tuple was published as gzip. Future Scope publishes can now use `--weights-compression none` or `--weights-compression zstd` to avoid wasting time gzipping already-compressed model files.

## Local Artifacts

Pulled local run bundle:

```text
VideoDiffusion/.tmp/scope_b200_20260515T194707Z_remote/
```

User-facing artifacts:

```text
/Users/xenochain/Downloads/scope_b200_20260515T194707Z_webrtc_recording_after_text_patch.mp4
/Users/xenochain/Downloads/scope_b200_20260515T194707Z_frame_000180.png
/Users/xenochain/Downloads/scope_b200_20260515T194707Z_offline_longlive_smoke.mp4
```

Key logs:

```text
VideoDiffusion/.tmp/scope_b200_20260515T194707Z_remote/manual_model_download.log
VideoDiffusion/.tmp/scope_b200_20260515T194707Z_remote/load_longlive_after_patch_autoload0.log
VideoDiffusion/.tmp/scope_b200_20260515T194707Z_remote/webrtc_benchmark_after_text_patch.json
VideoDiffusion/.tmp/scope_b200_20260515T194707Z_remote/webrtc_recording_benchmark.json
VideoDiffusion/.tmp/scope_b200_20260515T194707Z_remote/publish_scope_r2_prebuild.log
VideoDiffusion/.tmp/scope_b200_20260515T194707Z_remote/r2_verify_metadata_files.txt
```

## Next Optimization

Recommended next empirical pass:

1. test the same patched Scope tuple on cheaper `RTX 4090`, `RTX 5090`, or `L40S` Vast offers;
2. measure whether they still hold `>=24 fps` at `320x576`;
3. if yes, B200 is unnecessary for the art loop and should be reserved for Krea or higher resolution;
4. if no, keep B200/H100-class for performance and use cheaper GPUs only for protocol checks.

Recommended code/doc improvement:

1. republish the Scope tuple with a faster model-cache archive mode if R2 transfer/extract time dominates the next boot;
2. add a one-command Scope Vast smoke that performs restore, server start, load, WebRTC capture, synthetic EEG, pullback, and teardown;
3. decide whether to upstream the Scope text-mode WebRTC keepalive patch.
