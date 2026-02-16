# Cloudflare R2 Storage (Canonical)

_Last validated: 2026-02-16_

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
- `AGENT_S3_PREFIX`
- `AGENT_S3_ENDPOINT`
- `AGENT_S3_REGION`
- `AGENT_S3_ACCESS_KEY_ID`
- `AGENT_S3_SECRET_ACCESS_KEY`

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

## Security rules

1. Never commit credential files or literal secret values.
2. Never log access keys or tokens.
3. Keep `config/prime.env` and local env files ignored.
4. Upload only intended artifacts (no host metadata or private keys).

## Related docs

- `how_cloudflare.md` (local environment mapping used on this workstation)
- `docs/prime-intellect.md` (pod lifecycle)
- `docs/video-magi1-streaming.md` (MAGI runbook)
- `docs/video-magi1-observations.md` (empirical outcomes)
