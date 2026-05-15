#!/usr/bin/env python3
"""
Select a Prime offer deterministically from a model-aware video query scan.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from offer_common import default_policy, export_env_block, load_json, select_offer, slug


def _default_out_path(repo_root: Path, model: str, tier: str) -> Path:
    return repo_root / "VideoDiffusion" / ".tmp" / f"video_selected_offer_{slug(model)}_{slug(tier)}.json"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, choices=["magi", "krea"])
    parser.add_argument("--scan-json", required=True, help="Output from query_video_offers.py")
    parser.add_argument("--tier", default="", help="Tier override (optional)")
    parser.add_argument("--policy", default="")
    parser.add_argument("--out-json", default="")
    parser.add_argument(
        "--selection-goal",
        default="realtime",
        choices=["realtime", "cost"],
        help="Offer selection profile. realtime enforces policy realtime_min_nproc.",
    )
    parser.add_argument(
        "--min-gpu-count",
        type=int,
        default=0,
        help="Optional hard lower bound for gpu_count (overrides policy minima when larger).",
    )
    parser.add_argument("--print-env", action="store_true", help="Print KEY=VALUE exports for shell eval")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    scan_path = Path(args.scan_json).expanduser()
    if args.policy:
        policy_path = Path(args.policy).expanduser()
        if not policy_path.is_absolute():
            policy_path = (repo_root / policy_path).resolve()
    else:
        policy_path = default_policy(repo_root, args.model)

    scan = load_json(scan_path)
    policy = load_json(policy_path)

    tier = args.tier.strip() or str(scan.get("tier", "")).strip()
    if not tier:
        raise SystemExit("[error] scan JSON missing 'tier'.")

    selected = select_offer(
        scan=scan,
        policy=policy,
        tier=tier,
        selection_goal=args.selection_goal,
        min_gpu_count_override=max(0, int(args.min_gpu_count)),
        realtime_rank_first=True,
    )
    if not selected.get("model"):
        selected["model"] = args.model

    out_path = (
        Path(args.out_json).expanduser()
        if args.out_json
        else _default_out_path(repo_root, args.model, tier)
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(selected, f, indent=2)

    offer = selected["selected_offer"]
    print(
        f"[select] model={args.model} tier={tier} id={offer.get('availability_id')} "
        f"gpu={offer.get('gpu_type')} x{offer.get('gpu_count')} "
        f"region={offer.get('region')} rate={offer.get('price_value')} "
        f"attn={offer.get('preferred_attention', 'auto')}"
    )
    print(f"[select] json={out_path}")
    if args.print_env:
        print(export_env_block(selected, include_model=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
