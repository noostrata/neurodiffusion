# Scope + LongLive Observations

_Last updated: 2026-05-20_

This is the empirical run log for Daydream Scope + LongLive realtime validation.
Keep this file synchronized with:

1. `docs/video-scope-longlive-streaming.md` for operator steps;
2. `docs/accelerate.md` for cache/build strategy;
3. `docs/cloudflare-r2.md` for tuple/cache artifacts;
4. `docs/budget-analysis.md` for pricing and spend assumptions;
5. `AGENTS.md` for canonical repo operating rules.

## 2026-05-20 autonomous matrix plumbing

Status: local plumbing complete; no paid matrix run launched in this pass.

Added systematic entry point:

```bash
bash VideoDiffusion/run_scope_longlive_vast_matrix.sh \
  --create-instance \
  --max-budget-usd 20.14 \
  --max-attempts 10 \
  --duration-s 30
```

No-paid readiness command:

```bash
bash VideoDiffusion/run_scope_longlive_vast_matrix.sh \
  --offline-plan \
  --plan-only \
  --max-budget-usd 20.14
```

Matrix contract:

1. No paid compute is created unless `--create-instance` is passed.
2. Each paid attempt gets a fresh offer scan and selected offer, so stale `no_such_ask` results become one recorded matrix row rather than the end of the experiment.
3. Each attempt delegates remote lifecycle, R2 restore, WebRTC capture, synthetic EEG, local pullback, and teardown to `VideoDiffusion/run_scope_longlive_vast_smoke.sh`.
4. Results aggregate into `matrix_report.json`, `matrix_report.csv`, and `matrix_report.md`.
5. The smoke runner now traps `INT` and `TERM` as well as normal exit, so timeout cancellation still runs cleanup.

Default search order:

| Tier | GPU regex | Max rate | Resolution policy |
| --- | --- | ---: | --- |
| `cheap_mid` | `RTX.?5090\|L40S\|RTX.?6000\|A6000` | `$2.50/h` | target then up/down |
| `hopper` | `H100\|H200\|GH200` | `$8.00/h` | target then up/down |
| `b200_known_good` | `B200` | `$8.00/h` | target then up/down |
| `rtx4090_lowres` | `RTX.?4090` | `$1.50/h` | low-res only |

Resolution policy:

1. target: `320x576`, the profile already proven realtime on B200;
2. upscale if target passes: `368x640`, then `480x832`;
3. downscale if target fails: `256x448`, then `192x320`;
4. `480x832` is the next native-scale LongLive target to prove, not an already validated realtime result.

## 2026-05-20 H200/4090 realtime matrix

Status: complete; local artifacts pulled; all paid instances destroyed.

Command:

```bash
bash VideoDiffusion/run_scope_longlive_vast_matrix.sh \
  --create-instance \
  --max-budget-usd 14.75 \
  --max-attempts 4 \
  --duration-s 30 \
  --per-attempt-fixed-cost-usd 1.00 \
  --scan-retries 2 \
  --scan-sleep-s 30
```

Run root:

```text
/Users/xenochain/Downloads/scope_longlive_vast_matrix_20260520T200307Z/
```

Matrix reports:

```text
/Users/xenochain/Downloads/scope_longlive_vast_matrix_20260520T200307Z/matrix_report.json
/Users/xenochain/Downloads/scope_longlive_vast_matrix_20260520T200307Z/matrix_report.csv
/Users/xenochain/Downloads/scope_longlive_vast_matrix_20260520T200307Z/matrix_report.md
```

Teardown and balance:

1. final `vastai show instances --raw` returned `[]`;
2. Vast credit moved from `$15.519453` before the run to `$11.424968` after the run;
3. invoice-observed spend for the four new instances was about `$4.10`;
4. the matrix report's spend estimate remains conservative because it adds a configurable fixed per-attempt overhead.

Results:

| Attempt | GPU | Resolution | Pass | FPS | First frame | Frames | Invoice cost | Local video |
| ---: | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| 1 | `H200` | `320x576` | yes | `25.376` | `1.338s` | `737` | `$1.681` | `/Users/xenochain/Downloads/scope_longlive_vast_matrix_20260520T200307Z/scope_longlive_vast_matrix_20260520T200307Z_01_hopper_320x576_webrtc_capture.mp4` |
| 2 | `H200` | `368x640` | no | `20.835` | `1.506s` | `600` | `$0.890` | `/Users/xenochain/Downloads/scope_longlive_vast_matrix_20260520T200307Z/scope_longlive_vast_matrix_20260520T200307Z_02_hopper_368x640_webrtc_capture.mp4` |
| 3 | `H200` | `480x832` | no | `12.171` | `1.793s` | `348` | `$0.624` | `/Users/xenochain/Downloads/scope_longlive_vast_matrix_20260520T200307Z/scope_longlive_vast_matrix_20260520T200307Z_03_hopper_480x832_webrtc_capture.mp4` |
| 4 | `RTX 4090` | `256x448` | no | `12.912` | `4.693s` | `333` | `$0.907` | `/Users/xenochain/Downloads/scope_longlive_vast_matrix_20260520T200307Z/scope_longlive_vast_matrix_20260520T200307Z_04_rtx4090_lowres_256x448_webrtc_capture.mp4` |

Telemetry:

| Attempt | Matrix elapsed | 30s benchmark elapsed | Setup/restore/load/pull overhead |
| ---: | ---: | ---: | ---: |
| 1 | `776.4s` | `30.4s` | `746.0s` |
| 2 | `575.0s` | `30.3s` | `544.7s` |
| 3 | `514.9s` | `30.4s` | `484.6s` |
| 4 | `585.4s` | `30.5s` | `554.9s` |

Visual inspection:

1. sampled `frame_000024.png` from all four attempts;
2. all samples showed coherent red/blue neon tunnel geometry;
3. the failures were throughput/latency failures, not blank output or obvious model-load corruption.

Conclusions:

1. `H200` is a valid realtime tier for the current `320x576` Scope/LongLive target.
2. `H200` did not hold realtime at `368x640` or `480x832` in this run.
3. `480x832` can load and generate, but it is about half realtime on the sampled H200 path.
4. `RTX 4090` is still not realtime even at `256x448`; it should not be a default Scope/LongLive realtime tier.
5. The main pipeline inefficiency is repeated cold restore per resolution. The next optimization is a same-instance multi-resolution sweep that restores once, then reloads LongLive at multiple resolutions before teardown.
6. Future smoke logs now include `[scope-vast-ts]` UTC phase markers so setup, restore, load, capture, pullback, and report timings are directly parseable.

Follow-up code-quality changes:

1. `VideoDiffusion/run_scope_longlive_vast_sweep.sh` is now the preferred same-instance edge-finding entry point. It creates one Vast instance, restores once, starts one Scope server, reloads LongLive at each requested resolution, then writes per-resolution `run_report.json` files plus aggregate `sweep_report.{json,md}`.
2. `VideoDiffusion/scope_run_report.py` now owns local report construction, phase parsing, ffprobe metadata, nonblank luma QA, and contact-sheet generation.
3. `VideoDiffusion/run_scope_longlive_vast_matrix.py` no longer includes `RTX 4090` in the default realtime tier list. `rtx4090_lowres` remains available only when explicitly requested.
4. Default upscale probes now include `336x592` and `352x576` before `368x640` and `480x832`, matching the observed H200 pixel-throughput ceiling.
5. The default matrix stops after the first failed upscale probe; pass `--continue-after-upscale-fail` for exhaustive probing.
6. The matrix budget guard can now preserve Vast credit with `--min-credit-reserve-usd` and require a successful credit query with `--require-credit-check`.
7. Paid matrix reports now include sanitized `invoice_report.json` matched by created instance ids when Vast exposes invoice rows.

Performance model:

| Resolution | Pixels | Observed FPS | Pixel throughput |
| --- | ---: | ---: | ---: |
| `320x576` | `184,320` | `25.376` | `4.68 MPix/s` |
| `368x640` | `235,520` | `20.835` | `4.91 MPix/s` |
| `480x832` | `399,360` | `12.171` | `4.86 MPix/s` |

Interpretation: the sampled H200 path is compute-bound around `4.8-4.9 MPix/s`. For `24 fps`, this implies an effective realtime ceiling around `200k px/frame`, so `320x576` is inside the current envelope, `336x592`/`352x576` are the right edge probes, and `368x640` is expected to miss unless runtime throughput improves.

## 2026-05-20 cheap-GPU automation prep

Status: local runner implemented; first cheap-GPU validation recorded below.

Added operator entry point:

```bash
bash VideoDiffusion/run_scope_longlive_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'RTX.?4090|RTX.?5090|L40S' \
  --max-dph 1.50 \
  --duration-s 30
```

The runner automates:

1. Scope offer query and deterministic selection;
2. optional paid Vast provisioning only behind `--create-instance`;
3. SSH readiness, repo sync, remote dependency bootstrap, and Scope checkout/patch;
4. R2 tuple restore into the Scope uv env and `VideoDiffusion/.cache/daydream-scope`;
5. `SCOPE_AUTO_LOAD=0` server start and explicit no-VACE LongLive load;
6. WebRTC MP4 capture while synthetic EEG drives Scope OSC updates;
7. local artifact pullback and `run_report.json`;
8. R2 secret cleanup and teardown for wrapper-created instances.

Acceptance encoded in `run_report.json`:

| Gate | Threshold |
| --- | ---: |
| frames received | `>0` |
| receive FPS | `>=24` |
| first frame latency | `<=2s` |
| synthetic EEG Scope updates | `>0` |
| local MP4 | exists and non-empty |

Implementation note:

1. The B200 tuple remains `scope_auto_py312_torch2.9.1_cu128_sm100`.
2. For cheap GPUs, the runner defaults `SCOPE_VAST_ALLOW_RUNTIME_GPU_MISMATCH=1` because Scope tuple reuse is environment/cache oriented.
3. If a cheap GPU rejects the restored tuple, rerun with `--download-fallback` to test deterministic host-local model download.

## 2026-05-20 RTX 4090 cheap smoke

Status: complete; failed realtime acceptance, passed generation/pullback/teardown.

Teardown result:

1. Vast instance `37167888` was destroyed by the runner.
2. Final `vastai show instances --raw` returned `[]`.
3. Local MP4, sampled frames, logs, and `run_report.json` were pulled before teardown.

Selected GPU:

| Field | Value |
| --- | --- |
| Vast offer id | `36866026` |
| Vast instance id | `37167888` |
| GPU | `RTX 4090 x1` |
| VRAM | `24564 MB` |
| Hourly rate observed after launch | `$0.8685185185185185/h` total |
| Location | `Hungary, HU` |
| CUDA max good | `13.0` |
| Runtime tag | `scope_auto_py312_torch2.9.1_cu128_sm100` |

Why this offer:

1. the cheapest 4090 scan result was `$0.401/h` but only reported `cuda_max_good=12.7`;
2. the Scope tuple is CUDA `12.8`, so the Scope query now requires `cuda_max_good>=12.8`;
3. no `RTX 5090`, `L40S`, `RTX 6000`, or `A6000` matches were available under the current Scope query at the time of scan.

Provisioning observation:

1. Vast created the instance and finished image load, but left it in a stopped/loading state.
2. A manual `vastai start instance 37167888 --raw` was needed for this run.
3. `scripts/vast/provision_video_instance.sh` now detects `Successfully loaded` + stopped state and requests start automatically.

Restore observation:

1. R2 model/cache restore succeeded and populated `VideoDiffusion/.cache/daydream-scope`.
2. The restored Scope uv venv was not fully portable on this fresh host because the uv-managed CPython interpreter was missing.
3. uv recreated the venv before server start, so this run did not get the desired fast env restore.
4. `VideoDiffusion/restore_r2_prebuild_model.sh` now installs/finds the recorded uv Python and repairs `.venv/bin/python*` links after extraction.

Performance result:

| Metric | Value |
| --- | ---: |
| WebRTC frame count | `322` |
| Receive FPS | `11.310` |
| First frame latency | `2.480s` |
| Output duration by ffprobe | `13.416667s` |
| Output resolution | `576x320` |
| Synthetic EEG records | `56` |
| Synthetic EEG state-change emits | `3` |

Acceptance:

| Gate | Result |
| --- | --- |
| frames received | pass |
| receive FPS `>=24` | fail |
| first frame latency `<=2s` | fail |
| synthetic EEG emitted Scope updates | pass |
| local MP4 exists | pass |
| overall | fail |

Local artifacts:

```text
/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T190833Z/run_report.json
/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T190833Z/webrtc_capture.mp4
/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T190833Z/frames/frame_000024.png
/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T190833Z_webrtc_capture.mp4
/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T190833Z_frame_000024.png
```

Visual inspection:

1. opened `/Users/xenochain/Downloads/scope_longlive_vast_smoke_20260520T190833Z/frames/frame_000024.png`;
2. frame showed coherent red/blue hexagonal neon tunnel geometry;
3. output quality was valid, but throughput was not realtime.

Conclusion:

1. `RTX 4090 24GB` is not enough for the current `320x576` LongLive realtime target.
2. B200 remains the known-good realtime tier for this exact profile.
3. The next cost pass should either test a currently available `RTX 5090`/`L40S`/H100-class offer, or intentionally lower resolution on 4090 and record the quality/performance tradeoff.

Follow-up lower-resolution attempt:

1. A `192x320` 4090 probe was prepared with the new `--height`/`--width` runner options.
2. The previously selected offer disappeared before launch with Vast `no_such_ask`.
3. A fresh `RTX 4090` / `RTX 5090` / `L40S` scan with `cuda_max_good>=12.8` returned `0` offers.
4. No second paid instance was created for the lower-resolution probe.
5. `scripts/vast/provision_video_instance.sh` now rejects failed create output before parsing an instance id, so this offer-race failure will fail fast next time.

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

1. use `VideoDiffusion/run_scope_longlive_vast_sweep.sh` on H200/B200 to probe the `~200k px/frame` edge (`320x576`, `336x592`, `352x576`, `368x640`);
2. test currently available `RTX 5090` or `L40S` offers when they satisfy the Scope query constraints;
3. keep `RTX 4090` as explicit protocol/quality-check hardware unless a much lower-resolution art mode becomes acceptable;
4. if a cheaper non-4090 tier holds `>=24 fps` at `320x576`, it can replace B200/H200 as the default art-loop GPU.

Recommended code/doc improvement:

1. republish the Scope tuple with a faster model-cache archive mode if R2 transfer/extract time dominates the next boot;
2. use `scope_run_report.py` outputs (`phase_report.json`, `artifact_qa.json`, contact sheets) as the telemetry contract for future paid runs;
3. decide whether to upstream the Scope text-mode WebRTC keepalive patch.
