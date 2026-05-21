# LongLive2 Paid-Run Plan

_Last updated: 2026-05-21_

This is the operator launch plan for the first LongLive2 sequence-parallel run.
It is intentionally conservative because the current Vast budget is enough for a controlled smoke, not an open-ended build/debug session.

Use this file as the live checklist during the run. Do not treat it as static
background documentation: update the status rows, telemetry table, and "What
Changed" notes as soon as each phase finishes.

## Canonical References

Read these before changing the run path:

1. `AGENTS.md` — repo operator rules, paid-instance discipline, and LongLive2-specific constraints.
2. `docs/video-longlive2-sp-streaming.md` — detailed LongLive2 SP research, code plumbing, paper limitations, and validation gates.
3. `docs/vastai.md` — Vast provisioning, offer selection, SSH, lifecycle, teardown, and LongLive2 run commands.
4. `docs/accelerate.md` — acceleration policy, hardware lanes, R2 boundaries, and the Blackwell/NVFP4 limitation.
5. `docs/cloudflare-r2.md` — R2 tuple publish/restore contract and what R2 can/cannot persist.
6. `docs/budget-analysis.md` — current cost formulas, prior spend, and LongLive2 SP budget controls.
7. `docs/eeg-openbci-control.md` — synthetic/OpenBCI EEG control path and LongLive2 offline schedule generation.
8. `docs/video-realtime-steering.md` — cross-model realtime steering architecture and acceptance gates.
9. `docs/video-scope-longlive-streaming.md` — current validated Scope + LongLive live EEG path.
10. `docs/video-scope-longlive-observations.md` — empirical Scope/LongLive performance baselines.
11. `docs/references.md` — upstream LongLive/LongLive2 papers, model cards, and source links.

Relevant implementation entry points:

1. `VideoDiffusion/setup_longlive2.sh`
2. `VideoDiffusion/download_longlive2_models.sh`
3. `VideoDiffusion/longlive2_config.py`
4. `VideoDiffusion/run_longlive2_sp_offline.sh`
5. `VideoDiffusion/run_longlive2_sp_vast_smoke.sh`
6. `VideoDiffusion/longlive2_run_report.py`
7. `scripts/vast/query_video_offers.py`
8. `scripts/vast/select_video_offer.py`
9. `VideoDiffusion/publish_r2_prebuild_model.sh`
10. `VideoDiffusion/restore_r2_prebuild_model.sh`

## First-Principles Objective

The system we want is:

```text
EEG state -> stable low-rate command -> video model state -> visible change -> audience/brain reacts -> repeat
```

The LongLive2 question is narrower:

```text
Can one video stream become fast enough by splitting one generation state across multiple GPUs?
```

Data parallelism is not useful for the installation because it creates multiple independent videos.
The target is sequence parallelism:

```text
one LongLive2 AR state
  -> torchrun ranks cooperate on one denoising/generation state
  -> rank 0 writes/streams one output
```

The decisive metric is not "two GPUs were rented."
The decisive metric is:

```text
speedup = fps_sp2 / fps_sp1
```

Decision gates:

1. `speedup < 1.3x`: stop LongLive2 SP as a live path for now.
2. `1.3x <= speedup < 1.6x`: continue only if quality/cost look unusually good.
3. `speedup >= 1.6x`: LongLive2 SP becomes a serious live-runner candidate.

## Hardware Constraint From The Paper

The LongLive2 paper explicitly states that low-bit NVFP4 acceleration is hardware-dependent:

1. NVFP4 acceleration needs Blackwell Tensor Cores and optimized kernels.
2. GB200/B200-class hardware is the intended maximum-performance NVFP4 lane.
3. A100, H100, and H200 do not have native hardware support for those optimized NVFP4 kernels.
4. On non-Blackwell platforms, the paper's compensating strategy is SP inference.

Operational consequence:

```text
A100/H100/H200 -> bf16_sp sequence-parallel path
B200/GB200/RTX50-class -> nvfp4_s2 or nvfp4_s4 path
```

Do not start by trying `nvfp4_s2` on H200.
That is exactly the mismatch the paper warns about.

The repo now encodes this:

1. `VideoDiffusion/run_longlive2_sp_vast_smoke.sh` rejects NVFP4 profile/runtime combinations targeting non-Blackwell GPUs unless explicitly overridden.
2. `docs/video-longlive2-sp-streaming.md`, `docs/accelerate.md`, and `docs/vastai.md` all document the same boundary.

## Current Budget Snapshot

Last no-spend check: 2026-05-21.

```text
active Vast instances: []
Vast credit: $20.639956
latest viable LongLive2 Hopper offer: H200 x2 offer `28747631` at `$7.896080928126769/hour`
```

Approximate H200 x2 compute cost:

| Alive window | GPU cost estimate |
| ---: | ---: |
| 10 min | ~$1.29 |
| 20 min | ~$2.58 |
| 30 min | ~$3.87 |
| 45 min | ~$5.81 |
| 60 min | ~$7.74 |
| 90 min | ~$11.61 |

Budget conclusion:

1. Current credit is enough for the planned H200 x2 restore validation.
2. The latest preflight selected H200 x2 offer `28747631` at `$7.896080928126769/h`.
3. The planned `20 min` restore-validation window estimates `$2.632027` spend and requires `$2.832027` including the `$0.20` reserve.
4. A same-instance `sp1` vs `sp2` comparison should be decided after the restore validation result.
5. Blackwell NVFP4 follow-up still needs separate approval because it is a different hardware/runtime lane.

## Current Readiness

Ready locally:

1. LongLive2 setup/download/config/report/run scripts exist.
2. `VIDEO_MODEL=longlive2` dispatch exists.
3. Vast `--model longlive2` offer query exists.
4. R2 publish/restore dispatch supports `--model longlive2`.
5. EEG schedules can be compiled into LongLive2 prompt-block folders.
6. NVFP4/Hopper mismatch is rejected early.
7. `bash scripts/check.sh` passed after the latest guard update.
8. `vastai show instances --raw` returned `[]` after the latest check.
9. `VideoDiffusion/run_longlive2_sp_vast_smoke.sh --preflight` now runs the no-spend gate, offer selection, and credit/budget check.
10. The paid wrapper now writes sanitized `selected_offer.json`, `credit_check.json`, `budget_plan.json`, `phase_markers.log`, and `phase_report.json`.
11. The paid wrapper now tries best-effort artifact pullback before teardown even when setup/download/render fails.
12. The paid wrapper now enforces a local max-alive timeout around remote SSH phases.
13. `VideoDiffusion/run_longlive2_sp_benchmark.sh` now provides the same-prompt/same-seed `sp1` vs `sp2` speedup comparison.
14. `VideoDiffusion/download_longlive2_models.sh` now falls back to `huggingface_hub.snapshot_download` through the LongLive2 venv when `hf`/`huggingface-cli` is absent.
15. `VideoDiffusion/run_longlive2_sp_vast_smoke.sh --publish-r2-on-success` can publish the env/cache tuple before teardown after a successful render.
16. `VideoDiffusion/setup_longlive2.sh` now pins `transformers==4.57.3` by default and verifies `transformers.models.x_clip.modeling_x_clip.x_clip_loss` before model download.
17. `VideoDiffusion/setup_longlive2.sh` now installs `decord` as an extra package and verifies it before model download.
18. `VideoDiffusion/download_longlive2_models.sh` now downloads Wan2.2 base assets by default and links them into the upstream `wan_models/Wan2.2-TI2V-5B` path.
19. A paid H200 x2 BF16 SP render succeeded and published the first LongLive2 BF16 SP tuple to R2.
20. `VideoDiffusion/restore_r2_prebuild_model.sh` now recreates the LongLive2 Wan runtime symlink after tuple restore.
21. Local artifact retention is now telemetry-first: historical Scope/LongLive media was pruned, the archive is about `3.1M`, and the only retained media is the tiny LongLive2 H200 x2 proof clip.
22. `scripts/prune_artifacts.py --delete` records SHA-256/size manifests before deleting disposable MP4/PNG/JPG files.

Not ready / not yet proven:

1. The LongLive2 BF16 SP tuple is published to R2 but still needs a fresh restore render after the Wan-link restore patch.
2. The successful render was a cold build/download/render path, not a validated fast restore path.
3. No `sp1` vs `sp2` speedup has been measured.
4. No persistent live LongLive2 EEG runner exists yet.
5. No LongLive2 WebRTC/live-display path exists yet.

This means the first paid milestone is complete for cold BF16 SP render and tuple publication, but the next milestone is fresh restore validation.
The first restore validation proved R2 fetch/extract timing, then exposed a missing Wan symlink in the restore path; the code now patches that boundary, and the current top-up plus preflight make the fixed restore path ready to run after explicit paid-launch approval.

## Detailed Plan From Current State

This is the ordered plan from what we have learned so far.

### A. Keep The Repo Canonical And Cheap

Purpose: avoid losing work or spending while the budget is below the paid threshold.

1. Keep `main` as the working branch, but do not pull/rebase/push blindly while it is ahead/behind `origin/main`.
2. Run only no-spend checks until Vast credit is at least the restore-validation threshold; this is now satisfied for the H200 x2 restore-validation plan.
3. Keep local artifacts in `artifacts/`, not `Downloads`.
4. Keep telemetry and reports; prune historical media after QA with `python3 scripts/prune_artifacts.py --delete`.
5. Before any paid run, confirm `vastai show instances --raw` returns `[]`.

Done when:

1. `bash scripts/check.sh` passes;
2. `git diff --check` passes;
3. `python3 scripts/prune_artifacts.py` reports `candidate_count: 0`;
4. docs and `AGENTS.md` agree on the current run path.

### B. Validate The Published LongLive2 R2 Tuple

Purpose: prove the fast path, not rebuild the world.

The next paid run is a restore-only H200 x2 BF16 SP render:

1. use `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1`;
2. use `bf16_sp`, `sp_size=2`, `dp_size=1`;
3. use `480x832`, `32` frames, `seed=0`;
4. keep `--download-fallback` off;
5. cap max alive around `20 min`;
6. require enough credit for about `$2.50-$3.00` spend plus teardown margin.

This run answers one question:

```text
Can a fresh H200 x2 instance restore the R2 tuple, recreate the Wan symlink, and render without HF downloads or dependency rebuilds?
```

Pass means:

1. tuple restore completes;
2. `VideoDiffusion/.vendors/LongLive2/wan_models/Wan2.2-TI2V-5B` exists after restore;
3. `torchrun` starts two ranks;
4. one output stream is produced;
5. per-GPU telemetry shows both cards were active;
6. local report/log artifacts are pulled back;
7. the instance is destroyed.

Fail means:

1. do not republish the tuple;
2. preserve logs/reports;
3. update this ledger with the exact failure phase;
4. teardown and verify active instances are `[]`.

### C. Measure Whether Two GPUs Actually Help

Purpose: decide whether LongLive2 is worth pursuing for the live art system.

Only run this after the restore-only smoke passes. Use the same host/runtime if possible to avoid another setup tax.

Compare:

1. `sp_size=1`, `dp_size=1`, one rank;
2. `sp_size=2`, `dp_size=1`, two ranks;
3. same prompt, seed, frame count, resolution, and GPU family.

Decision rule:

1. `<1.3x` speedup: stop LongLive2 SP as a live path for now.
2. `1.3x-1.6x`: keep it for offline/research output, not the default live path.
3. `>=1.6x`: design the persistent runner.

Do not start live EEG integration before this benchmark. Without speedup, a two-GPU live runner is extra complexity without enough evidence.

### D. Keep Scope/LongLive As The Live Fallback

Purpose: keep the art project runnable while LongLive2 remains experimental.

The current proven live path is still Daydream Scope + LongLive:

1. B200 x1 proved realtime at `320x576` with synthetic EEG.
2. H200 x1 passed `320x576` and same-instance sweep found `352x576` as the best validated realtime edge.
3. RTX 4090 generated valid output but failed realtime even at low resolution.
4. EEG should continue to drive Scope through OSC while WebRTC owns display.

Operationally:

1. use Scope/LongLive for live demonstrations;
2. use LongLive2 for one-stream multi-GPU research until the speedup benchmark says otherwise;
3. do not describe LongLive2 offline `torchrun` as a live EEG/WebRTC system.

### E. Blackwell/NVFP4 Comes Later

Purpose: avoid repeating the Hopper/NVFP4 mismatch warned about in the paper.

Do not test NVFP4 on H100/H200 as a performance lane.

Blackwell work starts only after one of these is true:

1. BF16 SP shows enough value to justify higher-end experiments;
2. the user explicitly approves a Blackwell budget;
3. a cheap reliable B200/GB200/RTX 50-class offer appears and the run is bounded.

### F. Build Live LongLive2 Only If The Evidence Supports It

The persistent LongLive2 runner is a later engineering project.

It needs:

1. long-lived `torchrun` ranks;
2. a rank-0 control server;
3. stable EEG state events;
4. prompt/block-boundary scheduling;
5. KV/context transition handling;
6. output streaming or low-latency file handoff.

Do not build this until the restore and `sp1`/`sp2` benchmark pass.

## Live Run Ledger

Append one row per meaningful attempt. Keep hostnames, IPs, SSH ports, tokens,
and account identifiers out of this file.

| Date | Phase | Status | GPU / offer | Runtime tag | Cost window | Local artifacts | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-05-21 | planning | ready for no-paid preflight | H200 x2 candidate `28747627` at last scan | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | target `<=45 min` | none yet | credit was about `$9.63`; active instances were `[]`; re-query before spending |
| 2026-05-21 | no-spend validation | pass | none | n/a | `$0` | none | `bash scripts/check.sh` and `git diff --check` passed; `vastai show instances --raw` returned `[]` |
| 2026-05-21 | wrapper preflight | pass | H200 x2 offer `28957790` at `$7.743/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | planned `$5.807` for `45 min` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T224724Z/` | credit `$9.626478`, required `$7.00`, active instances `[]`; no paid instance created |
| 2026-05-21 | wrapper preflight | pass | H200 x2 offer `28957790` at `$7.743/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | planned `$5.807` for `45 min` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T224854Z/` | rerun after final timeout/docs patch; credit `$9.626478`, required `$7.00`, active instances `[]`; no paid instance created |
| 2026-05-21 | paid BF16 SP smoke | fail before render | H200 x2 offer `28957790` at `$7.743/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | observed about `$0.918` over `427s`; planned `$5.807` for `45 min` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T225420Z/` | setup/build reached model download, then failed because no `hf` or `huggingface-cli` binary existed; artifact pullback and teardown succeeded; active instances verified `[]` |
| 2026-05-21 | no-spend patch validation | pass | none | n/a | `$0` | `VideoDiffusion/.tmp/current_vast_credit_after_longlive2_fail.json` | added Python HF fallback plus publish-on-success wrapper path; forced downloader fallback dry-run passed; current credit about `$8.9355`; active instances `[]`; current H200 x2 offers start at `$7.743/h` |
| 2026-05-21 | paid BF16 SP smoke | fail before render | H200 x2 offer `28957790` at `$7.743/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | observed about `$0.667` over `310s`; planned `$7.743` for `60 min` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T230713Z/` | HF model download succeeded through Python fallback; `torchrun` failed importing `x_clip_loss` from `transformers==5.9.0`; artifact pullback and teardown succeeded; active instances verified `0`; current credit about `$8.213` |
| 2026-05-21 | paid BF16 SP smoke | fail before render | H200 x2 offer `28957790` at `$7.743/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | observed about `$0.693` over `322s`; planned `$7.743` for `60 min` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T231513Z/` | `transformers==4.57.3` pin and `x_clip_loss` guard passed; HF model download succeeded; `torchrun` failed because upstream imports `decord` but requirements did not install it; artifact pullback and teardown succeeded; active instances verified `0`; current credit about `$7.544` |
| 2026-05-21 | paid BF16 SP smoke | fail before render | H200 x2 offer `28957790` at `$7.743/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | observed about `$0.895` over `416s`; planned `$5.807` for `45 min` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T232208Z/` | `transformers` and `decord` guards passed; SP initialized with `sp_sizes=[2]`; failed because Wan2.2 base assets were not downloaded/linked; artifact pullback and teardown succeeded; active instances verified `[]`; current credit about `$6.126` |
| 2026-05-21 | paid BF16 SP smoke + R2 publish | pass | H200 x2 offer `28957790` at `$7.743/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | observed about `$3.170` over `1474s`; planned `$5.807` for `45 min` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T233039Z/` | cold setup/download/render succeeded; MP4 is `832x480`, `125` frames, `24 fps`, `5.208s`; SP used both H200s with max `36341 MiB` each; R2 publish succeeded with `3.977 GB` env archive, `44.203 GB` weights archive, and flash-attn wheel; local artifact pullback and teardown succeeded; active instances verified `[]`; current credit after charges about `$2.918` |
| 2026-05-21 | paid BF16 SP restore validation | fail after restore | H200 x2 offer `28957790` at `$7.743/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | observed about `$1.682` over `782s`; planned `$2.323` for `18 min` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T235723Z/` | R2 tuple restore succeeded in `559s`, then `torchrun` failed because restored weights did not recreate the upstream `LongLive2/wan_models/Wan2.2-TI2V-5B` link; patched `restore_r2_prebuild_model.sh` to recreate and require that link; artifact pullback and teardown succeeded; active instances verified `[]`; current credit about `$0.64` |
| 2026-05-21 | wrapper preflight | pass | H200 x2 offer `28747631` at `$7.896080928126769/h` | `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` | planned `$2.632027` for `20 min`; required `$2.832027` with reserve | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260521T110443Z/` | credit `$20.639956`, active instances `[]`, `bash scripts/check.sh` passed, `git diff --check` passed, offline dry-run passed, NVFP4-on-SM90 guard passed, no paid instance created |

## What Changed

Use this section for short operator notes that explain why the plan changed.

- 2026-05-21: Created the root paid-run control plan and expanded it into a live phase-by-phase checklist. Current next action is no-spend preflight, then one controlled BF16 SP paid smoke after explicit go.
- 2026-05-21: Updated `AGENTS.md` to treat this file as the source-of-truth paid-run checklist, then recorded local validation and no-active-instance status.
- 2026-05-21: Added code guardrails before paid launch: wrapper `--preflight`, failure-safe artifact pullback, phase/cost report generation, selected-offer/credit/budget artifacts, max-alive timeout, lower first-smoke geometry, seed plumbing, and a same-seed SP benchmark wrapper.
- 2026-05-21: First paid H200 x2 attempt failed before inference because the remote BF16 venv exposed `huggingface_hub` but no `hf` CLI binary. Patched the downloader to use Python `snapshot_download` fallback and added wrapper `--publish-r2-on-success` so a successful paid setup can publish the tuple before teardown.
- 2026-05-21: Second paid H200 x2 attempt passed setup and HF download, then failed at upstream import time because unbounded `transformers>=4.49.0` resolved to `5.9.0`, which did not expose `x_clip_loss` in the installed module. Pinned default `transformers==4.57.3`, where Hugging Face source still exposes `x_clip_loss`, and added a setup import guard.
- 2026-05-21: Third paid H200 x2 attempt proved the Transformers pin and download path, then failed on missing `decord`. Added `LONGLIVE2_EXTRA_PIP_PACKAGES=decord` default plus a setup import guard.
- 2026-05-21: Fourth paid H200 x2 attempt proved SP initialization and failed at missing Wan2.2 base weights. Changed the LongLive2 downloader and paid wrapper so Wan base assets are included by default and linked into the upstream relative path.
- 2026-05-21: Fifth paid H200 x2 attempt succeeded end-to-end on the cold build/download path, produced a local nonblank `832x480` MP4, published the BF16 SP tuple to R2, pulled artifacts locally, and tore down the instance.
- 2026-05-21: First fresh restore validation restored the R2 tuple in `559s`, then failed because tuple extraction did not recreate LongLive2's vendor-local Wan symlink. Patched `VideoDiffusion/restore_r2_prebuild_model.sh` so future restores link `VideoDiffusion/.cache/longlive2/wan_models/Wan2.2-TI2V-5B` into `VideoDiffusion/.vendors/LongLive2/wan_models/Wan2.2-TI2V-5B`.
- 2026-05-21: Pruned disposable historical Scope/LongLive MP4/PNG/JPG media after QA, reducing local `artifacts/` from `171M` to `3.1M`. Added `scripts/prune_artifacts.py` and updated docs so telemetry/reports/manifests are the durable evidence while media is retained only as explicit proof clips or deliverables.
- 2026-05-21: Expanded the next-step plan into ordered no-spend, restore-validation, `sp1`/`sp2` benchmark, Scope fallback, Blackwell, and later live-runner phases.
- 2026-05-21: User topped up Vast credit to `$20.639956`. The restore-validation preflight selected H200 x2 offer `28747631`, estimated `$2.632027` for the `20 min` cap, required `$2.832027` with reserve, and passed all no-spend gates. The repo is ready for the paid restore-only validation after explicit launch approval.

## Step-By-Step Checklist

### Phase 0: Operator Safety Gate

- [ ] Read `AGENTS.md`, this file, and `docs/video-longlive2-sp-streaming.md`.
- [ ] Confirm the user explicitly approved paid Vast work for this run.
- [ ] Confirm the requested run is LongLive2 BF16 SP, not Scope/LongLive and not MAGI.
- [ ] Confirm the branch state is understood:

```bash
cd /Users/xenochain/Code/neurodiffusion
git status --short --branch
```

- [ ] If the branch is ahead/behind `origin/main`, do not pull, push, or rebase unless that is the requested task.
- [ ] Update the `Live Run Ledger` row with the current date and intended phase.

Pass condition: no ambiguity about paid approval, branch state, or target model.

Fail action: stop before provisioning.

### Phase 1: No-Spend Local Validation

- [ ] Prefer the one-command preflight:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh --preflight
```

- [ ] Confirm preflight writes:
  - `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/<run_id>/selected_offer.json`
  - `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/<run_id>/credit_check.json`
  - `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/<run_id>/budget_plan.json`
  - `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/<run_id>/phase_report.json`

- [ ] Run the repo validation gate:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/check.sh
git diff --check
```

- [ ] Verify no paid instances are already running:

```bash
vastai show instances --raw
```

- [ ] Expected output for the active-instance check is `[]`.
- [ ] If the Vast CLI user/balance command is broken, do not paste credentials into logs. Use the existing local credential path only if needed, and record only the numeric credit.
- [ ] Update the `Live Run Ledger` with validation result and current credit.

Pass condition: checks pass and active instances are `[]`.

Fail action: fix local code/docs/checks first, or terminate unrelated paid instances only if they are known to belong to this workflow and the user has authorized cleanup.

### Phase 2: Offline LongLive2 Dry Run

- [ ] Generate an offline plan without GPU spending:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_offline.sh \
  --dry-run \
  --run-dir VideoDiffusion/.tmp/longlive2_dryrun_test \
  --frames 16 \
  --shot-prompt "A calm luminous ocean breathes slowly." \
  --shot-prompt "A frantic neon tunnel accelerates." \
  --shot-duration 1 \
  --shot-duration 1
```

- [ ] Confirm these files exist:
  - `VideoDiffusion/.tmp/longlive2_dryrun_test/longlive2_inference.yaml`
  - `VideoDiffusion/.tmp/longlive2_dryrun_test/prompt_schedule/`
  - `VideoDiffusion/.tmp/longlive2_dryrun_test/launch_plan.json`
- [ ] Inspect the launch plan and confirm it uses `torchrun --nproc_per_node=2`.
- [ ] Confirm the plan uses `sp_size=2` and `dp_size=1`.
- [ ] Confirm prompt-block generation works for multiple shots.
- [ ] Update the `Live Run Ledger` if dry-run behavior changed.

Pass condition: dry-run artifacts are deterministic and the launch command is a two-rank SP run.

Fail action: fix `VideoDiffusion/run_longlive2_sp_offline.sh` or `VideoDiffusion/longlive2_config.py` before paid work.

### Phase 3: Hardware-Lane Guard Check

- [ ] Confirm default paid wrapper plan:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh --dry-run
```

- [ ] Confirm NVFP4 is rejected on a non-Blackwell runtime tag:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --dry-run \
  --profile nvfp4_s2 \
  --runtime-tag longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm90_prebuild1
```

- [ ] Expected result: fail early with a Blackwell-only NVFP4 warning.
- [ ] Confirm a Blackwell NVFP4 dry-run is allowed only with an SM100-style runtime tag and Blackwell GPU regex.
- [ ] Update this file if the script guard behavior changes.

Pass condition: H100/H200 cannot accidentally launch NVFP4.

Fail action: patch `VideoDiffusion/run_longlive2_sp_vast_smoke.sh` before spending.

### Phase 4: Offer Query And Budget Gate

- [ ] Re-query offers immediately before launch:

```bash
cd /Users/xenochain/Code/neurodiffusion
python3 scripts/vast/query_video_offers.py \
  --model longlive2 \
  --gpu-name-regex 'H100|H200|GH200' \
  --out-json VideoDiffusion/.tmp/current_longlive2_hopper_offer_scan.json \
  --out-csv VideoDiffusion/.tmp/current_longlive2_hopper_offer_scan.csv
```

- [ ] Select deterministically:

```bash
cd /Users/xenochain/Code/neurodiffusion
python3 scripts/vast/select_video_offer.py \
  --scan-json VideoDiffusion/.tmp/current_longlive2_hopper_offer_scan.json \
  --selection-goal cost \
  --min-gpu-count 2 \
  --max-gpu-count 2 \
  --runtime-tag longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1 \
  --print-env
```

- [ ] Record selected offer id, GPU model, GPU count, listed hourly rate, reliability, CUDA version, and machine id in the `Live Run Ledger`.
- [ ] Confirm selected offer has exactly two usable GPUs.
- [ ] Confirm selected offer is at or below `$8.00/hour` unless the user explicitly approved a higher cap.
- [ ] Estimate cost before launch:

```text
estimated_cost = hourly_rate_usd * expected_minutes / 60
```

- [ ] Confirm current Vast credit leaves enough room for the planned window plus teardown margin.
- [ ] If running patched restore validation, require about `$2.50-$3.00` available for an `18-20 min` cap.
- [ ] If running a cold build/publish rerun, require about `$7.00+` available.
- [ ] If the best two-card Hopper offer is above `$8.00/hour`, stop or ask for a new cap.

Pass condition: a two-GPU H100/H200/GH200 offer fits the budget window.

Fail action: do not provision; update the ledger with the cheapest viable offer and reason for stopping.

### Phase 5: Cold Build/Publish BF16 SP Smoke

- [ ] Launch only after Phases 0-4 pass:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --min-gpu-count 2 \
  --max-gpu-count 2 \
  --max-dph 8.00 \
  --profile bf16_sp \
  --height 480 \
  --width 832 \
  --frames 32 \
  --sp-size 2 \
  --dp-size 1 \
  --seed 0 \
  --max-alive-min 60 \
  --budget-estimate-min 60 \
  --min-credit-usd 8.00 \
  --min-credit-reserve-usd 0.50 \
  --max-estimated-spend-usd 8.00 \
  --no-restore \
  --download-fallback \
  --publish-r2-on-success
```

- [ ] Start a timer as soon as the instance is created.
- [ ] Record instance creation time in local notes or the ledger without host/IP details.
- [ ] Watch for these phase markers or equivalent logs:
  - instance provisioned;
  - SSH resolved;
  - repo synced;
  - LongLive2 setup started;
  - model download/cache started;
  - `torchrun` started;
  - rank 0 output path created;
  - artifact pullback started;
  - teardown started.
- [ ] Cut the run if setup/build is clearly stuck.
- [ ] Cut the run if no render path is reached by roughly minute `35-45`.
- [ ] Do not switch to NVFP4 on H200.
- [ ] Do not keep the instance alive just to preserve a loaded process.

Pass condition: wrapper reaches `torchrun`, completes or fails with actionable logs, pulls artifacts when present, and tears down.

Fail action: preserve logs locally, tear down, update this file and `docs/video-longlive2-sp-streaming.md` with the failure mode.

### Phase 6: Runtime Telemetry To Capture

- [ ] Record total alive time.
- [ ] Record setup/build time.
- [ ] Record model download/cache time.
- [ ] Record model load time if available.
- [ ] Record render wall-clock time.
- [ ] Record frames generated.
- [ ] Record effective FPS.
- [ ] Record first-output latency if available.
- [ ] Record GPU utilization for both GPUs.
- [ ] Record VRAM usage for both GPUs.
- [ ] Record whether logs prove `sp_size=2`.
- [ ] Record whether exactly one MP4/output stream was produced.
- [ ] Record final local artifact directory.
- [ ] Preserve `phase_report.json`, `selected_offer.json`, `credit_check.json`, and `budget_plan.json` with the rest of the artifacts.

Telemetry table to fill after the run:

| Field | Value |
| --- | --- |
| run id | TBD |
| instance alive minutes | TBD |
| hourly rate | TBD |
| estimated spend | TBD |
| GPU model/count | TBD |
| runtime tag | TBD |
| profile | `bf16_sp` |
| frames | `32` |
| resolution | TBD |
| sp_size / dp_size | `2 / 1` |
| setup/build seconds | TBD |
| download/cache seconds | TBD |
| model-load seconds | TBD |
| render seconds | TBD |
| effective fps | TBD |
| first-output seconds | TBD |
| max VRAM GPU0/GPU1 | TBD |
| average utilization GPU0/GPU1 | TBD |
| output MP4 path | TBD |
| local artifact path | TBD |
| teardown verified | TBD |

### Phase 7: Local Artifact Pullback And QA

- [ ] Confirm the wrapper pulled artifacts to `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/<run_id>/` or another explicit local directory.
- [ ] Confirm local artifacts include:
  - MP4 or failure logs;
  - config;
  - launch plan;
  - rank logs;
  - telemetry;
  - `run_report.json` or equivalent report.
- [ ] If an MP4 exists, run media inspection:

```bash
ffprobe -v error -show_format -show_streams /absolute/path/to/output.mp4
```

- [ ] If an MP4 exists, sample frames/contact sheet using the existing report tooling where available.
- [ ] Open at least one sampled frame locally and check whether it is nonblank and visually plausible.
- [ ] If the output is static, corrupted, blank, or only a loading/error screen, mark the smoke as failed even if the process exited `0`.
- [ ] After QA and docs updates, run `python3 scripts/prune_artifacts.py --delete` unless the MP4 is intentionally retained as a proof clip or deliverable.
- [ ] Update `docs/video-longlive2-sp-streaming.md` with the artifact paths and QA result.
- [ ] Update this file's `Live Run Ledger` and telemetry table.

Pass condition: artifacts are local, inspectable, and sufficient to explain success/failure.

Fail action: do not publish a tuple; document the failure and teardown status.

### Phase 8: Teardown Verification

- [ ] Verify there are no active paid instances:

```bash
vastai show instances --raw
```

- [ ] Expected output is `[]`.
- [ ] If output is not `[]`, terminate only the instance(s) created for this workflow:

```bash
bash scripts/vast/terminate_instance.sh <INSTANCE_ID>
vastai show instances --raw
```

- [ ] Record teardown status in the `Live Run Ledger`.
- [ ] Final handoff must explicitly say whether teardown succeeded.

Pass condition: `vastai show instances --raw` returns `[]`.

Fail action: keep working until the paid instance is stopped, unless the user explicitly asks to keep it running.

### Phase 9: Documentation Sync

- [ ] Update this file with:
  - final ledger row;
  - telemetry table values;
  - pass/fail verdict;
  - exact local artifact directory;
  - next recommended step.
- [ ] Update `docs/video-longlive2-sp-streaming.md` with empirical results, failures, and any script behavior changes.
- [ ] Update `docs/vastai.md` if provisioning, SSH, lifecycle, or wrapper behavior changed.
- [ ] Update `docs/accelerate.md` if runtime tuple, cache, R2, NVFP4, or SP strategy changed.
- [ ] Update `docs/cloudflare-r2.md` if a tuple was published or restore/publish layout changed.
- [ ] Update `docs/budget-analysis.md` with actual spend and measured cost per output second.
- [ ] Update `AGENTS.md` only if operator rules changed.
- [ ] Run `bash scripts/check.sh` after doc/code changes.

Pass condition: docs agree with code and with actual telemetry.

Fail action: do not call the run complete until source-of-truth docs are synchronized.

### Phase 10: Optional SP Benchmark

Run this only if the first smoke succeeds quickly enough and budget remains.

- [ ] Use the same-instance benchmark wrapper when already attached to a prepared LongLive2 runtime:

```bash
cd /workspace/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_benchmark.sh \
  --profile bf16_sp \
  --height 480 \
  --width 832 \
  --frames 32 \
  --seed 0 \
  --prompt "A reactive neon tunnel breathes with smooth cinematic motion."
```

- [ ] Keep model, prompt, seed, resolution, frame count, GPU family, and runtime tag fixed.
- [ ] Run baseline `sp_size=1`, `dp_size=1`, `nproc=1`.
- [ ] Run target `sp_size=2`, `dp_size=1`, `nproc=2`.
- [ ] Compute:

```text
speedup = fps_sp2 / fps_sp1
```

- [ ] Apply the decision gate:
  - `<1.3x`: stop LongLive2 SP as a live path for now.
  - `1.3x-1.6x`: keep as research/offline candidate.
  - `>=1.6x`: proceed to persistent-runner design.
- [ ] Update this file, `docs/video-longlive2-sp-streaming.md`, `docs/accelerate.md`, and `docs/budget-analysis.md`.

### Phase 11: Optional R2 Publish

Do this only after a successful render and artifact QA.

Publishing is not the same as restore validation:

1. `published_tuple`: env/cache/checkpoints were uploaded after a successful render.
2. `validated_restore_tuple`: a fresh instance restored that tuple and produced a new render.

- [ ] Confirm the run produced a usable LongLive2 output.
- [ ] Confirm setup/build/model-cache artifacts are worth preserving.
- [ ] Publish:

```bash
R2_PREFIX=neurodiffusion \
bash VideoDiffusion/publish_r2_prebuild_model.sh \
  --model longlive2 \
  --runtime-tag longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1 \
  --tiers longlive2-bf16-sp-hopper \
  --include-weights \
  --weights-compression none
```

- [ ] Confirm publish manifest exists.
- [ ] Update `docs/cloudflare-r2.md`, `docs/accelerate.md`, and this file with the exact tuple tag and restore command.
- [ ] Do not claim R2 preserves a live loaded model. It preserves env/cache/checkpoint artifacts only.

## No-Paid Preflight

Run before spending:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/check.sh
git diff --check
vastai show instances --raw
```

Generate and inspect a LongLive2 dry run:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_offline.sh \
  --dry-run \
  --run-dir VideoDiffusion/.tmp/longlive2_dryrun_test \
  --frames 16 \
  --shot-prompt "A calm luminous ocean breathes slowly." \
  --shot-prompt "A frantic neon tunnel accelerates." \
  --shot-duration 1 \
  --shot-duration 1
```

Check that this writes:

1. `VideoDiffusion/.tmp/longlive2_dryrun_test/longlive2_inference.yaml`
2. `VideoDiffusion/.tmp/longlive2_dryrun_test/prompt_schedule/`
3. `VideoDiffusion/.tmp/longlive2_dryrun_test/launch_plan.json`
4. a `torchrun --nproc_per_node=2 inference_sp.py` command.

Confirm the paid wrapper plan:

```bash
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh --dry-run
```

Confirm the guard rejects the wrong hardware lane:

```bash
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --dry-run \
  --profile nvfp4_s2 \
  --runtime-tag longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm90_prebuild1
```

Expected result: fail early with a Blackwell-only NVFP4 warning.

## Offer Selection

No-spend query:

```bash
cd /Users/xenochain/Code/neurodiffusion
python3 scripts/vast/query_video_offers.py \
  --model longlive2 \
  --gpu-name-regex 'H100|H200|GH200' \
  --out-json VideoDiffusion/.tmp/current_longlive2_hopper_offer_scan.json \
  --out-csv VideoDiffusion/.tmp/current_longlive2_hopper_offer_scan.csv
```

No-spend deterministic selection:

```bash
python3 scripts/vast/select_video_offer.py \
  --scan-json VideoDiffusion/.tmp/current_longlive2_hopper_offer_scan.json \
  --selection-goal cost \
  --min-gpu-count 2 \
  --max-gpu-count 2 \
  --runtime-tag longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1 \
  --print-env
```

Current last-selected candidate:

```text
offer_id: 28957790
gpu: H200 x2
hourly_rate_usd: about 7.7433
gpu_ram: about 143 GB per GPU
cuda_max_good: 12.8
```

Re-query immediately before launch because Vast offers are dynamic.

## Cold Build/Publish Run: Controlled BF16 SP Smoke

This path is already proven by `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T233039Z/`.
Use it only after explicit approval to spend when deliberately replacing or rebuilding the tuple.

Use the build/download fallback path:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --min-gpu-count 2 \
  --max-gpu-count 2 \
  --max-dph 8.00 \
  --profile bf16_sp \
  --height 480 \
  --width 832 \
  --frames 32 \
  --sp-size 2 \
  --dp-size 1 \
  --seed 0 \
  --max-alive-min 60 \
  --budget-estimate-min 60 \
  --min-credit-usd 8.00 \
  --min-credit-reserve-usd 0.50 \
  --max-estimated-spend-usd 8.00 \
  --no-restore \
  --download-fallback \
  --publish-r2-on-success
```

Why `frames 32` first:

1. It is large enough to prove config, ranks, load, and save path.
2. It limits render time while the environment is unproven.
3. If this succeeds quickly, rerun with `--frames 128` on the same instance pattern or a later restored tuple.

Hard budget discipline:

1. Abort if setup/build is clearly stuck.
2. Abort if no render path is reached by roughly minute `35-45`.
3. Do not chase NVFP4 on H200.
4. Do not keep the instance alive to preserve a loaded process.
5. Pull artifacts before teardown.

Expected wrapper behavior:

1. select/provision paid Vast instance;
2. resolve SSH;
3. sync repo;
4. clone/build LongLive2;
5. download needed model artifacts;
6. run `torchrun` through `run_longlive2_sp_offline.sh`;
7. pull artifacts to `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/<run_id>/`;
8. teardown by default.

## Next Paid Run: Patched Restore Validation

Use this after enough credit is available.
Do not pass `--download-fallback`; this run should prove that R2 restore plus the LongLive2 Wan-link hook is sufficient.

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --min-gpu-count 2 \
  --max-gpu-count 2 \
  --max-dph 8.00 \
  --profile bf16_sp \
  --height 480 \
  --width 832 \
  --frames 32 \
  --sp-size 2 \
  --dp-size 1 \
  --seed 0 \
  --max-alive-min 20 \
  --budget-estimate-min 20 \
  --min-credit-usd 2.70 \
  --min-credit-reserve-usd 0.20 \
  --max-estimated-spend-usd 3.00
```

Expected restore behavior:

1. clone LongLive2 with `--skip-build`;
2. restore `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` from R2;
3. restore script recreates `VideoDiffusion/.vendors/LongLive2/wan_models/Wan2.2-TI2V-5B`;
4. `torchrun` renders the short SP smoke without HF downloads or dependency builds;
5. local artifact pullback and teardown still happen by default.

## Acceptance Criteria For First Smoke

A first smoke passes only if all are true:

1. `torchrun` starts two ranks.
2. logs show SP/Ulysses mode with effective `sp_size=2`.
3. both GPUs have nontrivial utilization in telemetry.
4. exactly one output MP4 stream is written.
5. the MP4, config, logs, telemetry, and report are pulled to the local machine.
6. report includes `ffprobe` metadata when local media tools can inspect it.
7. sampled frame/contact sheet is generated and inspected when output is available; it may be pruned after QA if the report records the result.
8. `vastai show instances --raw` returns `[]` after teardown.

## Second Paid Step: Decisive SP Benchmark

Only run this if first smoke succeeds fast enough.

Compare:

```text
same prompt
same seed
same resolution
same frame count
same GPU family

A: sp_size=1, dp_size=1, nproc=1
B: sp_size=2, dp_size=1, nproc=2
```

Record:

1. wall-clock setup time;
2. model load time;
3. render wall-clock;
4. frames/sec;
5. first output time if available;
6. GPU utilization and VRAM;
7. MP4 duration/resolution/frame count;
8. contact sheet quality;
9. cost per generated second;
10. cost per realtime frame.

Decision:

1. `<1.3x`: stop LongLive2 SP as a live path for now.
2. `1.3x-1.6x`: keep as research/offline candidate.
3. `>=1.6x`: proceed to persistent-runner design.

## R2 Publish Rule

Publish a LongLive2 tuple only after a successful render.

Do not mark that tuple as validated until a later fresh restore run proves it
can restore and render. The states are separate:

1. `published_tuple`: env/cache/checkpoints were uploaded after a successful render.
2. `validated_restore_tuple`: a fresh instance restored the tuple and produced a new render.

Persist:

1. Python env archive;
2. built extensions;
3. wheel/cache artifacts;
4. model/checkpoint cache;
5. manifest;
6. smoke report.

Do not publish a canonical tuple from a failed build or import-only state.

Suggested publish shape after a successful BF16 SP render:

```bash
R2_PREFIX=neurodiffusion \
bash VideoDiffusion/publish_r2_prebuild_model.sh \
  --model longlive2 \
  --runtime-tag longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1 \
  --tiers longlive2-bf16-sp-hopper \
  --include-weights \
  --weights-compression none
```

## Later Blackwell NVFP4 Lane

Do this only after BF16 SP is proven, or after explicit approval to target Blackwell directly.

```bash
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'B200|GB200|RTX.?5090' \
  --runtime-tag longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm100_prebuild1 \
  --profile nvfp4_s2 \
  --frames 384
```

This is not the current budget-safe next step.

## Live EEG Runner Comes Later

Do not build a persistent LongLive2 live runner until the SP benchmark justifies it.

Future live architecture:

```text
torchrun starts persistent ranks
rank 0 owns local control server
all ranks keep LongLive2 loaded
EEG loop sends stable state events
rank 0 schedules prompt change at block boundary
ranks synchronize prompt/context update
KV-recache-style transition handles prompt change
rank 0 streams/saves output
```

The current live fallback remains Scope + LongLive because it already has OSC and WebRTC.

## Ready-To-Run Checklist

Before saying "go", confirm:

1. `git status` is understood. Current local branch may be ahead/behind `origin/main`; do not push blindly.
2. `bash scripts/check.sh` passes.
3. `bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh --preflight` passes.
4. `vastai show instances --raw` returns `[]`.
5. Vast credit is enough for the intended phase: about `$2.50-$3.00` for one tight H200 x2 restore validation, or `$7.00+` for a cold build/publish rerun.
6. a fresh H100/H200 x2 offer query finds an offer at `<= $8.00/h`.
7. the run uses `bf16_sp`, not NVFP4, on H100/H200.
8. the next validation uses restore with no HF download fallback; use `--no-restore --download-fallback` only when deliberately rebuilding or replacing the tuple.
9. the run uses explicit modest first-smoke geometry, currently `480x832` and `32` frames.
10. the wrapper max-alive/budget guards are enabled and the operator watches for obvious stuck setup.
11. artifact retention is telemetry-first: prune disposable media after QA and keep only reports/logs/manifests plus intentional proof clips.

If those conditions hold, the repo is ready for the patched restore validation run.
