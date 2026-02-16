# MAGI-1 Observations (Master Reference)

_Last updated: 2026-02-16_

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
3. Current Prime CLI/API workflow does not expose a stable numeric credits endpoint in command output used by this repo.
4. Budget control is enforced by time-based spend caps:
   - `max_runtime_sec = floor((budget_usd * 0.90 / hourly_rate_usd) * 3600)`
5. Explicit spend stop command remains:
   - `prime pods terminate <POD_ID> --yes`
6. Live lifecycle testing on 2026-02-16 validated that pod provisioning and teardown are stable through:
   - `scripts/prime/provision_magi_pod.sh`
   - `scripts/prime/terminate_magi_pod.sh`
7. Storage persistence should be treated as external:
   - pod-local disk is disposable,
   - Cloudflare R2 is the canonical durable target for outputs/reports/cache bundles (`docs/cloudflare-r2.md`).

## 4) Performance observations

1. `TPOC` (steady-state chunk generation time) is the primary real-time control metric.
2. `TTFC` can be higher due to warmup and should be separated from steady-state metrics.
3. Queue behavior affects perceived prompt latency:
   - larger `QUEUE_LEN` -> more buffering -> slower visible prompt reaction
   - `DROP_OLD_ON_PROMPT=1` reduces visible lag after prompt change
4. `MAGI_WINDOW_SIZE=1` gives tighter prompt responsiveness, while larger values may improve throughput at the cost of control latency.
5. First-run compilation/JIT overhead can skew early measurements; calibration should use multiple chunks and exclude first-chunk timings for steady-state estimates.

## 4.1) GPU type findings (Prime + upstream MAGI guidance)

1. Upstream MAGI guidance maps tiers to practical hardware targets:
   - `4.5B`: `RTX4090 x1` baseline fast path
   - `24B`: `H100/H800 x8`
   - `24B distill + fp8 quant`: `H100/H800 x4`
2. Policy encoded in `scripts/prime/magi_gpu_policies.json` adds Prime-friendly equivalents:
   - `4.5b`: `RTX4090_24GB`, `A6000_48GB`, `A100_80GB`, `H100_80GB`, `H200_141GB`
   - `24b`: `H100_80GB`, `H200_141GB`
3. Live Prime scan dry-runs (2026-02-16) confirmed multi-type offer discovery is volatile but functional via:
   - `scripts/prime/query_magi_offers.py`
   - `scripts/prime/select_magi_offer.py`
4. Deterministic selection rule in the selector script is stable:
   - lower `price_value`, then higher `gpu_count`, then preferred region rank, then provider lexical.

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

### Prime lifecycle integration failures (fixed)

- Symptom: remote phase used stale `PRIME_POD_ID` from `config/prime.env`.
- Remedy:
  - `scripts/prime/resolve_ssh.sh`, `scripts/prime/run_magi_remote.sh`, and `scripts/prime/terminate_magi_pod.sh`
    now preserve explicit environment overrides over config defaults.

- Symptom: `scp` failed with `stat local "22"` due port flag mismatch.
- Remedy:
  - `scripts/prime/run_magi_remote.sh` now uses separate ssh/scp options (`-p` for ssh, `-P` for scp).

- Symptom: `REMOTE HOST IDENTIFICATION HAS CHANGED` on recycled pod IPs.
- Remedy:
  - lifecycle supports ephemeral known-host handling via:
    - `PRIME_STRICT_HOST_KEY_CHECKING=no`
    - `PRIME_USER_KNOWN_HOSTS_FILE=/dev/null`
    - `PRIME_GLOBAL_KNOWN_HOSTS_FILE=/dev/null`

- Symptom: fresh pod bootstrap raced apt lock and/or waited unnecessarily.
- Remedy:
  - remote bootstrap now waits for active `apt-get`/`dpkg` processes before `setup.sh`.

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
HOURLY_RATE_USD=0.6068 \
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
  --budget-usd 15
```

### Prime matrix automation

```bash
bash VideoDiffusion/run_prime_gpu_matrix.sh \
  --tier 24b \
  --budget-usd 15 \
  --slice-usd 3
```

## 7) Run log table template

| Date (UTC) | Region | GPU offer | Hourly rate | Profile | TPOC p90 (s) | Cue fidelity | Cost est | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| YYYY-MM-DD | eu_* / us_* | e.g. 4x RTX4090 | 2.3768 | scripted_30s_640x640_s16 | 0.00 | 0.00 | $0.00 | PASS/FAIL |

## 8) Open issues and next experiments

1. Add matrix resume mode that skips already-tested `availability_id` rows and appends to existing reports.
2. Add a replay tool that overlays cue IDs and chunk indices onto review videos for visual audit.
3. Add continuous calibration history tracking (CSV/JSON time series) for regression detection.
4. Evaluate alternative queue settings for better balance between prompt responsiveness and frame-drop stability.
5. Add objective continuity scoring between cue transitions for long-script runs.
6. Complete one uninterrupted lifecycle run through:
   - flash-attn build (or prebuilt wheel path),
   - weight download,
   - final MP4 artifact generation and report pullback.
7. Quantify startup-time reduction from:
   - baseline `setup.sh` on fresh pod,
   - prebuilt image only,
   - prebuilt image + R2 wheel/env cache restore.
