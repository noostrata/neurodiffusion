# Cloudflare R2 Storage (Canonical)

_Last validated: 2026-02-18_

This is the canonical storage runbook for this repository.
Use Cloudflare R2 for artifact persistence, cache handoff, and cross-pod reuse.

## Why R2 is part of the fast path

1. Prime pods are often short-lived; local pod disk is not durable.
2. MAGI setup has heavy cold-start cost (`pip`, `flash-attn`, weights, first-run caches).
3. R2 gives a stable object store to move artifacts and reusable bundles between runs.

## Secret source and local bootstrap

Canonical local secret file:

- `/Users/xenochain/agents/secrets/r2_full_access.env`

Bootstrap each shell before cloud operations:

```bash
cd /Users/xenochain/Code/neurodiffusion
source /Users/xenochain/agents/secrets/r2_full_access.env
```

Do not copy raw secret values into tracked files.

## Required environment contract

Expected variables from the env file:

- `AGENT_S3_BUCKET`
- `AGENT_S3_ENDPOINT`
- `AGENT_S3_REGION`
- `AGENT_S3_ACCESS_KEY_ID`
- `AGENT_S3_SECRET_ACCESS_KEY`

Optional:

- `AGENT_S3_PREFIX` (script defaults to `neurodiffusion` unless `--prefix` is provided)
- `R2_PREFIX` (used by `VideoDiffusion/publish_r2_prebuild.sh` and `VideoDiffusion/restore_r2_prebuild.sh`, default `neurodiffusion`)

## One-command bootstrap (recommended)

Create/verify the full neurodiffusion R2 layout and write a bootstrap manifest:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/cloudflare/bootstrap_r2.sh
```

Default namespace is `neurodiffusion/` even if your local env has another `AGENT_S3_PREFIX`.
Override explicitly when needed:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/cloudflare/bootstrap_r2.sh --prefix my-other-prefix
```

If the bucket does not exist yet, allow creation:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/cloudflare/bootstrap_r2.sh --create-bucket
```

Dry-run preview:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/cloudflare/bootstrap_r2.sh --dry-run
```

What this bootstraps:

- `<prefix>/weights/.keep`
- `<prefix>/wheelhouse/.keep`
- `<prefix>/env-cache/.keep`
- `<prefix>/images/.keep`
- `<prefix>/code-bundles/.keep`
- `<prefix>/runs/.keep`
- `<prefix>/benchmarks/.keep`
- `<prefix>/manifests/.keep`
- `<prefix>/manifests/code-bundles/.keep`
- `<prefix>/manifests/runtime-tuples/.keep`
- `<prefix>/bootstrap/.keep`
- `<prefix>/bootstrap/r2_bootstrap_manifest.json`

Default script locations:

- `scripts/cloudflare/bootstrap_r2.sh`
- `scripts/cloudflare/bootstrap_r2.py`
- `scripts/cloudflare/publish_repo_bundle.py`
- `scripts/cloudflare/publish_everything_r2.sh`
- `scripts/cloudflare/prebuild_bundle.py`
- `VideoDiffusion/publish_r2_prebuild.sh`
- `VideoDiffusion/restore_r2_prebuild.sh`

Bootstrap script behavior note:

- If `boto3` is missing in system Python, `bootstrap_r2.sh` auto-creates a helper venv at `.venv/r2-bootstrap` and installs `boto3` there.
- If the helper venv exists but is broken (for example missing `pip`), the script now repairs/recreates it automatically.
- On minimal Ubuntu pod images where `python3-venv` is unavailable, bootstrap now falls back to installing `python3-pip` and installs `boto3` into system Python user-site.

One-command publish for this repo:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/cloudflare/publish_everything_r2.sh \
  --runtime-tag <runtime_tag> \
  --tiers 4.5b,24b \
  --include-weights \
  --include-image
```

This publishes:

1. deterministic repo code bundle under `<prefix>/code-bundles/<bundle_tag>/`
2. latest code-bundle manifest under `<prefix>/manifests/code-bundles/latest.json`
3. runtime tuple artifacts (venv/wheels/weights) when present locally
4. optional runtime image archive under `<prefix>/images/<runtime_tag>/...`

Restore behavior note:

- `VideoDiffusion/restore_r2_prebuild.sh` now validates `boto3` importability before fetch and triggers bootstrap auto-heal when needed, so tuple restore no longer hard-fails on fresh pods with partially initialized helper environments.
- `scripts/cloudflare/prebuild_bundle.py fetch` now verifies artifact SHA256 against tuple manifest entries and fails fast on checksum mismatch.
- `VideoDiffusion/restore_r2_prebuild.sh` now serializes extraction to apply targets with lock directories, preventing concurrent restores from corrupting shared weight/venv paths.
- Latest validated MAGI path used `restore_r2_prebuild.sh --mode tuple` + `setup.sh` delta + one-shot `test_single_chunk.sh` to produce a full `30.0s` clip, then pod teardown.

`publish_everything_r2.sh` contract:

- `--runtime-tag <tag>`
- `--tiers 4.5b,24b`
- `--include-image`
- `--include-weights`
- `--purge-local-after-upload`

Restore latest repo code bundle:

```bash
cd /Users/xenochain/Code/neurodiffusion
.venv/r2-bootstrap/bin/python scripts/cloudflare/publish_repo_bundle.py \
  --prefix neurodiffusion \
  fetch \
  --dest-dir /tmp/neurodiffusion_bundle_restore \
  --extract
```

## Connectivity test (boto3)

```bash
python3 - <<'PY'
import os
import boto3

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["AGENT_S3_ENDPOINT"],
    region_name=os.environ.get("AGENT_S3_REGION", "auto"),
    aws_access_key_id=os.environ["AGENT_S3_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AGENT_S3_SECRET_ACCESS_KEY"],
)

bucket = os.environ["AGENT_S3_BUCKET"]
prefix = os.environ.get("AGENT_S3_PREFIX", "neurodiffusion/")
resp = s3.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=5)
print("bucket:", bucket)
print("prefix:", prefix)
print("keys:", len(resp.get("Contents", [])))
PY
```

## Optional AWS CLI pattern

R2 is S3-compatible. If `aws` CLI is available:

```bash
aws s3 ls "s3://$AGENT_S3_BUCKET/$AGENT_S3_PREFIX" \
  --endpoint-url "$AGENT_S3_ENDPOINT"
```

For copy:

```bash
aws s3 cp VideoDiffusion/magi_scripted_30s.mp4 \
  "s3://$AGENT_S3_BUCKET/${AGENT_S3_PREFIX%/}/runs/manual_test/magi_scripted_30s.mp4" \
  --endpoint-url "$AGENT_S3_ENDPOINT"
```

## Recommended bucket layout

Use deterministic keys:

- `neurodiffusion/weights/` — optional prepackaged reusable weight bundles.
- `neurodiffusion/wheelhouse/` — prebuilt wheels (`flash-attn`, pinned deps) by CUDA/Python/torch.
- `neurodiffusion/env-cache/` — archive of venv/site-packages for strict version match reuse.
- `neurodiffusion/images/<runtime_tag>/` — optional runtime image artifacts (`.tar/.tar.gz/.tar.zst`).
- `neurodiffusion/code-bundles/<bundle_tag>/` — versioned repo bundle archives for remote sync.
- `neurodiffusion/manifests/runtime-tuples/<runtime_tag>/latest.json` — tuple manifest pointer.
- `neurodiffusion/manifests/code-bundles/latest.json` — latest code bundle pointer.
- `neurodiffusion/runs/<run_id>/` — run outputs (`mp4`, json/csv reports, logs).
- `neurodiffusion/benchmarks/` — longitudinal perf summaries.

## Operator flow (recommended)

1. Build or refresh reusable cache bundle once.
2. Upload cache bundle to R2.
3. On new pod, pull cache bundle before `setup.sh`.
4. Run MAGI workflow.
5. Upload final artifacts and reports back to R2.
6. Terminate pod immediately.

## Example upload/download helper (boto3)

```bash
python3 - <<'PY'
import os
from pathlib import Path
import boto3

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["AGENT_S3_ENDPOINT"],
    region_name=os.environ.get("AGENT_S3_REGION", "auto"),
    aws_access_key_id=os.environ["AGENT_S3_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AGENT_S3_SECRET_ACCESS_KEY"],
)

bucket = os.environ["AGENT_S3_BUCKET"]
prefix = os.environ.get("AGENT_S3_PREFIX", "neurodiffusion/")
local_path = Path("VideoDiffusion/magi_scripted_30s.mp4")
remote_key = f"{prefix.rstrip('/')}/runs/manual_test/magi_scripted_30s.mp4"

if local_path.exists():
    s3.upload_file(str(local_path), bucket, remote_key)
    print("uploaded:", f"s3://{bucket}/{remote_key}")
PY
```

## Fast-path guidance for `flash-attn`

R2 should store wheel/cache artifacts keyed by runtime tuple:

- Python version
- torch version
- CUDA version
- GPU arch target

Suggested key pattern:

- `neurodiffusion/wheelhouse/py310_torch2.7.1_cu124_sm90/`

This does not replace a prebuilt Prime image, but it reduces repeated network/build time across pods.

## Prebuild publish/restore workflow

After `VideoDiffusion/setup.sh` succeeds on your target pod, publish the runtime tuple:

```bash
cd /root/neurodiffusion
export AGENT_S3_BUCKET=...
export AGENT_S3_ENDPOINT=...
export AGENT_S3_REGION=auto
export AGENT_S3_ACCESS_KEY_ID=...
export AGENT_S3_SECRET_ACCESS_KEY=...
WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/. \
bash VideoDiffusion/publish_r2_prebuild.sh \
  --runtime-tag <runtime_tag> \
  --tiers 4.5b,24b \
  --include-weights \
  --allow-missing-image
```

MAGI weights publish note:

- `VideoDiffusion/download_weights.sh` uses symlink normalization under `MAGI-1/downloads/`.
- For full-file tuple archives, publish from a real-files path (`MAGI-1/.` or equivalent staged directory), not symlink-only `MAGI-1/downloads/`.
- Otherwise the uploaded `weights_archive` can be tiny and incomplete.

`publish_r2_prebuild.sh` requires these `AGENT_S3_*` vars when running on pods.
By default it cleans local staging files under `VideoDiffusion/.tmp/` after upload.
Set `--keep-tmp` only when debugging.
If `.venv/r2-bootstrap` exists but lacks `boto3`, the script now auto-heals by re-running
`scripts/cloudflare/bootstrap_r2.sh --dry-run` before publish.

Recommended publish command:

```bash
WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/. \
bash VideoDiffusion/publish_r2_prebuild.sh \
  --runtime-tag <runtime_tag> \
  --tiers 4.5b,24b \
  --include-weights \
  --allow-missing-image
```

Latest validated MAGI tuple snapshot:

- `runtime_tag`: `hopper_sm80_py310_torch240_cu124_20260217_prebuild1`
- `env_archive`: `neurodiffusion/env-cache/hopper_sm80_py310_torch240_cu124_20260217_prebuild1/venv_hopper_sm80_py310_torch240_cu124_20260217_prebuild1.tar.gz` (`3,924,169,961` bytes)
- `weights_archive`: `neurodiffusion/weights/hopper_sm80_py310_torch240_cu124_20260217_prebuild1/weights_hopper_sm80_py310_torch240_cu124_20260217_prebuild1.tar.gz` (`18,617,611,111` bytes)
- `latest manifest`: `neurodiffusion/manifests/runtime-tuples/hopper_sm80_py310_torch240_cu124_20260217_prebuild1/latest.json`

Compatibility rule:

- despite the historical `hopper_` prefix, this tuple is an `sm80` runtime tuple.
- treat it as A100-class only.
- do not restore it onto H100/H200 unless intentionally debugging a mismatch.
- the 2026-05-14 H200 attempt restored successfully and loaded DiT, then failed in VAE decode with `no kernel image is available for execution on the device`.
- publish a separate `sm90` tuple before making H100/H200 the default fast path.

This uploads:

- wheel cache files (when available) -> `neurodiffusion/wheelhouse/<runtime_tag>/`
- venv archive -> `neurodiffusion/env-cache/<runtime_tag>/`
- optional weights archive -> `neurodiffusion/weights/<runtime_tag>/`
- optional runtime image archive -> `neurodiffusion/images/<runtime_tag>/`
- tuple manifests -> `neurodiffusion/manifests/runtime-tuples/<runtime_tag>/`

Restore on a fresh pod:

```bash
cd /root/neurodiffusion
bash VideoDiffusion/restore_r2_prebuild.sh \
  --mode auto \
  --runtime-tag <runtime_tag> \
  --tier 4.5b \
  --apply-venv-target /root/neurodiffusion/VideoDiffusion/.venv \
  --apply-weights-target /root/neurodiffusion/VideoDiffusion/MAGI-1
```

`restore_r2_prebuild.sh` repairs restored venv console-script shebangs after extraction, because archived venvs can contain absolute paths from the publishing host.
Then run only incremental setup steps.

## Model-aware runtime tuples (MAGI + Krea)

Use the model-aware wrappers when you need both runtimes in one repo:

Publish:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash scripts/cloudflare/publish_everything_r2.sh \
  --video-model krea \
  --attn-backend auto \
  --runtime-tag <runtime_tag> \
  --tiers krea-b200-flashattn,krea-hopper-sage,krea-ampere-sage-or-sdpa \
  --include-weights
```

Direct runtime publish/restore dispatchers:

- `bash VideoDiffusion/publish_r2_prebuild_model.sh --model <magi|krea> --attn-backend <auto|sage|flash|sdpa> ...`
- `bash VideoDiffusion/restore_r2_prebuild_model.sh --model <magi|krea> --mode auto --runtime-tag <runtime_tag> ...`

Suggested Krea runtime tuple tags:

- `krea-b200-flashattn`
- `krea-hopper-sage`
- `krea-ampere-sage-or-sdpa`

MAGI tuple naming remains unchanged (`4.5b`, `24b` tier metadata).

## Security rules

1. Never commit credential files or literal secret values.
2. Never log access keys or tokens.
3. Keep `config/prime.env` and local env files ignored.
4. Upload only intended artifacts (no host metadata or private keys).

## Related docs

- `how_cloudflare.md` (local environment mapping used on this workstation)
- `docs/prime-intellect.md` (pod lifecycle)
- `docs/budget-analysis.md` (Prime vs R2 recurring cost math)
- `docs/video-magi1-streaming.md` (MAGI runbook)
- `docs/video-magi1-observations.md` (empirical outcomes)
