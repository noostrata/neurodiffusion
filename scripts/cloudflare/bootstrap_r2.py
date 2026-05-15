#!/usr/bin/env python3
"""
Bootstrap Cloudflare R2 layout for neurodiffusion.

Creates/validates deterministic prefixes and uploads a manifest object so
fresh pods and operators can rely on a stable storage contract.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Iterable

try:
    import boto3
    from botocore.exceptions import ClientError
except Exception:  # pragma: no cover - optional dependency on bootstrap venv
    boto3 = None

    class ClientError(Exception):
        pass


DEFAULT_PREFIX = "neurodiffusion"
DEFAULT_LAYOUT_SUFFIXES = (
    "weights/.keep",
    "wheelhouse/.keep",
    "env-cache/.keep",
    "images/.keep",
    "code-bundles/.keep",
    "runs/.keep",
    "benchmarks/.keep",
    "manifests/.keep",
    "manifests/code-bundles/.keep",
    "manifests/runtime-tuples/.keep",
    "bootstrap/.keep",
)


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _normalize_prefix(raw: str) -> str:
    out = raw.strip().strip("/")
    return out or DEFAULT_PREFIX


def _env_or_arg(name: str, value: str | None, required: bool = False) -> str:
    if value is not None and value != "":
        return value
    env_val = os.environ.get(name, "")
    if env_val:
        return env_val
    if required:
        raise SystemExit(f"[error] Missing required value: --{name.lower().replace('_', '-')} or ${name}")
    return ""


def _is_not_found(err: ClientError) -> bool:
    code = str(err.response.get("Error", {}).get("Code", "")).strip().lower()
    return code in {"404", "nosuchbucket", "notfound", "nosuchkey"}


def _head_bucket_exists(s3, bucket: str) -> bool:
    try:
        s3.head_bucket(Bucket=bucket)
        return True
    except ClientError as exc:
        if _is_not_found(exc):
            return False
        raise


def _head_object_exists(s3, bucket: str, key: str) -> bool:
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        if _is_not_found(exc):
            return False
        raise


def _iter_layout_keys(prefix: str, suffixes: Iterable[str]) -> list[str]:
    return [f"{prefix}/{suffix.lstrip('/')}" for suffix in suffixes]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Bootstrap Cloudflare R2 storage layout for neurodiffusion.")
    parser.add_argument("--bucket", default=None, help="R2 bucket name (defaults to $AGENT_S3_BUCKET)")
    parser.add_argument("--prefix", default=None, help="Root key prefix (defaults to $AGENT_S3_PREFIX or neurodiffusion)")
    parser.add_argument("--endpoint", default=None, help="S3 endpoint URL (defaults to $AGENT_S3_ENDPOINT)")
    parser.add_argument("--region", default=None, help="S3 region (defaults to $AGENT_S3_REGION or auto)")
    parser.add_argument(
        "--manifest-key",
        default=None,
        help="Manifest object key. Defaults to <prefix>/bootstrap/r2_bootstrap_manifest.json",
    )
    parser.add_argument(
        "--create-bucket",
        action="store_true",
        help="Create bucket if missing.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only validate and print actions; do not write objects.",
    )
    args = parser.parse_args(argv)

    if boto3 is None:
        raise SystemExit(
            "[error] boto3 is required. Run scripts/cloudflare/bootstrap_r2.sh first "
            "or use .venv/r2-bootstrap/bin/python."
        )

    bucket = _env_or_arg("AGENT_S3_BUCKET", args.bucket, required=True)
    prefix_raw = _env_or_arg("AGENT_S3_PREFIX", args.prefix, required=False)
    prefix = _normalize_prefix(prefix_raw or DEFAULT_PREFIX)
    endpoint = _env_or_arg("AGENT_S3_ENDPOINT", args.endpoint, required=True)
    region = _env_or_arg("AGENT_S3_REGION", args.region, required=False) or "auto"
    access_key = _env_or_arg("AGENT_S3_ACCESS_KEY_ID", None, required=True)
    secret_key = _env_or_arg("AGENT_S3_SECRET_ACCESS_KEY", None, required=True)

    manifest_key = args.manifest_key.strip() if args.manifest_key else ""
    if not manifest_key:
        manifest_key = f"{prefix}/bootstrap/r2_bootstrap_manifest.json"
    manifest_key = manifest_key.strip().lstrip("/")

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=region,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    if not _head_bucket_exists(s3, bucket):
        if not args.create_bucket:
            raise SystemExit(
                f"[error] Bucket '{bucket}' does not exist or is not accessible. "
                "Use --create-bucket to create it."
            )
        if args.dry_run:
            print(f"[dry-run] would create bucket: {bucket}")
        else:
            s3.create_bucket(Bucket=bucket)
            print(f"[ok] created bucket: {bucket}")
    else:
        print(f"[ok] bucket accessible: {bucket}")

    layout_keys = _iter_layout_keys(prefix, DEFAULT_LAYOUT_SUFFIXES)
    created: list[str] = []
    existing: list[str] = []

    for key in layout_keys:
        exists = _head_object_exists(s3, bucket, key)
        if exists:
            existing.append(key)
            continue
        if args.dry_run:
            print(f"[dry-run] would create key: s3://{bucket}/{key}")
        else:
            s3.put_object(Bucket=bucket, Key=key, Body=b"")
            created.append(key)

    manifest = {
        "generated_at": _utc_now_iso(),
        "bucket": bucket,
        "prefix": prefix,
        "endpoint": endpoint,
        "region": region,
        "layout_keys": layout_keys,
        "notes": [
            "This file is generated by scripts/cloudflare/bootstrap_r2.py",
            "Do not store secrets in this manifest.",
        ],
    }
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    if args.dry_run:
        print(f"[dry-run] would write manifest: s3://{bucket}/{manifest_key}")
    else:
        s3.put_object(
            Bucket=bucket,
            Key=manifest_key,
            Body=manifest_bytes,
            ContentType="application/json",
        )

    summary = {
        "status": "dry-run" if args.dry_run else "ok",
        "bucket": bucket,
        "prefix": prefix,
        "manifest_key": manifest_key,
        "created_count": len(created),
        "existing_count": len(existing),
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
