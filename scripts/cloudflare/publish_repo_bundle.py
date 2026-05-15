#!/usr/bin/env python3
"""
Publish/fetch a deterministic neurodiffusion repo bundle to Cloudflare R2.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

try:
    import boto3
    from botocore.exceptions import ClientError
except Exception:  # pragma: no cover - optional dependency on bootstrap venv
    boto3 = None

    class ClientError(Exception):
        pass


DEFAULT_PREFIX = "neurodiffusion"
DEFAULT_INCLUDES = (
    "AGENTS.md",
    "README.md",
    "ImageDiffusion",
    "VideoDiffusion",
    "scripts",
    "docs",
    "config",
)
DEFAULT_EXCLUDES = (
    ".git",
    ".git/*",
    ".venv",
    ".venv/*",
    "*/__pycache__",
    "*/__pycache__/*",
    "*.pyc",
    "*.pyo",
    "*.log",
    "*.mp4",
    "*.png",
    "*.jpg",
    "*.jpeg",
    "config/prime.env",
    "config/vast.env",
    "VideoDiffusion/.tmp",
    "VideoDiffusion/.tmp/*",
    "VideoDiffusion/MAGI-1",
    "VideoDiffusion/MAGI-1/*",
)


def _utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _env_or_arg(env_name: str, arg_val: str | None, required: bool = False) -> str:
    if arg_val:
        return arg_val
    env_val = os.environ.get(env_name, "")
    if env_val:
        return env_val
    if required:
        raise SystemExit(f"[error] Missing required value: --{env_name.lower().replace('_', '-')} or ${env_name}")
    return ""


def _normalize_prefix(raw: str) -> str:
    out = raw.strip().strip("/")
    return out or DEFAULT_PREFIX


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _run_git(repo_root: Path, args: list[str]) -> str:
    try:
        out = subprocess.check_output(["git", *args], cwd=str(repo_root), stderr=subprocess.DEVNULL)
        return out.decode("utf-8").strip()
    except Exception:
        return ""


def _matches_any(rel_path: str, patterns: tuple[str, ...]) -> bool:
    if rel_path in patterns:
        return True
    for pat in patterns:
        if fnmatch.fnmatch(rel_path, pat):
            return True
    return False


def _iter_files(repo_root: Path, includes: tuple[str, ...], excludes: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    seen: set[Path] = set()
    for inc in includes:
        start = (repo_root / inc).resolve()
        if not start.exists():
            continue
        if start.is_file():
            rel = start.relative_to(repo_root).as_posix()
            if _matches_any(rel, excludes):
                continue
            if start not in seen:
                files.append(start)
                seen.add(start)
            continue

        for p in sorted(start.rglob("*")):
            if not p.is_file():
                continue
            rel = p.relative_to(repo_root).as_posix()
            if _matches_any(rel, excludes):
                continue
            if p in seen:
                continue
            files.append(p)
            seen.add(p)
    files.sort(key=lambda p: p.relative_to(repo_root).as_posix())
    return files


def _mk_s3(args) -> tuple[object, str, str]:
    if boto3 is None:
        raise SystemExit(
            "[error] boto3 is required. Run scripts/cloudflare/bootstrap_r2.sh first "
            "or use .venv/r2-bootstrap/bin/python."
        )
    bucket = _env_or_arg("AGENT_S3_BUCKET", args.bucket, required=True)
    endpoint = _env_or_arg("AGENT_S3_ENDPOINT", args.endpoint, required=True)
    region = _env_or_arg("AGENT_S3_REGION", args.region, required=False) or "auto"
    prefix = _normalize_prefix(_env_or_arg("AGENT_S3_PREFIX", args.prefix, required=False))
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


def _build_bundle_tag(repo_root: Path, explicit_tag: str) -> str:
    if explicit_tag:
        return explicit_tag.strip()
    stamp = _utc_stamp()
    git_short = _run_git(repo_root, ["rev-parse", "--short", "HEAD"]) or "nogit"
    dirty = _run_git(repo_root, ["status", "--porcelain"])
    dirty_suffix = "-dirty" if dirty else ""
    return f"{stamp}_{git_short}{dirty_suffix}"


def _make_tar(repo_root: Path, out_tar: Path, files: list[Path]) -> None:
    with tarfile.open(out_tar, "w:gz") as tar:
        for fp in files:
            rel = fp.relative_to(repo_root).as_posix()
            arcname = f"neurodiffusion/{rel}"
            info = tar.gettarinfo(str(fp), arcname=arcname)
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            with fp.open("rb") as f:
                tar.addfile(info, fileobj=f)


def _put_json(s3, bucket: str, key: str, payload: dict) -> None:
    body = (json.dumps(payload, indent=2) + "\n").encode("utf-8")
    s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/json")


def _publish(args) -> int:
    repo_root = Path(args.repo_root).expanduser().resolve()
    if not repo_root.is_dir():
        raise SystemExit(f"[error] repo-root not found: {repo_root}")

    includes = tuple(args.include) if args.include else DEFAULT_INCLUDES
    excludes = tuple(args.exclude) if args.exclude else DEFAULT_EXCLUDES
    files = _iter_files(repo_root, includes, excludes)
    if not files:
        raise SystemExit("[error] No files selected for bundle.")

    bundle_tag = _build_bundle_tag(repo_root, args.bundle_tag)
    s3, bucket, prefix = _mk_s3(args)

    with tempfile.TemporaryDirectory(prefix="nd_repo_bundle_") as td:
        tmp_tar = Path(td) / f"neurodiffusion_repo_{bundle_tag}.tar.gz"
        _make_tar(repo_root, tmp_tar, files)
        sha = _sha256(tmp_tar)
        size_bytes = tmp_tar.stat().st_size

        tar_key = "/".join([prefix, "code-bundles", bundle_tag, tmp_tar.name])
        manifest_key = "/".join([prefix, "manifests", "code-bundles", f"{bundle_tag}.json"])
        latest_key = "/".join([prefix, "manifests", "code-bundles", "latest.json"])

        if args.dry_run:
            summary = {
                "status": "dry-run",
                "bundle_tag": bundle_tag,
                "bucket": bucket,
                "object_key": tar_key,
                "manifest_key": manifest_key,
                "latest_key": latest_key,
                "file_count": len(files),
                "size_bytes": size_bytes,
                "sha256": sha,
            }
            print(json.dumps(summary, indent=2))
            return 0

        s3.upload_file(str(tmp_tar), bucket, tar_key)
        manifest = {
            "generated_at": _utc_iso(),
            "bundle_tag": bundle_tag,
            "bucket": bucket,
            "prefix": prefix,
            "archive_object_key": tar_key,
            "archive_sha256": sha,
            "archive_size_bytes": size_bytes,
            "repo_root": str(repo_root),
            "git_commit": _run_git(repo_root, ["rev-parse", "HEAD"]),
            "git_short": _run_git(repo_root, ["rev-parse", "--short", "HEAD"]),
            "git_branch": _run_git(repo_root, ["rev-parse", "--abbrev-ref", "HEAD"]),
            "includes": list(includes),
            "excludes": list(excludes),
            "file_count": len(files),
            "files": [fp.relative_to(repo_root).as_posix() for fp in files],
        }
        _put_json(s3, bucket, manifest_key, manifest)
        _put_json(s3, bucket, latest_key, manifest)

    summary = {
        "status": "ok",
        "bundle_tag": bundle_tag,
        "bucket": bucket,
        "archive_object_key": tar_key,
        "manifest_key": manifest_key,
        "latest_key": latest_key,
        "file_count": len(files),
    }
    print(json.dumps(summary, indent=2))
    return 0


def _fetch(args) -> int:
    s3, bucket, prefix = _mk_s3(args)
    dest_dir = Path(args.dest_dir).expanduser().resolve()
    dest_dir.mkdir(parents=True, exist_ok=True)

    manifest_key = args.manifest_key.strip() if args.manifest_key else ""
    if not manifest_key:
        if args.bundle_tag:
            manifest_key = "/".join([prefix, "manifests", "code-bundles", f"{args.bundle_tag}.json"])
        else:
            manifest_key = "/".join([prefix, "manifests", "code-bundles", "latest.json"])

    try:
        resp = s3.get_object(Bucket=bucket, Key=manifest_key)
    except ClientError as exc:
        raise SystemExit(f"[error] Failed to fetch manifest '{manifest_key}': {exc}") from exc
    manifest = json.loads(resp["Body"].read().decode("utf-8"))

    tar_key = manifest.get("archive_object_key", "")
    if not tar_key:
        raise SystemExit("[error] Manifest missing archive_object_key.")

    tar_name = Path(tar_key).name
    tar_out = dest_dir / tar_name
    s3.download_file(bucket, tar_key, str(tar_out))
    (dest_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    extracted_to = ""
    if args.extract:
        out_root = dest_dir / "extracted"
        out_root.mkdir(parents=True, exist_ok=True)
        with tarfile.open(tar_out, "r:gz") as tar:
            try:
                tar.extractall(path=out_root, filter="data")
            except TypeError:
                tar.extractall(path=out_root)
        extracted_to = str(out_root)

    summary = {
        "status": "ok",
        "bucket": bucket,
        "manifest_key": manifest_key,
        "archive_object_key": tar_key,
        "archive_path": str(tar_out),
        "extracted_to": extracted_to,
    }
    print(json.dumps(summary, indent=2))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Publish/fetch neurodiffusion repo bundle in Cloudflare R2.")
    parser.add_argument("--bucket", default=None)
    parser.add_argument("--prefix", default=None)
    parser.add_argument("--endpoint", default=None)
    parser.add_argument("--region", default=None)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_pub = sub.add_parser("publish")
    p_pub.add_argument("--repo-root", default=".")
    p_pub.add_argument("--bundle-tag", default="")
    p_pub.add_argument("--include", action="append", default=[])
    p_pub.add_argument("--exclude", action="append", default=[])
    p_pub.add_argument("--dry-run", action="store_true")

    p_fetch = sub.add_parser("fetch")
    p_fetch.add_argument("--bundle-tag", default="")
    p_fetch.add_argument("--manifest-key", default="")
    p_fetch.add_argument("--dest-dir", required=True)
    p_fetch.add_argument("--extract", action="store_true")

    args = parser.parse_args(argv)
    if args.cmd == "publish":
        return _publish(args)
    if args.cmd == "fetch":
        return _fetch(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
