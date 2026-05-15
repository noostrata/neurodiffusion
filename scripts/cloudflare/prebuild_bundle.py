#!/usr/bin/env python3
"""
Publish and fetch MAGI prebuild bundles in Cloudflare R2.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import boto3
    from botocore.exceptions import ClientError
except Exception:  # pragma: no cover - optional dependency on bootstrap venv
    boto3 = None

    class ClientError(Exception):
        pass


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _norm_prefix(raw: str) -> str:
    out = raw.strip().strip("/")
    return out or "neurodiffusion"


def _env_or_arg(env_name: str, arg_value: str | None, required: bool = False) -> str:
    if arg_value:
        return arg_value
    v = os.environ.get(env_name, "")
    if v:
        return v
    if required:
        raise SystemExit(f"[error] Missing required value: --{env_name.lower().replace('_', '-')} or ${env_name}")
    return ""


def _mk_s3_client(args) -> tuple[object, str, str]:
    if boto3 is None:
        raise SystemExit(
            "[error] boto3 is required. Run scripts/cloudflare/bootstrap_r2.sh first "
            "or use .venv/r2-bootstrap/bin/python."
        )
    bucket = _env_or_arg("AGENT_S3_BUCKET", args.bucket, required=True)
    endpoint = _env_or_arg("AGENT_S3_ENDPOINT", args.endpoint, required=True)
    region = _env_or_arg("AGENT_S3_REGION", args.region, required=False) or "auto"
    prefix_raw = _env_or_arg("AGENT_S3_PREFIX", args.prefix, required=False)
    prefix = _norm_prefix(prefix_raw)
    access_key = _env_or_arg("AGENT_S3_ACCESS_KEY_ID", None, required=True)
    secret_key = _env_or_arg("AGENT_S3_SECRET_ACCESS_KEY", None, required=True)
    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=region,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )
    return s3, bucket, prefix


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _upload_file(s3, bucket: str, local_path: Path, object_key: str) -> dict:
    s3.upload_file(str(local_path), bucket, object_key)
    return {
        "local_path": str(local_path),
        "object_key": object_key,
        "size_bytes": local_path.stat().st_size,
        "sha256": _sha256(local_path),
    }


def _walk_files(root: Path) -> list[Path]:
    out: list[Path] = []
    for p in sorted(root.rglob("*")):
        if p.is_file():
            out.append(p)
    return out


def _key_join(*parts: str) -> str:
    return "/".join([x.strip("/") for x in parts if x.strip("/")])


def _publish(args) -> int:
    s3, bucket, prefix = _mk_s3_client(args)
    runtime_tag = args.runtime_tag.strip()
    if not runtime_tag:
        raise SystemExit("[error] --runtime-tag is required for publish.")

    published_at = _utc_now_iso()
    stamp = _utc_stamp()
    artifacts: list[dict] = []

    if args.wheelhouse_dir:
        wheelhouse_dir = Path(args.wheelhouse_dir).expanduser().resolve()
        if not wheelhouse_dir.is_dir():
            raise SystemExit(f"[error] wheelhouse dir not found: {wheelhouse_dir}")
        for p in _walk_files(wheelhouse_dir):
            rel = p.relative_to(wheelhouse_dir).as_posix()
            object_key = _key_join(prefix, "wheelhouse", runtime_tag, rel)
            info = _upload_file(s3, bucket, p, object_key)
            info["artifact_type"] = "wheelhouse"
            artifacts.append(info)

    if args.env_archive:
        env_archive = Path(args.env_archive).expanduser().resolve()
        if not env_archive.is_file():
            raise SystemExit(f"[error] env archive not found: {env_archive}")
        object_key = _key_join(prefix, "env-cache", runtime_tag, env_archive.name)
        info = _upload_file(s3, bucket, env_archive, object_key)
        info["artifact_type"] = "env_archive"
        artifacts.append(info)

    if args.weights_archive:
        weights_archive = Path(args.weights_archive).expanduser().resolve()
        if not weights_archive.is_file():
            raise SystemExit(f"[error] weights archive not found: {weights_archive}")
        object_key = _key_join(prefix, "weights", runtime_tag, weights_archive.name)
        info = _upload_file(s3, bucket, weights_archive, object_key)
        info["artifact_type"] = "weights_archive"
        artifacts.append(info)

    if args.image_archive:
        image_archive = Path(args.image_archive).expanduser().resolve()
        if not image_archive.is_file():
            raise SystemExit(f"[error] image archive not found: {image_archive}")
        object_key = _key_join(prefix, "images", runtime_tag, image_archive.name)
        info = _upload_file(s3, bucket, image_archive, object_key)
        info["artifact_type"] = "image_archive"
        artifacts.append(info)

    metadata_obj_key = ""
    if args.metadata_json:
        metadata_json = Path(args.metadata_json).expanduser().resolve()
        if not metadata_json.is_file():
            raise SystemExit(f"[error] metadata json not found: {metadata_json}")
        metadata_obj_key = _key_join(prefix, "manifests", "runtime-tuples", runtime_tag, f"metadata_{stamp}.json")
        info = _upload_file(s3, bucket, metadata_json, metadata_obj_key)
        info["artifact_type"] = "metadata"
        artifacts.append(info)

    manifest = {
        "generated_at": published_at,
        "runtime_tag": runtime_tag,
        "bucket": bucket,
        "prefix": prefix,
        "artifacts": artifacts,
        "metadata_object_key": metadata_obj_key,
        "artifact_checksums": {
            str(a.get("object_key", "")): str(a.get("sha256", "")) for a in artifacts if a.get("object_key")
        },
    }
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    manifest_run_key = _key_join(prefix, "manifests", "runtime-tuples", runtime_tag, f"manifest_{stamp}.json")
    manifest_latest_key = _key_join(prefix, "manifests", "runtime-tuples", runtime_tag, "latest.json")
    s3.put_object(Bucket=bucket, Key=manifest_run_key, Body=manifest_bytes, ContentType="application/json")
    s3.put_object(Bucket=bucket, Key=manifest_latest_key, Body=manifest_bytes, ContentType="application/json")

    summary = {
        "status": "ok",
        "runtime_tag": runtime_tag,
        "artifact_count": len(artifacts),
        "manifest_run_key": manifest_run_key,
        "manifest_latest_key": manifest_latest_key,
    }
    print(json.dumps(summary, indent=2))
    return 0


def _download_object(s3, bucket: str, key: str, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    s3.download_file(bucket, key, str(path))


def _load_latest_manifest(s3, bucket: str, manifest_key: str) -> dict:
    try:
        resp = s3.get_object(Bucket=bucket, Key=manifest_key)
    except ClientError as exc:
        raise SystemExit(f"[error] Failed to load manifest '{manifest_key}': {exc}") from exc
    raw = resp["Body"].read().decode("utf-8")
    return json.loads(raw)


def _fetch(args) -> int:
    s3, bucket, prefix = _mk_s3_client(args)
    runtime_tag = args.runtime_tag.strip()
    if not runtime_tag:
        raise SystemExit("[error] --runtime-tag is required for fetch.")
    dest_dir = Path(args.dest_dir).expanduser().resolve()
    dest_dir.mkdir(parents=True, exist_ok=True)

    manifest_key = args.manifest_key.strip() if args.manifest_key else ""
    if not manifest_key:
        manifest_key = _key_join(prefix, "manifests", "runtime-tuples", runtime_tag, "latest.json")
    manifest = _load_latest_manifest(s3, bucket, manifest_key)

    saved_manifest = dest_dir / "manifest.json"
    saved_manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    requested_types: set[str] = set()
    if args.artifact_types:
        requested_types = {x.strip() for x in args.artifact_types.split(",") if x.strip()}

    downloaded = []
    skipped = []
    for artifact in manifest.get("artifacts", []):
        object_key = str(artifact.get("object_key", "")).strip()
        if not object_key:
            continue
        artifact_type = str(artifact.get("artifact_type", "artifact")).strip()
        if requested_types and artifact_type not in requested_types:
            skipped.append({"object_key": object_key, "artifact_type": artifact_type})
            continue
        filename = Path(object_key).name
        out_path = dest_dir / artifact_type / filename
        _download_object(s3, bucket, object_key, out_path)
        expected_sha = str(artifact.get("sha256") or "").strip().lower()
        local_sha = _sha256(out_path)
        if expected_sha and local_sha.lower() != expected_sha:
            try:
                out_path.unlink(missing_ok=True)
            except Exception:
                pass
            raise SystemExit(
                f"[error] sha256 mismatch for '{object_key}': expected {expected_sha}, got {local_sha}"
            )
        downloaded.append(
            {
                "path": str(out_path),
                "object_key": object_key,
                "artifact_type": artifact_type,
                "sha256_expected": expected_sha or None,
                "sha256_local": local_sha,
            }
        )

    summary = {
        "status": "ok",
        "runtime_tag": runtime_tag,
        "manifest_key": manifest_key,
        "dest_dir": str(dest_dir),
        "downloaded_count": len(downloaded),
        "downloaded": downloaded,
        "skipped_count": len(skipped),
        "requested_types": sorted(requested_types),
    }
    print(json.dumps(summary, indent=2))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Publish/fetch prebuild bundles in Cloudflare R2.")
    parser.add_argument("--bucket", default=None)
    parser.add_argument("--prefix", default=None)
    parser.add_argument("--endpoint", default=None)
    parser.add_argument("--region", default=None)

    sub = parser.add_subparsers(dest="cmd", required=True)

    p_pub = sub.add_parser("publish")
    p_pub.add_argument("--runtime-tag", required=True)
    p_pub.add_argument("--wheelhouse-dir", default="")
    p_pub.add_argument("--env-archive", default="")
    p_pub.add_argument("--weights-archive", default="")
    p_pub.add_argument("--image-archive", default="")
    p_pub.add_argument("--metadata-json", default="")

    p_fetch = sub.add_parser("fetch")
    p_fetch.add_argument("--runtime-tag", required=True)
    p_fetch.add_argument("--dest-dir", required=True)
    p_fetch.add_argument("--manifest-key", default="")
    p_fetch.add_argument(
        "--artifact-types",
        default="",
        help="Optional CSV filter, e.g. env_archive,wheelhouse,weights_archive,image_archive",
    )

    args = parser.parse_args(argv)
    if args.cmd == "publish":
        return _publish(args)
    if args.cmd == "fetch":
        return _fetch(args)
    raise SystemExit("[error] Unknown command.")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
