#!/usr/bin/env python3
"""
Select a Prime offer deterministically from a query scan for a MAGI tier.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from offer_common import export_env_block, load_json, load_policy, select_offer


def _default_out_path(repo_root: Path, tier: str) -> Path:
    return repo_root / "VideoDiffusion" / ".tmp" / f"magi_selected_offer_{tier}.json"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scan-json", required=True, help="Output from query_magi_offers.py")
    parser.add_argument("--tier", default="", choices=["4.5b", "24b"], help="Tier override (optional)")
    parser.add_argument("--policy", default="scripts/prime/magi_gpu_policies.json")
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
    parser.add_argument(
        "--exclude-availability-ids",
        default="",
        help="Comma-separated availability IDs to exclude from selection (used for retry after stale offers).",
    )
    parser.add_argument("--print-env", action="store_true", help="Print KEY=VALUE exports for shell eval")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    scan_path = Path(args.scan_json).expanduser()
    policy_path = (repo_root / args.policy).resolve() if not Path(args.policy).is_absolute() else Path(args.policy)
    scan = load_json(scan_path)
    policy = load_policy(policy_path)

    tier = args.tier.strip() or str(scan.get("tier", "")).strip()
    if not tier:
        raise SystemExit("[error] scan JSON missing 'tier'.")

    excluded_ids = {v.strip() for v in str(args.exclude_availability_ids).split(",") if v.strip()}
    selected = select_offer(
        scan=scan,
        policy=policy,
        tier=tier,
        selection_goal=args.selection_goal,
        min_gpu_count_override=max(0, int(args.min_gpu_count)),
        exclude_availability_ids=excluded_ids,
        realtime_rank_first=False,
    )

    out_path = Path(args.out_json).expanduser() if args.out_json else _default_out_path(repo_root, tier)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(selected, f, indent=2)

    offer = selected["selected_offer"]
    print(
        f"[select] tier={tier} id={offer.get('availability_id')} "
        f"gpu={offer.get('gpu_type')} x{offer.get('gpu_count')} "
        f"region={offer.get('region')} rate={offer.get('price_value')}"
    )
    print(f"[select] json={out_path}")
    if args.print_env:
        print(export_env_block(selected, include_model=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
