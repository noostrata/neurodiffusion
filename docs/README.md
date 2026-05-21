# Docs Index

This directory is the canonical operational documentation for the repo.

## Core docs

- `docs/vastai.md` — current Vast.ai provisioning, offer selection, SSH, persistence, and teardown workflow.
- `docs/prime-intellect.md` — legacy Prime provisioning, CLI, pod lifecycle, pricing snapshots, and billing visibility limitations.
- `docs/prime/how_keys.md` — API keys, SSH keys, and security workflow.
- `docs/cloudflare-r2.md` — canonical R2 storage contract for caches, weights, and run artifacts.
- `docs/accelerate.md` — startup/build acceleration strategy; currently needs a Vast refresh where Prime template assumptions remain.
- `docs/budget-analysis.md` — storage + compute budget model with historical Prime + R2 snapshots; update Vast rates before new paid runs.
- `docs/image-streaming.md` — SD-Turbo image workflow.
- `docs/video-magi1-streaming.md` — MAGI-1 video workflow, chunk-wise prompt hot-swap, and sizing notes.
- `docs/video-krea-streaming.md` — Krea realtime workflow, backend policy, and steering defaults.
- `docs/video-scope-longlive-streaming.md` — Daydream Scope + LongLive realtime workflow, Scope REST/OSC control, and EEG integration.
- `docs/video-scope-longlive-observations.md` — empirical Scope + LongLive B200 validation, WebRTC/EEG results, R2 tuple, and local artifact pointers.
- `docs/video-longlive2-sp-streaming.md` — experimental LongLive2 one-stream sequence-parallel plan for two-card inference, R2 tuples, Vast tests, and EEG integration staging.
- `docs/video-realtime-steering.md` — cross-model realtime steering policy, GPU ranking, and acceptance gates.
- `docs/eeg-openbci-control.md` — no-pay OpenBCI/BrainFlow EEG-to-video prompt-control workflow.
- `docs/video-magi1-scaling-testing.md` — testing matrix, first-principles cluster sizing, and cost-bounded scaling for prompt-reactive MAGI runs.
- `docs/video-magi1-observations.md` — master empirical reference for validated MAGI behavior, performance observations, and failure/remedy notes.
- latest validated MAGI runtime tuple: `hopper_sm80_py310_torch240_cu124_20260217_prebuild1` (full env + full weights archive; see `docs/cloudflare-r2.md` and `docs/video-magi1-observations.md`).
- latest validated Scope/LongLive runtime tuple: `scope_auto_py312_torch2.9.1_cu128_sm100` (Scope uv env + LongLive/Wan model cache; see `docs/cloudflare-r2.md` and `docs/video-scope-longlive-observations.md`).
- latest Scope/LongLive edge sweep: same-instance H200 run passed `352x576` at `24.835 fps` and failed `368x640` at `22.175 fps`; run root `/Users/xenochain/Code/neurodiffusion/artifacts/runs/scope-longlive/scope_longlive_vast_smoke_20260520T211512Z/`.
- latest Scope/LongLive realtime snapshot: `B200 x1` reached `24.868 fps` over a 90s WebRTC receive run with synthetic EEG control; bulky local media was pruned after QA and the telemetry remains in `docs/video-scope-longlive-observations.md`.
- latest Scope/LongLive matrix snapshot: `H200 x1` passed `320x576` at `25.376 fps`; `368x640`, `480x832`, and `RTX 4090 256x448` failed realtime. H200 measured about `4.8-4.9 MPix/s`, so `24 fps` should stay near `<=200k px/frame` unless a faster tier is proven. Run root: `/Users/xenochain/Code/neurodiffusion/artifacts/runs/scope-longlive/scope_longlive_vast_matrix_20260520T200307Z/`.
- latest cheap Scope/LongLive snapshot: `RTX 4090 x1` generated coherent output but failed realtime at `11.310 fps`; bulky local media was pruned after QA.
- latest Scope/LongLive sweep plumbing: `VideoDiffusion/run_scope_longlive_vast_sweep.sh` runs multiple resolutions on one Vast instance after one restore/server start; use it for edge-finding on a chosen GPU.
- latest Scope/LongLive matrix plumbing: `VideoDiffusion/run_scope_longlive_vast_matrix.sh` plans or runs a bounded cross-GPU Vast sweep around the smoke runner; use it for offer/tier selection instead of trying one offer by hand.
- latest LongLive2 SP status: H200 x2 BF16 SP cold render succeeded and produced `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T233039Z/offline/videos/rank0-0-0_regular_sp2.mp4` (`832x480`, `125` frames, `24 fps`, nonblank QA). The run published `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` to R2. First fresh restore validation fetched/extracted the tuple but failed before render because the restored cache did not recreate the LongLive2 Wan symlink; `VideoDiffusion/restore_r2_prebuild_model.sh` now patches that. The next paid step is one no-fallback restore render before promoting the tuple to validated; the detailed order is in `longlive2plan.md`.
- current artifact policy: keep reports/logs/telemetry/manifests in `/Users/xenochain/Code/neurodiffusion/artifacts/`; prune historical MP4/PNG/JPG media after QA with `scripts/prune_artifacts.py`.
- latest scripted stream validation snapshot: `A100 80GB x1` tuned run confirmed chunk-boundary cue application (`18/18`) but not near-real-time (`steady p90 TPOC ~6.2s`); details in `docs/video-magi1-observations.md`.
- latest one-shot quality validation snapshot: `A100 80GB x1` low-cost profile produced full `30.0s` / `720` frame output (`/Users/xenochain/Downloads/magi_try.mp4`); details in `docs/video-magi1-observations.md`.
- `scripts/vast/*.sh|*.py` — current Vast GPU offer discovery, selection, instance lifecycle, SSH resolution, and teardown automation.
- `scripts/prime/magi_gpu_policies.json` + `scripts/prime/*.sh|*.py` — legacy Prime GPU-type policy, discovery, selection, lifecycle execution, and teardown automation.
- `scripts/prime/krea_gpu_policies.json` + `scripts/prime/query_video_offers.py` + `scripts/prime/select_video_offer.py` + `scripts/prime/build_video_runtime_remote.sh` — model-aware offer scan/selection and remote build/publish flow.
- `scripts/cloudflare/bootstrap_r2.sh` + `scripts/cloudflare/bootstrap_r2.py` — one-command Cloudflare R2 layout bootstrap + manifest generation.
- `scripts/cloudflare/publish_repo_bundle.py` + `scripts/cloudflare/publish_everything_r2.sh` — repo code-bundle + model-aware runtime tuple/image publish workflow to R2.
- `scripts/cloudflare/prebuild_bundle.py` + `VideoDiffusion/publish_r2_prebuild_model.sh` + `VideoDiffusion/restore_r2_prebuild_model.sh` — runtime tuple publish/restore pipeline (`--mode auto|tuple|image`) for MAGI, Krea, Scope, and LongLive2.
- `VideoDiffusion/requirements-magi.lock.txt` + `VideoDiffusion/apt-magi.lock.txt` + `VideoDiffusion/runtime-manifest.schema.json` — deterministic dependency/manifest contracts for prebuild artifacts.
- `VideoDiffusion/setup_video_runtime.sh` + `VideoDiffusion/run_video_stream.sh` + Scope/Krea/MAGI/LongLive2 runtime scripts — unified video model setup/launch path (`VIDEO_MODEL=magi|krea|scope|longlive|longlive2`, `ATTN_BACKEND=auto|sage|flash|sdpa`).
- `VideoDiffusion/run_scope_longlive_vast_smoke.sh` — one-command Scope/LongLive Vast smoke: offer selection, provision, R2 restore, WebRTC capture, synthetic EEG, local pullback, structured report, artifact QA, and teardown.
- `VideoDiffusion/run_scope_longlive_vast_sweep.sh` — same-instance Scope/LongLive resolution sweep: one provision/restore/server start, multiple LongLive loads/benchmarks, per-resolution reports, and aggregate `sweep_report`.
- `VideoDiffusion/run_scope_longlive_vast_matrix.sh` — systematic Scope/LongLive Vast validation: fresh offer selection per attempt, default GPU tier ladder without 4090, `320x576` target plus lower/edge/upper resolution probes through `480x832`, budget/time/credit guards, aggregate JSON/CSV/Markdown report, and smoke-runner teardown.
- `VideoDiffusion/scope_run_report.py` — local run/sweep report builder with phase telemetry parsing, ffprobe metadata, nonblank luma QA, and contact-sheet generation.
- `VideoDiffusion/setup_longlive2.sh`, `download_longlive2_models.sh`, `longlive2_config.py`, `run_longlive2_sp_offline.sh`, `run_longlive2_sp_vast_smoke.sh`, `run_longlive2_sp_benchmark.sh`, and `longlive2_run_report.py` — LongLive2 setup, checkpoint cache, prompt schedule/config generation, local/offline SP runner, preflight/budgeted Vast smoke wrapper, same-seed SP benchmark, and report/QA/phase tooling.
- `VideoDiffusion/eeg_control/` + `VideoDiffusion/requirements-eeg.txt` — local EEG feature extraction, fake MAGI/Scope control servers, calibration, and prompt controller.
- `docs/security.md` — secret handling and ignored file patterns.
- `docs/references.md` — upstream docs and source links.
- `AGENTS.md` — operator rules and workflow conventions.

## Legacy

- `docs/legacy/` stores historical pre-migration VAST.ai notes only.
- New onboarding and runbook updates must stay in `docs/` (not legacy).
