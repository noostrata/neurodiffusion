# Acceleration Playbook (Hopper-Only MAGI)

_Last updated: 2026-02-16_

This is the canonical performance strategy for this repository.

Policy decision for this repo:

1. Hopper-only acceleration path (`H100/H800`-class guidance from upstream MAGI docs).
2. MagiAttention is always part of the prebuilt stack.
3. Prime custom template + Cloudflare R2 is the default architecture.

## 1) Why this policy

Upstream MAGI and MagiAttention docs point to Hopper as the fast path:

- MAGI model-zoo guidance uses `H100/H800` for 24B-class fast paths.
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

## 6) Docker location strategy

For Prime custom template flow, use an OCI registry Prime can access with credentials/template tooling.

Cloudflare notes:

1. Cloudflare Containers has registry capabilities (Cloudflare-native workflow).
2. Prime docs explicitly document custom-template provisioning and image accessibility checks, but do not provide a first-class “Cloudflare registry direct fast-path” runbook for GPU pods.

Practical recommendation for this repo:

1. keep runtime image in Docker Hub/GHCR/ECR-compatible flow validated by Prime template tooling
2. keep data/caches/artifacts in R2

Treat “OCI directly on Cloudflare-only stack for Prime GPU pull path” as optional R&D, not default.

## 7) Speed estimates (repo planning values)

These are planning estimates based on repository runs and source constraints.

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

## 8) Hopper-only runbook checklist

1. Validate live Hopper availability in target region.
2. Provision with Hopper template id.
3. Confirm runtime tuple matches template metadata.
4. Pull latest scripts/prompts only.
5. Run smoke chunk.
6. Run full workload.
7. Upload artifacts to R2.
8. Terminate pod immediately.

## 9) Lockstep update rule (mandatory)

Any acceleration behavior change must update together:

1. implementation scripts (`VideoDiffusion/`, `scripts/prime/`)
2. runbooks (`docs/video-magi1-streaming.md`, `docs/prime-intellect.md`, `docs/cloudflare-r2.md`)
3. empirical outcomes (`docs/video-magi1-observations.md`)
4. this strategy doc (`docs/accelerate.md`)

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
