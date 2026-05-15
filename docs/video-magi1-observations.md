# MAGI-1 Observations (Master Reference)

_Last updated: 2026-05-14_

## 1) Purpose and scope

This document is the master empirical reference for MAGI-1 operations in this repository.
It records what was observed in real runs, what worked, what failed, and how to tune the system.

Use this together with:

- `docs/video-magi1-streaming.md` (canonical workflow)
- `docs/video-magi1-scaling-testing.md` (test protocol)

## 2) Model behavior truths

1. MAGI-1 generation is chunk autoregressive with fixed **24-frame chunks**.
2. Prompt changes are applied at chunk boundaries, not inside a chunk.
3. In `realtime_magi_stream.py`, prompt updates are applied to future chunk conditioning via `_apply_prompt_from(start_chunk_idx=chunk_idx+1, ...)`.
4. Chunk-boundary behavior is expected and is not a bug.

## 3) Runtime and infrastructure observations

1. Prime availability is volatile and can change between consecutive queries.
2. Region and SKU availability may disappear temporarily; selection must be done at runtime.
3. Price drift can be large even within one day:
   - sampled 2026-02-16 values showed `eu_north` `H100_80GB` at `gpu-count=2` listed at `$4.58/h`,
   - while `gpu-count=8` for the same region/SKU had no listing in the same sampling pass.
4. Current Prime CLI/API workflow does not expose a stable numeric credits endpoint in command output used by this repo.
5. Budget control is enforced by time-based spend caps:
   - `max_runtime_sec = floor((budget_usd * 0.90 / hourly_rate_usd) * 3600)`
6. Explicit spend stop command remains:
   - `prime pods terminate <POD_ID> --yes`
7. Live lifecycle testing on 2026-02-16 validated that pod provisioning and teardown are stable through:
   - `scripts/prime/provision_magi_pod.sh`
   - `scripts/prime/terminate_magi_pod.sh`
8. Storage persistence should be treated as external:
   - pod-local disk is disposable,
   - Cloudflare R2 is the canonical durable target for outputs/reports/cache bundles (`docs/cloudflare-r2.md`).
9. Budget and storage-cost decisions are centralized in:
   - `docs/budget-analysis.md`
10. Prebuild tuple pipeline is now implemented in-repo:
    - publish: `VideoDiffusion/publish_r2_prebuild.sh`
    - fetch/restore: `VideoDiffusion/restore_r2_prebuild.sh`
    - object layer: `scripts/cloudflare/prebuild_bundle.py`
11. Restore policy now supports `--mode auto|tuple|image`:
    - `auto` tries runtime image first, then tuple fallback
    - `tuple` enforces env/wheel/weights restore only
    - `image` enforces image path (fails hard if unavailable)
12. Lifecycle remote runs now upload final run artifacts to:
    - `neurodiffusion/runs/<run_id>/` with checksum manifest.
13. Lifecycle remote runs now support controlled tuning overrides without script edits on pod:
    - frame/steps/geometry, calibration knobs, and stream queue/JPEG knobs can be injected from local env into `test_scripted_30s.sh`.
14. First full MAGI tuple publish with real weights is validated:
    - `runtime_tag`: `hopper_sm80_py310_torch240_cu124_20260217_prebuild1`
    - env archive: `3,924,169,961` bytes
    - weights archive: `18,617,611,111` bytes
    - latest manifest timestamp: `2026-02-17T23:04:08+00:00`
15. Pod spend-control rule remains enforced after publish completion:
    - terminate immediately with `prime pods terminate <POD_ID> --yes`
16. Manual fallback render path is validated for full-length output:
    - restore tuple (`--mode tuple`) -> run `setup.sh` delta -> run `test_single_chunk.sh`
    - profile: `4.5B_distill`, `FP8=0`, `384x384`, `8` steps, `720` frames
    - output validated at `/Users/xenochain/Downloads/magi_try.mp4` (`30.0s`, `720` frames)
17. Tuple restore/download integrity hardening is now in place:
    - `scripts/cloudflare/prebuild_bundle.py fetch` verifies SHA256 per artifact against manifest and fails fast on mismatch.
    - `VideoDiffusion/restore_r2_prebuild.sh` now serializes apply-target extraction with lock directories to avoid concurrent extract corruption.
18. Latest validated lifecycle 30s scripted run (manual artifact pullback) succeeded:
    - `run_tag`: `lifecycle_30s_a100_nonspot_fix2_20260218_050739`
    - `GPU`: `A100 80GB x1` (Datacrunch, non-spot), `rate=$1.29/h`
    - `profile`: `384x384`, `8` steps, `720` frames, non-quant `4.5B_distill`
    - result: `status=OK`, `frame_count=720`, `duration=30.0s`
    - measured `steady_tpoc_p90_s=10.2052` against `target_tpoc_s=12.0`
    - estimated spend from summary: `$0.1476`
19. Prime create volatility reproduced again on 2026-02-24:
    - dry-run realtime4 selection chose `RTX4090 24GB x4` (`availability_id=6c7af3`, `eu_north`, `$2.3768/h`),
    - immediate `prime pods create` failed twice with the same selected ID (`exit=1`).
20. Lifecycle wrapper now includes built-in stale-offer failover and telemetry:
    - `VideoDiffusion/run_scripted_30s_prime.sh` supports `--max-provision-retries`,
    - on provision failure it re-queries and reselects excluding failed IDs,
    - emits JSONL attempt logs at `VideoDiffusion/.tmp/magi_lifecycle_telemetry_<run_tag>.jsonl`.
21. Realtime floor availability can be empty at run time:
    - a 2026-02-24 dry run with `--selection-goal realtime --min-gpu-count 4` returned no eligible offers despite 17 total scanned offers.
    - operators should expect transient `required_gpu_count` misses and retry at a different time/region.
22. Stored telemetry artifacts from 2026-02-24 session:
    - `VideoDiffusion/.tmp/magi_offer_scan_4.5b_realtime4_dry_20260224_104459.json`
    - `VideoDiffusion/.tmp/magi_offer_scan_4.5b_realtime4_live_20260224_104603.json`
    - `VideoDiffusion/.tmp/magi_lifecycle_telemetry_retrylogic_selftest3_20260224.jsonl`
    - `VideoDiffusion/.tmp/magi_lifecycle_telemetry_invalidid_retrypath_20260224.jsonl`
    - `VideoDiffusion/.tmp/magi_lifecycle_telemetry_retryloop_runtime_test_20260224.jsonl`
23. Vast H200 smoke attempt on 2026-05-14 exposed a runtime tuple / GPU architecture mismatch:
    - instance class: `H200 x1`, `compute_cap=900`, `220 GB` disk, selected rate about `$1.97/h`
    - restored tuple: `hopper_sm80_py310_torch240_cu124_20260217_prebuild1`
    - restore succeeded for both env archive and weights archive
    - MAGI reached DiT model build and weight load
    - final failure happened during VAE decode: `RuntimeError: CUDA error: no kernel image is available for execution on the device`
24. The 2026-05-14 H200 failure means the current `sm80` tuple must be treated as A100-class only until a Hopper/sm90 tuple is published.
25. Vast helper bugs fixed from the 2026-05-14 run:
    - `scripts/vast/provision_video_instance.sh` no longer drops create/show JSON through a pipe-plus-heredoc parse bug.
    - `scripts/vast/resolve_ssh.sh` captures `vastai show instances --raw` before parsing.
    - `scripts/vast/terminate_instance.sh` captures `vastai show instances --raw` before parsing; direct `vastai destroy instance <id> --raw` was required once before this fix.
26. R2 restore helper bug fixed from the 2026-05-14 run:
    - `scripts/cloudflare/r2_common.sh` now sends bootstrap diagnostics to stderr when the caller expects only a Python path on stdout.
27. Restored venv portability bug fixed from the 2026-05-14 run:
    - the tuple venv contained console scripts with old absolute shebangs
    - `VideoDiffusion/restore_r2_prebuild.sh` now repairs restored console-script shebangs
    - `VideoDiffusion/test_single_chunk.sh` also invokes `torch.distributed.run` through the selected Python when the restored `torchrun` script would be non-relocatable.
28. First-run prompt embedding can look like a hang:
    - the 4.5B config uses `t5_device='cpu'` by default
    - the H200 run spent roughly three minutes in CPU-heavy prompt embedding / compile before DiT load
    - `VIDEO_MAGE_T5_DEVICE` / `MAGI_T5_DEVICE` overrides were added for smoke runs that should put T5 on CUDA.
29. New Vast fast-smoke wrapper:
    - `VideoDiffusion/run_magi_vast_smoke.sh`
    - enforces runtime-tag GPU compatibility before restoring
    - waits for SSH auth readiness before cutting a fresh instance
    - installs minimal smoke-time system dependencies (`build-essential`, Python headers/venv/pip, `ffmpeg`)
    - restores the R2 tuple, runs smoke detached with polling, pulls logs/MP4 locally, and can destroy the instance with `MAGI_VAST_DESTROY_ON_EXIT=1`.
30. Post-run spend check on 2026-05-14:
    - incompatible H200 instance was explicitly destroyed
    - `vastai show instances --raw` returned `[]`.
31. Vast A100 retry on 2026-05-14 improved architecture compatibility but exposed fresh-image dependency gaps:
    - selected compatible `A100-SXM4-40GB` host from an `A100 x8` listing
    - first retry reached `Permission denied (publickey)` immediately after `running`; the instance was destroyed and wrapper gained SSH-auth wait/retry
    - second retry restored tuple, repaired `40` venv console-script shebangs, put T5 on CUDA, built DiT, and loaded weights
    - smoke failed when Triton tried to compile its CUDA driver helper because `/usr/include/python3.10/Python.h` was missing
    - wrapper now installs Python headers and build tooling before smoke
32. Vast A100 retry with fresh-image system deps succeeded on 2026-05-14:
    - selected compatible `A100-SXM4-40GB` host from an `A100 x8` listing
    - restored `hopper_sm80_py310_torch240_cu124_20260217_prebuild1`
    - repaired `40` restored venv console-script shebangs
    - put T5 on CUDA with `VIDEO_MAGE_T5_DEVICE=cuda`
    - built DiT, loaded weights, and completed one 24-frame MAGI smoke
    - peak memory reported by MAGI was `18.30 GB` allocated and `18.33 GB` reserved
    - pulled validated local output to `/Users/xenochain/Downloads/neurodiffusion_magi_a100_sm80_smoke_deps_20260514_0650/magi_vast_smoke_24f.mp4`
    - `ffprobe` validation reported `duration=1.000000` and `nb_read_frames=24`
33. All Vast instances from the 2026-05-14 debugging pass were destroyed; latest active-instance proof was `[]`.

## 4) Performance observations

1. `TPOC` (steady-state chunk generation time) is the primary real-time control metric.
2. `TTFC` can be higher due to warmup and should be separated from steady-state metrics.
3. Queue behavior affects perceived prompt latency:
   - larger `QUEUE_LEN` -> more buffering -> slower visible prompt reaction
   - `DROP_OLD_ON_PROMPT=1` reduces visible lag after prompt change
4. `MAGI_WINDOW_SIZE=1` gives tighter prompt responsiveness, while larger values may improve throughput at the cost of control latency.
5. First-run compilation/JIT overhead can skew early measurements; calibration should use multiple chunks and exclude first-chunk timings for steady-state estimates.
6. A one-GPU `A100 80GB` run can still produce a full 30s clip on the low-cost profile, but this does not satisfy near-real-time chunk latency for interactive steering.

## 4.0.1) Offline OpenBCI EEG control scaffold

1. The no-pay EEG path is now local-first:
   - `VideoDiffusion/eeg_control/fake_video_control_server.py` emulates MAGI `/prompt`, `/stats`, and chunk-boundary prompt application.
   - `VideoDiffusion/eeg_control/openbci_to_video_prompt.py` maps mock, BrainFlow, or LSL EEG windows to prompt updates.
   - `VideoDiffusion/eeg_control/calibrate_eeg.py` writes local threshold suggestions under `VideoDiffusion/.tmp/`.
2. The systematic runner is `VideoDiffusion/eeg_control/run_neurofeedback_session.py`:
   - signal reader -> EEG features -> neuro-state estimator -> art policy -> sink.
   - built-in policies include `reward`, `balancer`, `mirror`, and `inversion`.
   - sinks include `stdout`, `jsonl`, `http`, and `schedule`.
3. Current OpenBCI docs imply these implementation constraints:
   - BrainFlow is the primary hardware integration layer.
   - the OpenBCI GUI/LSL path should be treated as a debugging bridge.
   - Cyton/Cyton+Daisy serial mode should use `/dev/cu.*` on macOS.
   - Cyton WiFi / Cyton+Daisy WiFi / Ganglion WiFi need `--ip-port` with optional `--ip-address`.
4. This scaffold should be validated with mock EEG and then real OpenBCI dry-run logs before any paid Vast instance is launched.
5. For live MAGI use, EEG control must respect the existing chunk-boundary contract; it should send stable state changes with cooldown, not per-frame prompt churn.

## 4.1) GPU type findings (Prime + upstream MAGI guidance)

1. Upstream MAGI guidance maps tiers to practical hardware targets:
   - `4.5B`: `RTX4090 x1` baseline fast path
   - `24B`: `H100/H800 x8`
   - `24B distill + fp8 quant`: `H100/H800 x4`
2. Policy encoded in `scripts/prime/magi_gpu_policies.json` adds Prime-friendly equivalents:
   - `4.5b`: `RTX4090_24GB`, `A6000_48GB`, `A100_80GB`, `H100_80GB`, `H200_141GB`
   - `24b`: `H100_80GB`, `H200_141GB`
3. Live Prime scan dry-runs (2026-02-16 and 2026-02-17) confirmed multi-type offer discovery is volatile but functional via:
   - `scripts/prime/query_magi_offers.py`
   - `scripts/prime/select_magi_offer.py`
4. A dry-run on `2026-02-17` in `eu_north` selected:
   - `--selection-goal cost`: `A100 80GB (Spot) x1`, `rate=$0.4515/h`.
   - `--selection-goal realtime`: `A6000 48GB x4`, `rate=$1.9768/h`.
5. Deterministic selection rule in the selector script is stable:
   - first filter by required GPU floor (`realtime_min_nproc` for `--selection-goal realtime`, `min_viable_nproc` for `--selection-goal cost`, or `--min-gpu-count` override),
   - then lower `price_value`, then higher `gpu_count`, then preferred region rank, then provider lexical.
6. Current policy encodes `realtime_min_nproc=4` for `4.5b`, to avoid underpowered one-GPU picks for near-real-time tests.

## 5) Failure modes and remedies

### flash-attn / attention build

- Symptom: long compile times or build failures on fresh pods.
- Remedy:
  - wheel-first install policy in `VideoDiffusion/setup.sh`
  - constrained source fallback with:
    - `FLASH_ATTN_MAX_JOBS=1`
    - `FLASH_ATTN_NVCC_THREADS=1`
    - `FLASH_ATTN_SKIP_SM90=1` (non-Hopper)
    - `MAGI_ATTENTION_SKIP_SM90=1` (non-Hopper)
  - practical acceleration pattern:
    - prebuild wheels once (matching python/torch/cuda/arch),
    - store under R2 `neurodiffusion/wheelhouse/`,
    - reuse on fresh pods.

### Vast / runtime tuple architecture mismatch

- Symptom: MAGI reaches DiT build and loads `4.5B_distill`, then VAE decode fails with:
  - `RuntimeError: CUDA error: no kernel image is available for execution on the device`
- Confirmed context:
  - `H200 x1` / `compute_cap=900`
  - restored tuple `hopper_sm80_py310_torch240_cu124_20260217_prebuild1`
  - failure in `flash_attn_qkvpacked_func` during VAE decode.
- Cause:
  - restored flash-attn/MAGI runtime contains kernels for the wrong architecture family.
- Remedy:
  - use A100-class hosts for the current `sm80` tuple,
  - or publish a dedicated `sm90`/Hopper tuple before selecting H100/H200,
  - pass `--runtime-tag <tag>` to `scripts/vast/select_video_offer.py` so selection filters incompatible GPUs.

### R2 restore / console script portability

- Symptom: restored tuple smoke fails before model load with:
  - `bad interpreter: /root/neurodiffusion/VideoDiffusion/.venv/bin/python: No such file or directory`
- Cause:
  - Python console scripts inside the restored venv keep the absolute shebang from the machine that published the tuple.
- Remedy:
  - `VideoDiffusion/restore_r2_prebuild.sh` repairs restored console-script shebangs.
  - `VideoDiffusion/test_single_chunk.sh` invokes `python -m torch.distributed.run` when using the project venv.

### Vast fresh image missing Python headers

- Symptom: A100-compatible restored tuple reaches DiT load, then fails when Triton compiles its CUDA helper:
  - `/tmp/.../main.c:5:10: fatal error: Python.h: No such file or directory`
  - subprocess command includes `/usr/bin/gcc ... -I/usr/include/python3.10`
- Cause:
  - base Vast image had gcc but not the matching Python dev headers.
- Remedy:
  - `VideoDiffusion/run_magi_vast_smoke.sh` now installs minimal system deps before smoke:
    - `build-essential`
    - `python3-dev`
    - `python3-venv`
    - `python3-pip`
    - `ffmpeg`

### Static-looking MP4

- Symptom: output appears like a still image despite valid video container.
- Checks:
  - `ffprobe` frame count/duration
  - `ffmpeg -vf mpdecimate` for motion retention
- Remedy:
  - stronger motion prompt cues (camera + world movement + parallax)
  - multi-chunk schedules instead of single short chunk

### Stream recorder robustness

- Symptom: ffmpeg multipart parse instability.
- Remedy:
  - keep `/stream` MJPEG-only payloads
  - avoid mixed content-types in multipart stream
  - record with fixed frame target and validate output
  - `test_scripted_30s.sh` now dumps stream-log tail immediately when server readiness fails.

### Prime lifecycle integration failures (fixed)

- Symptom: remote phase used stale `PRIME_POD_ID` from `config/prime.env`.
- Remedy:
  - `scripts/prime/resolve_ssh.sh`, `scripts/prime/run_magi_remote.sh`, and `scripts/prime/terminate_magi_pod.sh`
    now preserve explicit environment overrides over config defaults.

- Symptom: `scp` failed with `stat local "22"` due port flag mismatch.
- Remedy:
  - `scripts/prime/run_magi_remote.sh` now uses separate ssh/scp options (`-p` for ssh, `-P` for scp).

- Symptom: Runpod pods exposed non-22 SSH ports, but remote execution still attempted port `22`.
- Cause:
  - `scripts/prime/run_magi_remote.sh` built `SSH_OPTS`/`SCP_OPTS` before calling `resolve_ssh.sh`, so resolved ports were ignored.
- Remedy:
  - option construction moved after SSH resolution; resolved `PRIME_SSH_PORT` now propagates to both ssh/scp.
  - keepalive/connect-timeout options added to reduce half-open SSH hangs.

- Symptom: `run_magi_remote.sh` dropped out early on remote non-zero exit and could skip artifact pullback.
- Remedy:
  - remote run now captures `REMOTE_RUN_RC`, always attempts artifact sync + optional R2 upload, then returns failure code.

- Symptom: scripted rung-1 startup on `A6000` failed with `Stream process exited before server became ready`.
- Cause (confirmed by code-path comparison):
  - `realtime_magi_stream.py` previously left fp8 quant as shipped config default in `auto`, while `test_single_chunk.sh` auto-disables fp8 on non-SM90 cards.
- Remedy:
  - `realtime_magi_stream.py` now mirrors `test_single_chunk.sh` fp8 auto-detection:
    - enable fp8 on Hopper-class (`sm90+`) GPUs,
    - disable fp8 on SM80/SM86-class GPUs unless explicitly forced.

- Symptom: in-pod scripted run aborted early with `torchrun not found`.
- Cause:
  - `test_scripted_30s.sh` previously defaulted to system `python3`/`torchrun` and hard-failed preflight on pods where only the project `.venv` had PyTorch tooling.
- Remedy:
  - `test_scripted_30s.sh` now prefers `VideoDiffusion/.venv/bin/python` and `VideoDiffusion/.venv/bin/torchrun` automatically.
  - if `torchrun` binary is absent, it falls back to `python -m torch.distributed.run`.

- Symptom: remote prebuild publish failed with `boto3 is required`.
- Cause:
  - `publish_r2_prebuild.sh` only checked for bootstrap venv python existence, not whether `boto3` was actually installed in that venv.
- Remedy:
  - `publish_r2_prebuild.sh` now verifies `boto3` importability and auto-runs `scripts/cloudflare/bootstrap_r2.sh --dry-run` when missing.
  - publish now fails fast with explicit diagnostics only if boto3 still cannot be loaded after bootstrap.

- Symptom: scripted lifecycle run failed with `Calibration ladder had no runnable rung for current CUDA_VISIBLE_DEVICES.`
- Cause:
  - the selected rung (`1x A100`) was runnable but calibration chunk collection timed out (`failed_collect`), so no rung became selectable.
- Remedy:
  - `test_scripted_30s.sh` now emits explicit calibration-timeout diagnostics:
    - `Calibration failed to collect <CALIB_CHUNKS> chunks on all runnable rungs (CALIB_TIMEOUT_S=<...>).`
  - tune `CALIB_TIMEOUT_S` and/or reduce `CALIB_CHUNKS` for first-run warm pods.
  - prefer lifecycle `--selection-goal realtime` to enforce multi-GPU floor for near-real-time runs.

- Symptom: on `RTX4090 x4` (`eu_east`, Runpod), calibration `1/3/4` all reported `failed_collect` with `/stats` reachable but no completed chunks.
- Observed context:
  - stack was fully built and verified (`flash-attn`, `MagiAttention`, `flashinfer`, weights downloaded),
  - `test_scripted_30s.sh` launched each rung, but chunk collection remained empty until timeout.
- Current interpretation:
  - this is a runtime startup/parallelization path issue for this profile (not a dependency-build failure).
- Next experiment:
  - force `MAGI_CP_SIZE=1` (or test alternative CP/PP split) on multi-GPU rung retries before declaring throughput ceilings.

- Symptom: calibration CSV rows were malformed when `devices` contained commas (e.g. `0,1,2`).
- Cause:
  - shell `printf` emitted raw comma-delimited fields without CSV escaping.
- Remedy:
  - `test_scripted_30s.sh` now writes calibration rows through a CSV-escaping helper (`write_calib_row`), preserving parser correctness.

- Symptom: `REMOTE HOST IDENTIFICATION HAS CHANGED` on recycled pod IPs.
- Remedy:
  - lifecycle supports ephemeral known-host handling via:
    - `PRIME_STRICT_HOST_KEY_CHECKING=no`
    - `PRIME_USER_KNOWN_HOSTS_FILE=/dev/null`
    - `PRIME_GLOBAL_KNOWN_HOSTS_FILE=/dev/null`

- Symptom: fresh pod bootstrap raced apt lock and/or waited unnecessarily.
- Remedy:
  - remote bootstrap now waits for active `apt-get`/`dpkg` processes before `setup.sh`.

- Symptom: R2 `weights_archive` uploaded as tiny file (`232` bytes) even after successful downloads.
- Cause:
  - default publish source `MAGI-1/downloads/` is symlink-normalized by `download_weights.sh`;
    archive creation captured symlink entries instead of full files.
- Remedy:
  - publish from a real-files source path:
    - `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/.`
  - re-publish same `runtime_tag` to replace incomplete weights artifact.

- Symptom: tuple restore failed immediately on fresh pods with `[error] boto3 is required`.
- Cause:
  - helper R2 python env existed but was incomplete (missing `boto3` and, on some pods, missing `pip` due `python3-venv` absence).
- Remedy:
  - `VideoDiffusion/restore_r2_prebuild.sh` now validates `boto3` importability and triggers bootstrap auto-heal.
  - `scripts/cloudflare/bootstrap_r2.sh` now repairs broken helper venvs and falls back to `python3-pip` + user-site `boto3` install when venv creation is unavailable.

- Symptom: `run_magi_remote.sh` could fail before sync with `mktemp ... File exists`.
- Cause:
  - non-portable `mktemp /tmp/name.XXXXXX.tar.gz` usage.
- Remedy:
  - switched to base `mktemp` + explicit rename to `.tar.gz`.

- Symptom: remote artifact pullback stalled for long periods after run completion.
- Cause:
  - script recursively copied full remote `VideoDiffusion/.tmp/` (including huge restore caches).
- Remedy:
  - `run_magi_remote.sh` now bundles and downloads only run-tag-matching `.tmp` files.

- Symptom: lifecycle wrappers could hang after in-pod scripted run finished, leaving local SSH/wrapper processes alive.
- Cause:
  - `test_scripted_30s.sh` watchdog used a background shell with `sleep`, which could leave a long-lived inherited stdio process and keep SSH sessions open.
- Remedy:
  - watchdog switched to a single-process Python timer (`VideoDiffusion/test_scripted_30s.sh`) so cleanup can terminate it reliably without orphaned `sleep` channel hold.

- Symptom: dynamic prompt update path threw:
  - `Inplace update to inference tensor outside InferenceMode is not allowed`.
- Cause:
  - chunk-conditioning tensors were updated with in-place writes outside `torch.inference_mode()`.
- Remedy:
  - `realtime_magi_stream.py` now applies prompt updates with `copy_` inside `torch.inference_mode()`.

- Symptom: scripted output could end at calibration length (for example 96 frames) even when final run requested more frames.
- Cause:
  - calibration `start_stream` mutated global `MAGI_NUM_FRAMES`, and final run reused the mutated value.
- Remedy:
  - `test_scripted_30s.sh` now keeps final target frames in a dedicated variable and uses that for final stream, ffmpeg capture, and frame validation.

- Symptom: `prime pods create` failed with `No valid GPU configuration found` right after successful offer selection.
- Cause:
  - selected `availability_id` became stale between `availability list` and `pods create`.
- Remedy:
  - `run_scripted_30s_prime.sh` now supports `--max-provision-retries`.
  - on provision failure it re-queries, excludes failed IDs, and deterministically reselects.
  - per-attempt telemetry is persisted in `VideoDiffusion/.tmp/magi_lifecycle_telemetry_<run_tag>.jsonl`.

## 6) Validated commands

### Prompt-schedule execution

```bash
python VideoDiffusion/run_prompt_schedule.py \
  --url http://localhost:8000 \
  --schedule-csv VideoDiffusion/prompt_schedules/cyberpunk_30s_hybrid.csv \
  --poll 0.25 \
  --timeout 180 \
  --report-json VideoDiffusion/.tmp/prompt_schedule_report.json \
  --report-csv VideoDiffusion/.tmp/prompt_schedule_report.csv
```

### Full scripted 30s test (budget-guarded)

```bash
cd VideoDiffusion
HOURLY_RATE_USD=<HOURLY_RATE_USD_FROM_SELECTED_OFFER> \
BUDGET_USD=15 \
CUDA_VISIBLE_DEVICES=0,1,2,3 \
bash ./test_scripted_30s.sh
```

### Video validation

```bash
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,duration \
  -of json VideoDiffusion/magi_scripted_30s.mp4
```

### Prime lifecycle automation

```bash
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode lifecycle \
  --tier 4.5b \
  --budget-usd 15 \
  --selection-goal realtime \
  --min-gpu-count 4 \
  --max-provision-retries 4 \
  --restore-mode auto \
  --runtime-tag <runtime_tag>
```

Lifecycle telemetry artifact:

- `VideoDiffusion/.tmp/magi_lifecycle_telemetry_<run_tag>.jsonl`

### Prime matrix automation

```bash
bash VideoDiffusion/run_prime_gpu_matrix.sh \
  --tier 24b \
  --budget-usd 15 \
  --slice-usd 3 \
  --restore-mode auto \
  --runtime-tag <runtime_tag>
```

### Cloudflare canonical publish/restore

```bash
bash scripts/cloudflare/publish_everything_r2.sh \
  --runtime-tag <runtime_tag> \
  --tiers 4.5b,24b \
  --include-weights \
  --include-image

WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/. \
bash VideoDiffusion/publish_r2_prebuild.sh \
  --runtime-tag <runtime_tag> \
  --tiers 4.5b,24b \
  --include-weights \
  --allow-missing-image

bash VideoDiffusion/restore_r2_prebuild.sh \
  --mode auto \
  --runtime-tag <runtime_tag> \
  --tier 4.5b \
  --apply-venv-target /root/neurodiffusion/VideoDiffusion/.venv \
  --apply-weights-target /root/neurodiffusion/VideoDiffusion/MAGI-1
```

## 7) Run log table template

| Date (UTC) | Region | GPU offer | Hourly rate | Profile | TPOC p90 (s) | Cue fidelity | Cost est | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| YYYY-MM-DD | eu_* / us_* | e.g. 4x RTX4090 | 2.3768 | scripted_30s_640x640_s16 | 0.00 | 0.00 | $0.00 | PASS/FAIL |
| 2026-02-17 | eu_north | A100 80GB (Spot) x1 | 0.4515 | lifecycle_dry_run_selection | N/A | N/A | $0.00 | DRY-RUN |
| 2026-02-17 | eu_north | A6000 48GB x4 (Runpod) | 1.9768 | lifecycle_dry_run_selection_realtime | N/A | N/A | $0.00 | DRY-RUN |
| 2026-02-17 | eu_north | A6000 48GB (Spot) x1 | 0.1715 | lifecycle_live_setup_attempt | N/A | N/A | < $0.20 | FAIL (spot interruption during setup download) |
| 2026-02-17 | eu_north | A6000 48GB x1 (Runpod non-spot) | 0.5068 | lifecycle_live_bootstrap_compile | N/A | N/A | ~ $1.0-$1.5 | FAIL (stream server readiness on rung-1; fp8 auto mismatch fixed) |
| 2026-02-17 | eu_north | A100 80GB (Spot) x1 | 0.4515 | lifecycle_live_scripted30s | N/A | N/A | ~ $0.02 (scripted phase only) | FAIL (calibration `failed_collect` on rung-1; calibration-timeout diagnostics + realtime floor policy added) |
| 2026-02-17 | eu_east | RTX4090 24GB x4 | 2.3768 | lifecycle_live_bootstrap_plus_scripted_smoke | N/A | N/A | ~ $0.48 (scripted phase) | FAIL (all calibration rungs `failed_collect`; stack build succeeded, runtime generation still not producing chunks) |
| 2026-02-17/18 | eu_north | A100 80GB (Spot) x1 | 0.4515 | full_runtime_tuple_publish | N/A | N/A | ~ $1.89 | PASS (real env+weights archives published to R2; pod terminated) |
| 2026-02-18 | eu_north | A100 80GB (Spot) x1 | 0.4515 | tuple_restore_debug | N/A | N/A | ~ $0.05 | PASS (tuple restore path validated after boto3/bootstrap fallback fixes) |
| 2026-02-18 | eu_north | A100 80GB (Spot) x1 | 0.4515 | scripted_4s_96f_384_s8_fix3 | 6.235 | 0.1667 | ~ $0.08 | FAIL (18/18 cues applied, lag up to +6 chunks; debug short run produced 96 frames/4.0s, not full 30s) |
| 2026-02-18 | eu_north | A100 80GB (Datacrunch) x1 | 0.4515 | direct_30s_720f_384_s8_nonquant | N/A | N/A | ~ $0.14 | PASS (`test_single_chunk.sh` produced `30.0s`/`720` frames clip; pulled to `/Users/xenochain/Downloads/magi_try.mp4`; pod terminated) |
| 2026-02-18 | eu_north | A100 80GB (Datacrunch non-spot) x1 | 1.29 | lifecycle_scripted30s_fix2 | 10.2052 | 1.0000 | ~ $0.1476 | PASS (`run_scripted_30s_prime.sh` in-pod run reached `status=OK`; lifecycle wrapper still needed manual artifact pull in this run; pod terminated) |
| 2026-02-24 | eu_* / us_* | none (realtime floor >=4 GPUs) | N/A | lifecycle_realtime4_dry_run | N/A | N/A | $0.00 | FAIL (no offers satisfied `required_gpu_count=4` at query time) |
| 2026-02-24 | eu_north | RTX4090 24GB x4 | 2.3768 | lifecycle_realtime4_create_attempt | N/A | N/A | $0.00 | FAIL (selected `availability_id=6c7af3`; `prime pods create` returned `No valid GPU configuration found`) |
| 2026-02-24 | eu_* / us_* | mixed 4.5b offers | varies | lifecycle_retry_logic_dryrun_and_failure_path | N/A | N/A | $0.00 | PASS (retry-aware selection + telemetry path validated; no pods left active) |
| 2026-05-14 | Vast FR | H200 x1 | 1.9709 | r2_tuple_sm80_24f_384_s8 | N/A | N/A | live paid debug | FAIL (tuple restore succeeded; DiT loaded; VAE decode failed with `no kernel image` because current tuple is sm80 and host was sm90/H200; instance destroyed and `vastai show instances --raw` returned `[]`) |
| 2026-05-14 | Vast SI | A100-SXM4-40GB from A100 x8 listing | 5.8676 | r2_tuple_sm80_24f_384_s8 | N/A | N/A | live paid debug | FAIL (architecture matched; tuple restore and shebang repair succeeded; DiT loaded; Triton failed because Python headers were missing; wrapper now installs system deps; instance destroyed and `vastai show instances --raw` returned `[]`) |
| 2026-05-14 | Vast SI | A100-SXM4-40GB from A100 x8 listing | 5.8676 | r2_tuple_sm80_24f_384_s8_deps | N/A | N/A | live paid debug | PASS (system deps installed; tuple restore and shebang repair succeeded; T5 ran on CUDA; MAGI produced a validated `24` frame / `1.0s` MP4 at `/Users/xenochain/Downloads/neurodiffusion_magi_a100_sm80_smoke_deps_20260514_0650/magi_vast_smoke_24f.mp4`; instance destroyed and `vastai show instances --raw` returned `[]`) |

## 8) Open issues and next experiments

1. Add matrix resume mode that skips already-tested `availability_id` rows and appends to existing reports.
2. Add a replay tool that overlays cue IDs and chunk indices onto review videos for visual audit.
3. Add continuous calibration history tracking (CSV/JSON time series) for regression detection.
4. Evaluate alternative queue settings for better balance between prompt responsiveness and frame-drop stability.
5. Add objective continuity scoring between cue transitions for long-script runs.
6. Run the same Vast/R2 wrapper against a longer quality profile after the 24-frame A100 smoke:
   - 96 frames for prompt/motion sanity,
   - then 720 frames for the 30-second cheap pretty render.
7. Quantify startup-time reduction from:
   - baseline `setup.sh` on fresh pod,
   - prebuilt image only,
   - prebuilt image + R2 wheel/env cache restore.
8. Benchmark fresh-pod restore latency from published tuple `hopper_sm80_py310_torch240_cu124_20260217_prebuild1` and compare against fresh `setup.sh`.
9. Publish a true Hopper/sm90 tuple if H100/H200 is needed; until then, route `hopper_sm80_py310_torch240_cu124_20260217_prebuild1` to A100-class hosts only.
10. Eliminate macOS extended-attribute tar warnings in remote sync archives (cleaner logs, lower noise in failure triage).
11. Re-run one full lifecycle pass with `--max-provision-retries 4` and capture a successful 4+ GPU realtime calibration dataset.
12. Optimize R2 bootstrap so fresh pods use the helper venv cleanly after `python3-venv` is installed instead of falling back to system user-site `boto3`.
