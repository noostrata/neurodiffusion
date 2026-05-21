# AGENTS.md (neurodiffusion)

This repository is operator-first. Scripts and docs should make GPU work deterministic, repeatable, and safe on a fresh Vast.ai instance.

## Current Operating Model

- Vast.ai is the active compute provider.
- MAGI-1 is expected to run remotely on a rented GPU instance, not on the local laptop.
- Local development should cover code quality, offer selection, preflight checks, EEG control logic, fake servers, logs, and docs.
- Prime Intellect content is legacy context only. Do not extend `scripts/prime/` or Prime runbooks unless the user explicitly asks for legacy Prime support.
- Cloudflare R2 is optional persistence/cache infrastructure. It is not a substitute for pulling the final generated video back to the local machine.

## Canonical Sources

- `longlive2plan.md` — root LongLive2 paid-run control plan, live checklist, budget envelope, telemetry ledger, and go/no-go criteria.
- `docs/vastai.md` — current Vast provisioning, SSH, lifecycle, and teardown source of truth.
- `docs/video-magi1-streaming.md` — MAGI-1 setup, weights, smoke, stream, prompt, and validation source of truth.
- `docs/video-magi1-observations.md` — empirical MAGI outcomes, failures, fixes, and tuning notes.
- `docs/video-scope-longlive-streaming.md` — Daydream Scope + LongLive realtime setup, OSC control, WebRTC validation, and Vast runbook.
- `docs/video-scope-longlive-observations.md` — empirical Scope + LongLive outcomes, fixes, R2 tuple, local artifacts, and tuning notes.
- `docs/video-longlive2-sp-streaming.md` — LongLive2 one-stream sequence-parallel research, plumbing, R2, Vast, and validation plan.
- `docs/eeg-openbci-control.md` — OpenBCI/BrainFlow EEG control path.
- `docs/cloudflare-r2.md` — R2 cache/artifact layout.
- `docs/accelerate.md` — acceleration/build/cache strategy.
- `docs/budget-analysis.md` — cost formulas and budget notes.
- `docs/prime-intellect.md` and `docs/legacy/` — historical context only.
- `docs/prime/how_keys.md` and `docs/security.md` — key/token hygiene.

## Repository Layout

- `VideoDiffusion/` — MAGI/Krea/Scope setup, weights/model flow, tests, streams, prompt scheduling, EEG control.
- `VideoDiffusion/eeg_control/` — offline EEG feature/state/policy/sink system and fake MAGI-compatible control server.
- `ImageDiffusion/` — SD-Turbo image streaming runtime.
- `scripts/vast/` — current Vast offer query/selection, instance lifecycle, SSH resolver, teardown.
- `scripts/cloudflare/` — R2 bootstrap/publish/restore helpers.
- `scripts/prime/` — legacy Prime support; avoid for new work.
- `config/` — templates and ignored local overrides.
- `docs/` — operator contracts and runbooks.

## Security Rules

1. Never commit secrets, provider tokens, API keys, SSH private keys, HF tokens, R2 credentials, hostnames, IPs, ports, or access tokens.
2. Keep `config/vast.env` ignored and local-only.
3. Keep vendor repos, checkpoints, generated media, logs, and local calibration/session files in ignored paths.
4. Do not print raw credentials in logs or summaries.
5. If a command creates a paid instance, teardown is part of the same task unless the user explicitly asks to keep it running.

## Vast.ai Contract

- Authenticate outside the repo with `vastai set api-key <KEY>`.
- Checking credits, user info, offers, and active instances is no-spend and allowed when relevant.
- Creating an instance is paid work. Do not create one unless the user gives explicit approval or an explicit budget/run request.
- Prefer a one-GPU A100 80GB smoke target for first MAGI proof-of-life unless the user asks for realtime/Hopper testing.
- Prefer `RTX 5090`, `L40S`, H100/H200, or B200-class offers for Scope/LongLive realtime validation. `RTX 4090` is no longer a default realtime tier for this profile.
- Use `scripts/vast/query_video_offers.py` and `scripts/vast/select_video_offer.py` for deterministic offer selection.
- Pass the intended R2 runtime tag to `scripts/vast/select_video_offer.py`; `smXX` tags filter to matching GPU families.
- Current tuple `hopper_sm80_py310_torch240_cu124_20260217_prebuild1` is A100-class only despite the historical `hopper_` prefix. Do not use it on H100/H200 unless intentionally debugging a mismatch.
- Use `scripts/vast/provision_video_instance.sh`, `scripts/vast/resolve_ssh.sh`, and `scripts/vast/terminate_instance.sh` for lifecycle.
- `vastai` JSON output is an external contract. If parsing breaks, update `scripts/vast/resolve_ssh.sh` or the relevant Vast parser first.

## MAGI-1 Remote Smoke Discipline

The local checkout does not need to contain the MAGI-1 vendor repo or weights. A real MAGI test means:

1. Query and select a suitable Vast offer, matching the runtime tuple architecture.
2. Provision a Vast Docker SSH instance.
3. Resolve SSH through `scripts/vast/resolve_ssh.sh`.
4. Prefer `VideoDiffusion/run_magi_vast_smoke.sh` for fast tuple restore, smoke execution, local pullback, and optional teardown.
5. Manual fallback on the instance:
   - `cd /workspace/neurodiffusion/VideoDiffusion`
   - `bash setup.sh`
   - authenticate Hugging Face if needed
   - `bash download_weights.sh`
   - run the cheapest one-GPU smoke first with `test_single_chunk.sh`
6. Validate output with `ffprobe`; use `mpdecimate` when checking for near-static output.
7. Download the generated video and logs to the local machine before teardown.
8. Destroy the Vast instance and verify `vastai show instances --raw`.

Local-only failures such as missing `VideoDiffusion/MAGI-1/example/4.5B/...` usually mean the remote setup has not been run yet, not that MAGI itself is broken.

## Scope / LongLive Discipline

- Scope is the preferred first realtime EEG video target.
- LongLive runs through Daydream Scope, not through the MAGI server.
- `VIDEO_MODEL=scope` and `VIDEO_MODEL=longlive` dispatch to the Scope runtime.
- Scope setup/launch entry points:
  - `VideoDiffusion/setup_scope.sh`
  - `VideoDiffusion/download_scope_models.sh`
  - `VideoDiffusion/run_scope_server.sh`
  - `VideoDiffusion/load_scope_longlive.sh`
  - `VideoDiffusion/scope_webrtc_benchmark.py`
  - `VideoDiffusion/run_scope_longlive_vast_smoke.sh`
  - `VideoDiffusion/run_scope_longlive_vast_sweep.sh`
  - `VideoDiffusion/run_scope_longlive_vast_matrix.sh`
  - `VideoDiffusion/scope_run_report.py`
- Latest validated Scope tuple: `scope_auto_py312_torch2.9.1_cu128_sm100` for B200 / SM100.
- Latest realtime Scope result: `B200 x1` held the current `320x576` target at `>=24 fps` with synthetic EEG steering.
- Latest H200 matrix result: `H200 x1` passed `320x576` (`25.376 fps`) but failed `368x640` (`20.835 fps`) and `480x832` (`12.171 fps`).
- Latest H200 same-instance edge sweep: `352x576` passed (`24.835 fps`) and `368x640` failed (`22.175 fps`); best validated realtime point is now `352x576`.
- Current H200 throughput model is about `4.8-4.9 MPix/s`; a `24 fps` realtime target should stay near or below `200k px/frame` unless a faster GPU/runtime path is proven.
- Latest cheap Scope result: `RTX 4090 x1` generates valid output but is not realtime at `320x576` (`11.310 fps`).
- Latest low-res 4090 result: `RTX 4090 x1` failed realtime at `256x448` (`12.912 fps`, first frame `4.693s`).
- Do not include `RTX 4090` in default paid realtime sweeps. Use `--tiers rtx4090_lowres` only for explicit protocol or quality checks.
- LongLive native/paper-scale target for the next max-resolution pass is `480x832` (`832x480` display orientation); the repo has only proven realtime at `320x576` so far.
- R2 prebuild can restore the Scope uv env and LongLive/Wan model cache; it cannot preserve a live loaded GPU model.
- For a fast fresh boot: clone repo, run `SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh`, restore the Scope tuple, start with `SCOPE_AUTO_LOAD=0`, then load LongLive with `SCOPE_VACE_ENABLED=false`.
- `VideoDiffusion/setup_scope.sh` applies repo patches from `VideoDiffusion/patches/daydream-scope/` by default. Use `SCOPE_APPLY_PATCHES=0` only when intentionally testing unmodified upstream Scope.
- `VideoDiffusion/download_scope_models.sh` uses the repo deterministic LongLive downloader because upstream Scope did not declare downloadable artifacts for `longlive` during the B200 validation.
- Keep VACE disabled for the validated no-VACE text-mode realtime path unless intentionally downloading and testing VACE weights.
- Scope REST controls pipeline lifecycle; OSC controls live runtime parameters.
- EEG should drive Scope through the `scope` sink, which sends OSC updates to `/scope/prompt`, `/scope/noise_scale`, `/scope/transition_steps`, and related runtime controls.
- Use `VideoDiffusion/eeg_control/fake_scope_server.py` and `python3 VideoDiffusion/eeg_control/selftest.py` before any paid Scope run.
- Do not attempt to embed WebRTC inside the EEG loop. Let Scope UI or a browser/WebRTC client own video display; the EEG loop owns control.
- For headless GPU validation, use `VideoDiffusion/scope_webrtc_benchmark.py` and synthetic EEG concurrently, then pull the recorded MP4 and sampled frames before teardown.
- For one paid validation, use `VideoDiffusion/run_scope_longlive_vast_smoke.sh --create-instance`; it queries/selects, provisions, restores, captures, pulls artifacts, writes `run_report.json`, and tears down by default.
- For same-GPU resolution edge finding, prefer `VideoDiffusion/run_scope_longlive_vast_sweep.sh --create-instance`; it creates one instance, restores once, starts Scope once, then writes per-resolution `run_report.json` files plus `sweep_report.json`.
- For cross-GPU offer validation, use `VideoDiffusion/run_scope_longlive_vast_matrix.sh --create-instance`; it retries fresh offers, sweeps GPU tiers and adaptive resolutions, keeps budget/time bounds, writes matrix JSON/CSV/Markdown, and still delegates each paid attempt to the smoke runner for teardown and local artifact pullback.
- Scope/LongLive paid selection defaults to one-GPU offers. Use `--max-gpu-count 0` only when intentionally allowing multi-GPU listings.
- Treat telemetry as part of the artifact contract: preserve `run_report.json`, `sweep_report.*`, `matrix_report.*`, `phase_report.json`, `artifact_qa.json`, sampled frames/contact sheets, ffprobe output, invoice/spend notes, and `[scope-vast-ts]` phase markers when available.

## LongLive2 Sequence-Parallel Discipline

- LongLive2 is experimental and separate from Daydream Scope + LongLive.
- Use it only for the one-stream multi-GPU path where multiple GPUs cooperate on one video generation state.
- Do not present a two-GPU Scope host as a LongLive2 or sequence-parallel result.
- Source-of-truth implementation doc: `docs/video-longlive2-sp-streaming.md`.
- Source-of-truth paid-run checklist: `longlive2plan.md`. Before any paid LongLive2 run, follow and update that checklist phase by phase.
- Entry points:
  - `VideoDiffusion/setup_longlive2.sh`
  - `VideoDiffusion/download_longlive2_models.sh`
  - `VideoDiffusion/longlive2_config.py`
  - `VideoDiffusion/run_longlive2_sp_offline.sh`
  - `VideoDiffusion/run_longlive2_sp_vast_smoke.sh`
  - `VideoDiffusion/run_longlive2_sp_benchmark.sh`
  - `VideoDiffusion/longlive2_run_report.py`
- First target is BF16 Ulysses sequence-parallel inference through upstream `inference_sp.py`, not live EEG.
- First two-card target uses `sp_size=2`, `dp_size=1`, and `torchrun --nproc_per_node=2`.
- The upstream valid SP-size rule is `sp_size` must divide `gcd(model_num_heads, num_frame_per_block)`; for the current `24` heads and `8` frames/block, valid sizes are `1`, `2`, `4`, and `8`.
- Use `VIDEO_MODEL=longlive2` for this path. `VIDEO_MODEL=longlive` remains the Daydream Scope alias.
- LongLive2 EEG plumbing starts offline: compile stable EEG state changes into prompt blocks using `--schedule-csv` or repeated `--shot-prompt` inputs, then render a multi-shot video.
- LongLive2 live EEG requires a future persistent runner with KV-recache/prompt-boundary handling; do not pretend the offline `torchrun` entry point is a live OSC target.
- Keep the LongLive2 default `transformers` pin conservative. Upstream requirements are broad, but paid validation showed `transformers==5.9.0` broke `x_clip_loss`; `setup_longlive2.sh` now pins `4.57.3` and verifies that import.
- Keep `decord` in the LongLive2 extra package list unless upstream requirements add it; paid validation showed upstream imports it without installing it.
- NVFP4 acceleration is Blackwell-only per the LongLive2 paper limitation. On A100/H100/H200, use `bf16_sp` sequence-parallel inference as the compensation path unless intentionally debugging NVFP4/FourOverSix.
- The upstream SP script disables `kv_quant` under Ulysses SP today; do not claim SP+KV-quant speedups unless a real run proves them.
- A valid LongLive2 two-card run must show one output stream plus per-GPU telemetry proving both cards were active.
- Latest cold LongLive2 two-card run succeeded on H200 x2 and published `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` to R2. Treat it as `published_tuple`, not `validated_restore_tuple`, until a fresh restore render passes.
- The first fresh restore validation fetched/extracted the tuple but failed before render because the restored cache did not recreate LongLive2's vendor-local Wan symlink. `VideoDiffusion/restore_r2_prebuild_model.sh` now recreates that link; the next paid validation should run with restore enabled and no HF download fallback.
- `VideoDiffusion/download_longlive2_models.sh` should work with either `hf`/`huggingface-cli` or the Python `huggingface_hub` fallback from the LongLive2 venv.
- LongLive2 runtime needs both LongLive2 checkpoint artifacts and the Wan2.2 base tree. Keep Wan download/linking enabled unless intentionally doing cache-only debugging.
- Use `VideoDiffusion/run_longlive2_sp_vast_smoke.sh --publish-r2-on-success` when the intent is to publish the first reusable tuple before teardown after a successful render.
- R2 may cache the LongLive2 env, built extensions, checkpoints, and generated merged/materialized checkpoints; it cannot preserve a live NCCL process group or GPU-resident model.
- Run `VideoDiffusion/run_longlive2_sp_vast_smoke.sh --preflight` before paid LongLive2 work; it should pass local checks, dry-run, offer selection, active-instance, credit, and budget gates.
- First LongLive2 paid smoke defaults should stay small and explicit: `480x832`, `32` frames, `sp_size=2`, `dp_size=1`, `seed=0`, max-alive around `45 min` for render-only or `60 min` when publishing R2 before teardown, and failure-safe artifact pullback enabled by default.
- EEG integration comes after distributed inference is proven: offline prompt schedule first, persistent runner second, live output third.
- Paid LongLive2 tests must use explicit two-GPU selection and teardown by default.
- Do not promote LongLive2 as the default realtime path until it beats the one-GPU Scope baseline on speed, cost, and visual acceptability.

## Local Artifact Rule

For generated videos, the user wants the result on the local system.

- Remote-only output is incomplete.
- R2-only output is incomplete unless a local copy is also pulled down.
- Prefer a clear local destination such as `/Users/xenochain/Downloads/<run_tag>.mp4` for final user-facing videos.
- Also pull minimal logs/reports needed to explain success/failure.

## MAGI Runtime Contracts

- MAGI-1 generates fixed 24-frame chunks.
- Prompt updates apply at chunk boundaries, not per frame.
- Real-time playback at 24 fps requires steady-state `TPOC <= 1s`.
- For prompt responsiveness: keep `MAGI_WINDOW_SIZE=1`, keep `QUEUE_LEN` small, and keep `DROP_OLD_ON_PROMPT=1`.
- `test_single_chunk.sh` defaults to one GPU and supports:
  - `VIDEO_MAGE_VISIBLE_DEVICES`
  - `VIDEO_MAGE_NPROC`
  - `VIDEO_MAGE_NUM_FRAMES`
  - `VIDEO_MAGE_NUM_STEPS`
  - `VIDEO_MAGE_VIDEO_SIZE_H`
  - `VIDEO_MAGE_VIDEO_SIZE_W`
  - `VIDEO_MAGE_WINDOW_SIZE`
- Geometry must be divisible by 16. Prefer frame counts in multiples of 24.
- Do not mix non-quant configs with quant checkpoint paths unless the path remap is intentional.

## EEG / OpenBCI Control Path

- BrainFlow is the primary hardware abstraction for OpenBCI integration.
- OpenBCI GUI/LSL is a debugging bridge, not the core runtime dependency.
- `VideoDiffusion/eeg_control/run_neurofeedback_session.py` is the systematic path:
  - reader -> features -> neuro-state -> art policy -> sink
- Built-in policies include `reward`, `balancer`, `mirror`, and `inversion`.
- Sinks include `stdout`, `jsonl`, `http`, `scope`, and `schedule`.
- Use the fake local MAGI-compatible server before hardware/GPU tests:
  - `VideoDiffusion/eeg_control/fake_video_control_server.py`
- Use the fake local Scope server before Scope/LongLive GPU tests:
  - `VideoDiffusion/eeg_control/fake_scope_server.py`
- EEG control must send stable state changes with cooldown; do not thrash `/prompt`.

## Code Quality Rules

- Use `set -euo pipefail` in shell scripts.
- Keep scripts idempotent where practical.
- Prefer explicit environment variables over hardcoded constants.
- Avoid manual SSH host strings in tracked files.
- Keep defaults non-interactive for automation compatibility.
- Fail early with clear messages on `stderr`.
- Keep optional dependencies lazy: BrainFlow and pylsl should only import inside paths that need them.
- Add no-cost selftests when adding control logic or parsers.
- Use structured parsers and JSON/CSV writers rather than ad hoc string parsing when practical.

## Docs / Infra Update Discipline

When changing runtime behavior, update in lockstep:

1. Implementation script(s) in `VideoDiffusion/`, `ImageDiffusion/`, or `scripts/`.
2. Relevant source-of-truth docs under `docs/`.
3. `docs/video-magi1-observations.md` for empirical outcomes, failures, fixes, and tuning decisions.
4. `docs/video-scope-longlive-observations.md` for empirical Scope/LongLive outcomes, failures, fixes, and tuning decisions.
5. `docs/vastai.md` if provider behavior or lifecycle changes.
6. `docs/cloudflare-r2.md` if cache/artifact layout changes.
7. `docs/accelerate.md` if startup/build/caching strategy changes.
8. `docs/budget-analysis.md` if pricing assumptions, rates, or budget formulas change.

New provider instructions go under `docs/`, not `docs/legacy/`.

## Validation Gate

Before handing over a branch, run:

```bash
bash scripts/check.sh
```

When attached to a Vast instance, also run:

```bash
vastai show instances --raw
bash scripts/vast/resolve_ssh.sh
```

If a paid instance was created, final handoff must include teardown status and whether local video/log pullback succeeded.
