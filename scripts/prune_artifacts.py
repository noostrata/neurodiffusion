#!/usr/bin/env python3
"""Prune bulky local video/image artifacts while preserving run telemetry."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ARTIFACTS_ROOT = REPO_ROOT / "artifacts"
MEDIA_SUFFIXES = {".mp4", ".png", ".jpg", ".jpeg"}
DEFAULT_KEEP_GLOBS = (
    "runs/longlive2/*/offline/videos/*.mp4",
    "runs/longlive2/*/offline/qa/contact_sheet.jpg",
    "runs/longlive2/*/sp_benchmark/*/videos/*.mp4",
    "runs/longlive2/*/sp_benchmark/*/qa/contact_sheet.jpg",
)


@dataclass(frozen=True)
class PruneItem:
    path: Path
    relative_path: str
    size_bytes: int
    sha256: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_kept(relative_path: str, keep_globs: Iterable[str]) -> bool:
    return any(fnmatch.fnmatch(relative_path, pattern) for pattern in keep_globs)


def collect_prune_items(artifacts_root: Path, keep_globs: Iterable[str]) -> list[PruneItem]:
    root = artifacts_root.resolve()
    items: list[PruneItem] = []
    if not root.exists():
        return items
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in MEDIA_SUFFIXES:
            continue
        relative_path = path.relative_to(root).as_posix()
        if is_kept(relative_path, keep_globs):
            continue
        stat = path.stat()
        items.append(
            PruneItem(
                path=path,
                relative_path=relative_path,
                size_bytes=stat.st_size,
                sha256=sha256_file(path),
            )
        )
    return items


def write_manifest(
    manifest_path: Path,
    artifacts_root: Path,
    items: list[PruneItem],
    keep_globs: Iterable[str],
    delete: bool,
) -> None:
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "artifacts_root": str(artifacts_root),
        "delete": delete,
        "policy": "Prune bulky local media artifacts while preserving run telemetry, reports, logs, and configured proof clips.",
        "keep_globs": list(keep_globs),
        "item_count": len(items),
        "total_size_bytes": sum(item.size_bytes for item in items),
        "items": [
            {
                "path": str(item.path),
                "relative_path": item.relative_path,
                "size_bytes": item.size_bytes,
                "sha256": item.sha256,
            }
            for item in items
        ],
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def remove_empty_dirs(root: Path) -> None:
    keep = {
        root,
        root / "manifests",
        root / "runs",
        root / "runs" / "longlive2",
        root / "runs" / "scope-longlive",
    }
    for directory in sorted((p for p in root.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
        if directory in keep:
            continue
        try:
            directory.rmdir()
        except OSError:
            pass


def run_prune(args: argparse.Namespace) -> int:
    artifacts_root = args.artifacts_root.expanduser().resolve()
    keep_globs = tuple(args.keep_glob or DEFAULT_KEEP_GLOBS)
    items = collect_prune_items(artifacts_root, keep_globs)
    manifest_path = args.manifest
    if manifest_path is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        manifest_path = artifacts_root / "manifests" / f"media_prune_{stamp}.json"
    else:
        manifest_path = manifest_path.expanduser()

    if args.write_manifest or args.delete:
        write_manifest(manifest_path, artifacts_root, items, keep_globs, args.delete)

    if args.delete:
        for item in items:
            item.path.unlink()
        remove_empty_dirs(artifacts_root)

    if not getattr(args, "quiet", False):
        print(
            json.dumps(
                {
                    "artifacts_root": str(artifacts_root),
                    "delete": bool(args.delete),
                    "candidate_count": len(items),
                    "candidate_size_bytes": sum(item.size_bytes for item in items),
                    "manifest": str(manifest_path) if args.write_manifest or args.delete else "",
                },
                indent=2,
            )
        )
    return 0


def selftest() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "artifacts"
        keep = root / "runs/longlive2/test/offline/videos/keep.mp4"
        keep_contact = root / "runs/longlive2/test/sp_benchmark/sp1/qa/contact_sheet.jpg"
        drop = root / "runs/scope-longlive/test/webrtc_capture.mp4"
        frame = root / "runs/scope-longlive/test/frames/frame_000024.png"
        report = root / "runs/scope-longlive/test/run_report.json"
        for path, data in (
            (keep, b"keep-video"),
            (keep_contact, b"keep-contact"),
            (drop, b"drop-video"),
            (frame, b"drop-frame"),
            (report, b"{}"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        manifest = root / "manifests/prune.json"
        args = argparse.Namespace(
            artifacts_root=root,
            keep_glob=list(DEFAULT_KEEP_GLOBS),
            manifest=manifest,
            write_manifest=True,
            delete=True,
            quiet=True,
        )
        run_prune(args)
        assert keep.exists(), "kept proof video was deleted"
        assert keep_contact.exists(), "kept proof contact sheet was deleted"
        assert report.exists(), "non-media report was deleted"
        assert not drop.exists(), "video candidate was not deleted"
        assert not frame.exists(), "frame candidate was not deleted"
        assert json.loads(manifest.read_text())["item_count"] == 2
    print("[prune-artifacts-selftest] ok")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifacts-root",
        type=Path,
        default=DEFAULT_ARTIFACTS_ROOT,
        help=f"Artifact archive root. Default: {DEFAULT_ARTIFACTS_ROOT}",
    )
    parser.add_argument(
        "--keep-glob",
        action="append",
        help="Relative glob to keep. Repeatable. Default keeps LongLive2 proof MP4s.",
    )
    parser.add_argument("--manifest", type=Path, help="Manifest path to write.")
    parser.add_argument("--write-manifest", action="store_true", help="Write a manifest without deleting.")
    parser.add_argument("--delete", action="store_true", help="Delete matching media files.")
    parser.add_argument("--selftest", action="store_true", help="Run local selftest.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.selftest:
        return selftest()
    return run_prune(args)


if __name__ == "__main__":
    raise SystemExit(main())
