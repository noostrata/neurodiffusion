#!/usr/bin/env python3
"""Deterministic LongLive model-cache downloader for Daydream Scope."""

from __future__ import annotations

import argparse
from pathlib import Path

from huggingface_hub import snapshot_download


def _repo_size(path: Path) -> tuple[int, int]:
    files = [p for p in path.rglob("*") if p.is_file()]
    return len(files), sum(p.stat().st_size for p in files)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Download Scope LongLive model artifacts.")
    parser.add_argument("--models-dir", required=True, help="DAYDREAM_SCOPE_MODELS_DIR target.")
    parser.add_argument("--include-vace", action="store_true", help="Also download the 1.3B VACE module.")
    parser.add_argument("--max-workers", type=int, default=8)
    args = parser.parse_args(argv)

    root = Path(args.models_dir).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)

    wanvideo_patterns = ["config.json", "umt5-xxl-enc-fp8_e4m3fn.safetensors"]
    if args.include_vace:
        wanvideo_patterns.append("Wan2_1-VACE_module_1_3B_bf16.safetensors")

    jobs = [
        (
            "daydreamlive/Wan2.1-T2V-1.3B",
            "Wan2.1-T2V-1.3B",
            ["config.json", "Wan2.1_VAE.pth", "google/**"],
        ),
        ("daydreamlive/WanVideo_comfy", "WanVideo_comfy", wanvideo_patterns),
        (
            "daydreamlive/LongLive-1.3B",
            "LongLive-1.3B",
            ["config.json", "models/longlive_base.pt", "models/lora.pt"],
        ),
        (
            "daydreamlive/Autoencoders",
            "Autoencoders",
            ["config.json", "lightvaew2_1.pth", "taew2_1.pth", "lighttaew2_1.pth"],
        ),
    ]

    for repo_id, dirname, patterns in jobs:
        dest = root / dirname
        print(f"[scope-download] repo={repo_id} dest={dest} patterns={patterns}", flush=True)
        snapshot_download(
            repo_id=repo_id,
            local_dir=str(dest),
            allow_patterns=patterns,
            max_workers=args.max_workers,
        )
        file_count, size_bytes = _repo_size(dest)
        print(
            f"[scope-download] complete repo={repo_id} files={file_count} size_gb={size_bytes / 1e9:.3f}",
            flush=True,
        )

    print("[scope-download] final cache tree:", flush=True)
    for child in sorted(root.iterdir()):
        if not child.is_dir():
            continue
        file_count, size_bytes = _repo_size(child)
        print(f"  {child.name}: files={file_count} size_gb={size_bytes / 1e9:.3f}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
