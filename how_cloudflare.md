# how_cloudflare

This file is the workstation-local quick map for Cloudflare R2 access used by
`/Users/xenochain/Code/neurodiffusion`.

Canonical repo runbook is now:

- `docs/cloudflare-r2.md`

## 1) Where local keys live

Canonical full-access credentials file:

- `/Users/xenochain/agents/secrets/r2_full_access.env`

Convenience links (same credentials):

- `/Users/xenochain/agents/cloud.env`
- `/Users/xenochain/Code/epstein/.env.s3`

Do not copy raw secret values into repository files.

## 2) Session bootstrap (required in each new shell)

```bash
cd /Users/xenochain/Code/neurodiffusion
source /Users/xenochain/agents/secrets/r2_full_access.env
```

## 3) Variables available in local env

Common fields used by this repo:

- `AGENT_S3_BUCKET`
- `AGENT_S3_PREFIX`
- `AGENT_S3_ENDPOINT`
- `AGENT_S3_REGION`
- `AGENT_S3_ACCESS_KEY_ID`
- `AGENT_S3_SECRET_ACCESS_KEY`

Additional account-scoped values may also exist:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_DEFAULT_REGION`

## 4) Connectivity smoke test

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
resp = s3.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=10)
print("bucket:", bucket)
print("prefix:", prefix)
print("keys_returned:", len(resp.get("Contents", [])))
PY
```

## 5) Local safety rules

1. Always source `/Users/xenochain/agents/secrets/r2_full_access.env` before cloud operations.
2. Do not print secrets in shell logs or chat.
3. Do not commit `.env` files or inline credentials to git.
4. Keep runtime usage and storage layout aligned with `docs/cloudflare-r2.md`.
