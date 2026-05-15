#!/usr/bin/env python3
"""
Select a Vast.ai offer deterministically from query_video_offers.py output.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


GPU_RANKS = [
    (re.compile(r"B200", re.IGNORECASE), 1),
    (re.compile(r"H200|GH200", re.IGNORECASE), 2),
    (re.compile(r"H100", re.IGNORECASE), 3),
    (re.compile(r"RTX.?5090", re.IGNORECASE), 4),
    (re.compile(r"L40S|RTX.?6000|A6000", re.IGNORECASE), 5),
    (re.compile(r"A100", re.IGNORECASE), 6),
    (re.compile(r"RTX.?4090", re.IGNORECASE), 7),
]

RUNTIME_ARCH_GPU_REGEX = {
    "sm80": re.compile(r"A100", re.IGNORECASE),
    "sm86": re.compile(r"A6000|RTX.?6000", re.IGNORECASE),
    "sm89": re.compile(r"L40S|RTX.?4090", re.IGNORECASE),
    "sm90": re.compile(r"H100|H200|GH200", re.IGNORECASE),
    "sm100": re.compile(r"B200", re.IGNORECASE),
}


def _load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"[error] File not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _gpu_rank(name: str) -> int:
    for rx, rank in GPU_RANKS:
        if rx.search(name):
            return rank
    return 999999


def _as_float(value: Any) -> float | None:
    try:
        return float(value)
    except Exception:
        return None


def _as_int(value: Any) -> int | None:
    try:
        return int(float(value))
    except Exception:
        return None


def _runtime_arch_from_tag(runtime_tag: str) -> str | None:
    match = re.search(r"(?:^|[_-])(sm\d+)(?:[_-]|$)", runtime_tag, re.IGNORECASE)
    if not match:
        return None
    return match.group(1).lower()


def _select(
    scan: dict[str, Any],
    *,
    selection_goal: str,
    min_gpu_count: int,
    max_dph: float | None,
    runtime_tag: str,
    allow_runtime_gpu_mismatch: bool,
) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    runtime_arch = _runtime_arch_from_tag(runtime_tag)
    runtime_gpu_rx = RUNTIME_ARCH_GPU_REGEX.get(runtime_arch or "")
    for offer in scan.get("offers", []):
        offer_id = str(offer.get("offer_id") or "").strip()
        gpu_name = str(offer.get("gpu_name") or "").strip()
        num_gpus = _as_int(offer.get("num_gpus")) or 0
        dph_total = _as_float(offer.get("dph_total"))
        if not offer_id or not gpu_name or dph_total is None:
            continue
        if num_gpus < min_gpu_count:
            continue
        if max_dph is not None and dph_total > max_dph:
            continue
        if runtime_gpu_rx is not None and not allow_runtime_gpu_mismatch and not runtime_gpu_rx.search(gpu_name):
            continue
        candidates.append(offer)

    if not candidates:
        raise SystemExit(
            f"[error] No Vast offers satisfy min_gpu_count={min_gpu_count}"
            + (f" max_dph={max_dph}" if max_dph is not None else "")
            + (
                f" runtime_tag={runtime_tag} runtime_arch={runtime_arch}"
                if runtime_gpu_rx is not None and not allow_runtime_gpu_mismatch
                else ""
            )
        )

    def sort_key(offer: dict[str, Any]) -> tuple:
        gpu_name = str(offer.get("gpu_name") or "")
        dph_total = float(offer.get("dph_total"))
        num_gpus = int(float(offer.get("num_gpus") or 0))
        location = str(offer.get("location") or "")
        machine_id = str(offer.get("machine_id") or "")
        if selection_goal == "realtime":
            return (_gpu_rank(gpu_name), dph_total, -num_gpus, location, machine_id)
        return (dph_total, _gpu_rank(gpu_name), -num_gpus, location, machine_id)

    best = sorted(candidates, key=sort_key)[0]
    return {
        "provider": "vastai",
        "model": scan.get("model"),
        "selection_goal": selection_goal,
        "min_gpu_count": min_gpu_count,
        "max_dph": max_dph,
        "runtime_tag": runtime_tag,
        "runtime_arch": runtime_arch,
        "allow_runtime_gpu_mismatch": allow_runtime_gpu_mismatch,
        "candidate_count": len(candidates),
        "selection_rule": [
            "realtime: gpu rank -> lower dph_total -> higher num_gpus -> location -> machine_id",
            "cost: lower dph_total -> gpu rank -> higher num_gpus -> location -> machine_id",
            "runtime_tag smXX: filter to matching GPU family unless --allow-runtime-gpu-mismatch is set",
        ],
        "selected_offer": best,
    }


def _default_out_path(repo_root: Path, model: str) -> Path:
    return repo_root / "VideoDiffusion" / ".tmp" / f"vast_selected_offer_{model}.json"


def _env_block(selected: dict[str, Any]) -> str:
    offer = selected["selected_offer"]
    return "\n".join(
        [
            f"VAST_OFFER_ID={offer.get('offer_id')}",
            f"VAST_GPU_NAME={offer.get('gpu_name')}",
            f"VAST_NUM_GPUS={offer.get('num_gpus')}",
            f"HOURLY_RATE_USD={offer.get('dph_total')}",
            f"VAST_LOCATION={offer.get('location') or ''}",
            f"VAST_MACHINE_ID={offer.get('machine_id') or ''}",
        ]
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scan-json", required=True)
    parser.add_argument("--selection-goal", choices=["realtime", "cost"], default="realtime")
    parser.add_argument("--min-gpu-count", type=int, default=1)
    parser.add_argument("--max-dph", type=float, default=None)
    parser.add_argument("--runtime-tag", default="", help="Optional R2 runtime tag; smXX tags filter to compatible GPUs")
    parser.add_argument(
        "--allow-runtime-gpu-mismatch",
        action="store_true",
        help="Do not filter offers by smXX architecture inferred from --runtime-tag",
    )
    parser.add_argument("--out-json", default="")
    parser.add_argument("--print-env", action="store_true")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    scan = _load_json(Path(args.scan_json).expanduser())
    model = str(scan.get("model") or "video")
    selected = _select(
        scan,
        selection_goal=args.selection_goal,
        min_gpu_count=max(1, int(args.min_gpu_count)),
        max_dph=args.max_dph,
        runtime_tag=args.runtime_tag,
        allow_runtime_gpu_mismatch=args.allow_runtime_gpu_mismatch,
    )

    out_path = Path(args.out_json).expanduser() if args.out_json else _default_out_path(repo_root, model)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(selected, indent=2) + "\n", encoding="utf-8")

    offer = selected["selected_offer"]
    print(
        f"[vast-select] id={offer.get('offer_id')} gpu={offer.get('gpu_name')} "
        f"x{offer.get('num_gpus')} dph={offer.get('dph_total')} location={offer.get('location')}"
    )
    if selected.get("runtime_arch"):
        print(
            f"[vast-select] runtime_tag={selected.get('runtime_tag')} "
            f"runtime_arch={selected.get('runtime_arch')} "
            f"allow_mismatch={selected.get('allow_runtime_gpu_mismatch')}"
        )
    print(f"[vast-select] json={out_path}")
    if args.print_env:
        print(_env_block(selected))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
