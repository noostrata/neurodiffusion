# Acceleration Playbook

_Last updated: 2026-05-15_

This is the canonical performance strategy for this repository.

Policy decision for this repo:

1. MAGI-1 keeps the Hopper-first acceleration path (MagiAttention expected in the prebuilt stack).
2. Krea uses a tiered backend path:
   - `B200 -> flash-attn`
   - `H100/H200/GH200/L40S/RTX-Ada/RTX5xxx -> SageAttention`
   - fallback: `sdpa`
3. Scope/LongLive is the first realtime EEG validation path. B200 has validated the control path; RTX 4090 did not hold realtime at `320x576`.
4. Vast + Cloudflare R2 is the current provider/storage architecture; Prime references below are legacy context unless explicitly revived.

## Scope / LongLive acceleration policy

Scope is upstream-owned, but this repo may apply small operator patches at checkout time when they are required for headless validation.
The repo accelerates Scope runs by making startup deterministic:

1. clone/build with `VideoDiffusion/setup_scope.sh`;
2. apply repo patches from `VideoDiffusion/patches/daydream-scope/` unless `SCOPE_APPLY_PATCHES=0`;
3. place Scope models/logs/plugins under ignored `VideoDiffusion/.cache/daydream-scope/` paths unless overridden;
4. download LongLive with `VideoDiffusion/download_scope_models.sh`, which now uses the repo deterministic downloader for LongLive;
5. start Scope with `SCOPE_AUTO_LOAD=0` to avoid accidental VACE auto-load;
6. use `VideoDiffusion/load_scope_longlive.sh` for deterministic no-VACE pipeline load parameters;
7. use OSC from the EEG loop for prompt/runtime updates instead of embedding WebRTC in the EEG process.

Validated B200 tuple:

| Field | Value |
| --- | --- |
| Runtime tag | `scope_auto_py312_torch2.9.1_cu128_sm100` |
| GPU | B200 / SM100 |
| Env archive | `4484945914 bytes` |
| Weights archive | `13718035301 bytes` |
| Validation | `24.868 fps` over 90s WebRTC receive with synthetic EEG |

Restore order for a fast next boot:

1. clone repo on the Vast host;
2. run `SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh` to clone Scope and apply patches;
3. restore `scope_auto_py312_torch2.9.1_cu128_sm100` with `VideoDiffusion/restore_r2_prebuild_model.sh --model scope --apply-weights-target VideoDiffusion/.cache/daydream-scope`;
4. start with `SCOPE_AUTO_LOAD=0`;
5. load LongLive explicitly with `SCOPE_VACE_ENABLED=false`.

For a single paid validation, `VideoDiffusion/run_scope_longlive_vast_smoke.sh --create-instance` automates that sequence plus offer selection, WebRTC capture, synthetic EEG control, local artifact pullback, `run_report.json`, artifact QA, and teardown.
For same-GPU resolution edge-finding, use `VideoDiffusion/run_scope_longlive_vast_sweep.sh --create-instance`; it restores once, starts Scope once, reloads LongLive for each resolution, and writes `sweep_report.{json,md}`.
For cross-GPU paid validation, use `VideoDiffusion/run_scope_longlive_vast_matrix.sh --create-instance`; it wraps the smoke path with fresh offer retries, GPU tier sequencing, adaptive resolution probes, budget/time/credit guards, and aggregate reports.

Prebuild boundary:

1. R2 can persist the Scope uv env, dependency metadata, and LongLive/Wan model cache.
2. R2 cannot persist a live GPU-resident loaded model; every fresh instance still needs a server start and explicit pipeline load.
3. The validated B200 path reduced next boot work to source checkout/patch, tuple restore, server start, and load.

Current publish controls:

1. The Scope venv is uv-managed and may not have `pip`; publish falls back to `uv pip freeze`.
2. `VideoDiffusion/publish_r2_prebuild_model.sh` supports `--env-compression gzip|zstd|none` and `--weights-compression gzip|zstd|none`.
3. For Scope/LongLive, use gzip or zstd for the env archive and `--weights-compression none` for fastest large model-cache publish when R2 storage cost is less important than startup iteration time.

Next cross-GPU validation should optimize for low hourly burn but still include the known-good fallback:

1. `RTX 5090 32GB` if available and reliable;
2. `L40S` / `RTX 6000 Ada` for more memory headroom;
3. H100/H200/GH200 if cheap-mid cards fail the realtime acceptance gate;
4. B200 as the known-good fallback and the tier to test `368x640` / `480x832` if budget remains.

Latest cheap-GPU result:

1. `RTX 4090 x1` generated coherent output at `320x576`.
2. It only received `11.310 fps`, with first frame at `2.480s`.
3. A later `256x448` 4090 matrix probe still failed realtime at `12.912 fps`, first frame `4.693s`.
4. Treat 4090 as a protocol/quality-check tier for this profile, not a default realtime tier.

Latest H200 matrix result:

1. `H200` passed `320x576` at `25.376 fps`, first frame `1.338s`.
2. `H200` failed `368x640` at `20.835 fps`.
3. `H200` failed `480x832` at `12.171 fps`.
4. Effective throughput was stable at about `4.8-4.9 MPix/s`, so a `24 fps` realtime target should stay near `<=200k px/frame`.
5. The next acceleration target is same-instance resolution sweeping, because each fresh instance currently spends roughly `8-13 min` in cold setup/restore/load/pullback around a `30s` benchmark.

Current H200 edge probes:

| Resolution | Pixels | Expected status from model |
| --- | ---: | --- |
| `320x576` | `184,320` | proven realtime |
| `336x592` | `198,912` | edge candidate |
| `352x576` | `202,752` | edge candidate |
| `368x640` | `235,520` | measured below realtime |
| `480x832` | `399,360` | measured about half realtime |

## 1) Why this policy

Upstream MAGI and MagiAttention docs point to Hopper as the fast path:

- MAGI model-zoo guidance uses `H100/H800` for 24B-class fast paths.
- MAGI also documents a `4.5B` path on `RTX4090 x1`; this repo still standardizes on Hopper for one prebuilt high-throughput stack.
- MAGI install docs recommend MagiAttention for Hopper.
- MagiAttention docs explicitly mark Hopper-only support and note source build can take ~20-30 minutes.

So the optimization target is not generic GPU portability; it is fastest repeated startup and throughput on Hopper.

## 2) Source-backed requirements (must-have)

### MAGI-1 baseline

From upstream MAGI README:

1. Docker-based deployment is recommended for environment setup.
2. Source setup example pins `python==3.10.12`, `torch==2.4.0`, `CUDA 12.4`.

### MagiAttention baseline

From MagiAttention README:

1. Recommended for MAGI users on Hopper (`H100/H800`) and improves inference speed.
2. Current support note says only Hopper architecture.
3. Build can take around 20-30 minutes (one-time if done in image build).

### FlashAttention baseline

From FlashAttention README:

1. Requires `CUDA >= 12.0` and `PyTorch >= 2.2`.
2. Recommended install command is `pip install flash-attn --no-build-isolation`.
3. Authors recommend NVIDIA PyTorch container for environment stability.
4. `MAX_JOBS` is supported to control compile resource usage.

### Prime custom template baseline

From Prime CLI/API docs:

1. Pod create supports `--image custom_template --custom-template-id <id>`.
2. API create payload uses `image: "custom_template"` with `customTemplateId`.
3. Not every template is compatible with every availability; must check at create time.

### Prime disk billing baseline

From Prime disk docs:

1. Managed disk exists independently of pod lifecycle.
2. Disk billing continues while disk exists, even when no pod is attached.

### Cloudflare R2 baseline

From Cloudflare docs:

1. R2 is S3-compatible (easy tooling integration).
2. R2 pricing model is storage + operations; egress is free.

## 3) Canonical architecture (fastest practical)

### Layer A: Prime custom template image (golden runtime)

Build and maintain a single Hopper-focused image containing:

1. CUDA-compatible Python/torch runtime.
2. MAGI checkout + pinned requirements.
3. MagiAttention prebuilt.
4. FlashAttention prebuilt for Hopper tuple(s).
5. Runtime user/SSH setup required by Prime pod lifecycle.

### Layer B: R2 cache + artifact fabric

R2 stores durable objects:

1. `neurodiffusion/wheelhouse/` (wheels by runtime tuple)
2. `neurodiffusion/env-cache/` (optional packed env/caches)
3. `neurodiffusion/weights/` (optional staged model assets)
4. `neurodiffusion/runs/<run_id>/` (video + JSON/CSV/logs)

### Layer C: pod-local fast workspace

On each run:

1. provision from custom template
2. restore only missing deltas from R2
3. run workload
4. sync outputs to R2
5. terminate pod

## 4) Most aggressive best-case path (what you asked for)

This is the max-speed configuration and should be treated as the target state.

## 4.1 Build-time (done once per runtime tuple)

1. Start from NVIDIA PyTorch container family (as FlashAttention recommends).
2. Pin exact runtime tuple:
   - Python version
   - torch version
   - CUDA version
   - GPU arch target (`sm90`)
3. Install MAGI dependencies.
4. Build/install MagiAttention in image.
5. Build/install FlashAttention in image.
6. Pre-warm Python import graph and kernel caches where possible.
7. Push image to registry and bind Prime custom template.

Tuple examples:

- `py310_torch2.4.0_cu124_sm90`
- if runtime changes, create a new tuple tag; do not mutate old one.

## 4.2 Asset staging

1. Prestage MAGI assets to R2 (or managed disk if repeated same-region workloads justify continuous disk cost).
2. Keep deterministic asset manifest in repo docs.
3. Validate checksums/hashes before marking tuple as production.
4. For MAGI tuple publish, avoid symlink-only weight roots:
   - `download_weights.sh` normalizes `MAGI-1/downloads/` with symlinks.
   - publish from real-file root (recommended: `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/.`).

Repo implementation hooks:

1. Publish tuple artifacts:
   - `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/. bash VideoDiffusion/publish_r2_prebuild.sh --runtime-tag <runtime_tag> --tiers 4.5b,24b --include-weights --allow-missing-image`
2. Restore tuple artifacts:
   - `bash VideoDiffusion/restore_r2_prebuild.sh --mode auto --runtime-tag <runtime_tag> --tier 4.5b --apply-venv-target <venv_path> --apply-weights-target <magi_dir>`
3. Underlying object operations:
   - `python3 scripts/cloudflare/prebuild_bundle.py publish|fetch ...`
4. Publish code + runtime assets in one command:
   - `bash scripts/cloudflare/publish_everything_r2.sh --runtime-tag <runtime_tag> --tiers 4.5b,24b --include-weights --include-image`

## 4.3 Run-time boot (target behavior)

1. Prime pod create from template.
2. No kernel compilation during run startup.
3. No heavy `pip` dependency solve at startup.
4. Only lightweight sync from R2 (scripts/schedules/latest manifests).
5. Immediate smoke render, then full run.

## 4.4 Failure fallback order

1. Template wheel install fallback from R2.
2. Wheel miss -> constrained source build (last resort).
3. Upload newly successful wheels to R2 and mark tuple metadata.

## 4.5 What to prebuild exactly

Minimum prebuild set for this repo:

1. MagiAttention (Hopper path).
2. FlashAttention (Hopper path).
3. All Python deps from MAGI requirements.
4. ffmpeg + media validation tools.
5. Runtime helper tooling (`prime` client optional in image, ssh/scp deps, jq).

## 4.6 Operational guarantees we want

Target contract:

1. no compile at startup
2. deterministic startup script time
3. deterministic dependency versions
4. deterministic pullback/upload paths

## 5) Storage decision: Prime vs R2

Use both, but for different jobs:

1. Prime pod disk:
   - active runtime scratch
   - shortest retention
2. Prime managed disk:
   - optional hot dataset cache when runs are frequent enough to justify always-on disk billing
3. Cloudflare R2:
   - canonical long-term store for caches and outputs
   - better for durable archive and cross-pod portability

Canonical cost comparison for this decision:

- `docs/budget-analysis.md`

## 6) Docker location strategy

For Prime custom template flow, use an OCI registry Prime can access with credentials/template tooling.

Cloudflare notes:

1. Cloudflare documents container image management and R2 object storage.
2. Prime docs explicitly document custom-template provisioning and image accessibility checks.
3. This repo now supports R2-stored OCI tar artifacts as an optional restore path (`restore_r2_prebuild.sh --mode image`), while template registry compatibility still depends on Prime provider support.

Practical recommendation for this repo:

1. keep runtime image in Docker Hub/GHCR/ECR-compatible flow validated by Prime template tooling
2. keep data/caches/artifacts in R2
3. optionally keep a compressed runtime OCI tar in R2 and load it on pod boot for fast fallback.

Treat “OCI directly on Cloudflare-only stack for Prime GPU pull path” as optional R&D, not default.

## 7) Speed estimates (repo planning values)

These are empirical planning estimates from local repo runs, not vendor guarantees.

Baseline fresh pod (runtime installs + possible source build):

- `25-70 min` to first reliable output

Hopper custom template only:

- `6-15 min`
- typical speedup: `~3x to ~6x`

Hopper custom template + R2 cache/artifacts:

- `3-10 min`
- typical speedup: `~4x to ~8x`

Most aggressive best-case (all prebuilt + warm assets + zero compile on boot):

- `2-6 min`
- can exceed `8x` in favorable runs

Hard lower bound remains:

1. pod provisioning/activation latency
2. image pull/start latency
3. first inference warmup

Latest live MAGI finding (`2026-02-18`, non-template fallback, `A100 80GB x1`, `384x384`, `8` steps):

1. Functional prompt injection is confirmed, but one-GPU steady-state remained around `~6s/chunk` (`p90`), far from near-real-time.
2. Same low-cost profile is now validated to produce full-length one-shot output (`30.0s`, `720` frames) for quality checks.
3. Practical implication: keep one-GPU for cheap validation/render checks only; use multi-GPU tiers for responsiveness goals.
4. Restore/bootstrap path is now more robust on fresh pods (`boto3` + missing `python3-venv` fallback handled automatically).

Latest Vast MAGI finding (`2026-05-14`, `H200 x1`, restored `sm80` tuple):

1. Restore speed path worked: R2 env archive and weights archive fetched/extracted successfully.
2. The restored venv was not fully relocatable because console scripts retained old absolute shebangs; `restore_r2_prebuild.sh` now repairs those scripts after extraction.
3. The `hopper_sm80_py310_torch240_cu124_20260217_prebuild1` tuple is not Hopper-compatible despite the historical prefix. On H200, MAGI reached DiT load and then failed in VAE decode with `no kernel image is available for execution on the device`.
4. Fast path policy: route the current `sm80` tuple to A100-class hosts only, or publish a true `sm90` tuple before selecting H100/H200.
5. `VideoDiffusion/run_magi_vast_smoke.sh` is the preferred attach-mode smoke wrapper because it enforces runtime/GPU compatibility before spending time on restore.

Follow-up Vast MAGI finding (`2026-05-14`, `A100-SXM4-40GB`, restored `sm80` tuple):

1. Architecture match worked: the run avoided the H200 `no kernel image` failure.
2. R2 tuple restore and venv shebang repair worked (`40` console scripts repaired).
3. The fresh Vast image lacked Python dev headers, so Triton failed compiling `cuda_utils` with `Python.h: No such file or directory`.
4. Fast path policy: install minimal system deps before smoke even when restoring a full venv, because Triton/flash-attn can still JIT small helpers at first inference.

Latest live Krea finding (`2026-02-18`, `B200 180GB x1`, flash source-build attempt):

1. `flash-attn==2.7.4.post1` has no matching prebuilt wheel for this tuple, so source build is required.
2. Source build on fresh pods requires Python headers/toolchain (`python3.11-dev`, `ninja-build`); setup now auto-installs these when `FLASH_ATTN_ALLOW_SOURCE_BUILD=1`.
3. Provider-side pod termination interrupted long flash source builds in observed B200 runs; keep `H100/H200/GH200 + SageAttention` as the practical default while validating stable B200 capacity.

## 8) Hopper-only runbook checklist

1. Validate live Hopper availability in target region.
2. Provision with Hopper template id.
3. Confirm runtime tuple matches template metadata.
4. Pull latest scripts/prompts only.
5. Run smoke chunk.
6. Run full workload.
7. Upload artifacts to R2.
8. Terminate pod immediately.

## 8.1) Krea realtime acceleration policy (new)

Krea runtime targets in this repo:

1. `krea-b200-flashattn` (best quality/latency headroom)
2. `krea-hopper-sage` (best practical availability/perf balance)
3. `krea-ampere-sage-or-sdpa` (cost tier)

Operational defaults for steering:

1. keep denoising steps low (`4-6`) for prompt responsiveness
2. default one GPU per realtime stream
3. scale by pod count before trying single-stream multi-GPU

Model-aware runtime scripts:

- `VideoDiffusion/setup_video_runtime.sh`
- `VideoDiffusion/run_video_stream.sh`
- `VideoDiffusion/publish_r2_prebuild_model.sh`
- `VideoDiffusion/restore_r2_prebuild_model.sh`

## 9) Lockstep update rule (mandatory)

Any acceleration behavior change must update together:

1. implementation scripts (`VideoDiffusion/`, `scripts/prime/`)
2. runbooks (`docs/video-magi1-streaming.md`, `docs/prime-intellect.md`, `docs/cloudflare-r2.md`)
3. empirical outcomes (`docs/video-magi1-observations.md`)
4. budget model (`docs/budget-analysis.md`) when startup or storage assumptions change cost math
5. this strategy doc (`docs/accelerate.md`)

## 10) References

- Prime custom Docker tutorial:
  - https://docs.primeintellect.ai/tutorials-on-demand-cloud/deploy-custom-docker-image
- Prime CLI provisioning (`--image custom_template`, `--custom-template-id`):
  - https://docs.primeintellect.ai/cli-reference/provision-gpu
- Prime API provisioning (`customTemplateId` compatibility note):
  - https://docs.primeintellect.ai/api-reference/provision-gpu
- Prime managed disk billing behavior:
  - https://docs.primeintellect.ai/cli-reference/managing-disks
- Prime image accessibility API:
  - https://docs.primeintellect.ai/api-reference/template/check-docker-image
- Cloudflare R2 pricing:
  - https://developers.cloudflare.com/r2/pricing/
- Cloudflare R2 S3 API compatibility:
  - https://developers.cloudflare.com/r2/api/s3/api/
- Cloudflare Containers registry management:
  - https://developers.cloudflare.com/containers/manage-images/
- MAGI-1 repository and install guidance:
  - https://github.com/SandAI-org/MAGI-1
- MAGI-1 model-zoo hardware guidance:
  - https://github.com/SandAI-org/MAGI-1?tab=readme-ov-file#model-zoo
- MagiAttention repository:
  - https://github.com/SandAI-org/MagiAttention
- FlashAttention repository/install guidance:
  - https://github.com/Dao-AILab/flash-attention
- NVIDIA PyTorch container release notes:
  - https://docs.nvidia.com/deeplearning/frameworks/pytorch-release-notes/index.html
