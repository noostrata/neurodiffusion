#!/usr/bin/env python3
"""
Select a Prime offer deterministically from a query scan for a MAGI tier.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def _load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"[error] File not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _load_policy(path: Path) -> dict[str, Any]:
    return _load_json(path)


def _region_rank(regions: list[str]) -> dict[str, int]:
    return {r: i for i, r in enumerate(regions)}


def _select_offer(
    scan: dict[str, Any],
    policy: dict[str, Any],
    tier: str,
) -> dict[str, Any]:
    tiers = policy.get("tiers", {})
    if tier not in tiers:
        raise SystemExit(f"[error] Tier '{tier}' missing in policy.")
    tier_cfg = tiers[tier]
    min_viable = int(tier_cfg.get("min_viable_nproc", 1))
    region_order = list(policy.get("regions_default", []))
    region_idx = _region_rank(region_order)

    offers = scan.get("offers", [])
    filtered: list[dict[str, Any]] = []
    for o in offers:
        try:
            gpu_count = int(o.get("gpu_count"))
            price = float(o.get("price_value"))
        except Exception:
            continue
        if gpu_count < min_viable:
            continue
        if price <= 0:
            continue
        filtered.append(o)

    if not filtered:
        raise SystemExit(
            f"[error] No offers satisfy min_viable_nproc={min_viable} for tier={tier}. "
            "Try a broader region set or a different tier."
        )

    def sort_key(o: dict[str, Any]) -> tuple:
        price = float(o.get("price_value"))
        gpu_count = int(o.get("gpu_count"))
        region = str(o.get("region", ""))
        provider = str(o.get("provider", ""))
        return (
            price,  # lower first
            -gpu_count,  # higher first
            region_idx.get(region, 10**6),  # preferred region order
            provider,  # lexical
        )

    best = sorted(filtered, key=sort_key)[0]
    return {
        "tier": tier,
        "min_viable_nproc": min_viable,
        "selected_offer": best,
        "selection_rule": [
            "lower price_value first",
            "then higher gpu_count",
            "then preferred region order",
            "then provider lexical",
        ],
        "candidate_count": len(filtered),
    }


def _default_out_path(repo_root: Path, tier: str) -> Path:
    return repo_root / "VideoDiffusion" / ".tmp" / f"magi_selected_offer_{tier}.json"


def _export_env_block(selected: dict[str, Any]) -> str:
    offer = selected["selected_offer"]
    availability_id = str(offer.get("availability_id", "")).strip()
    gpu_type = str(offer.get("gpu_type", "")).strip()
    gpu_count = int(offer.get("gpu_count"))
    rate = float(offer.get("price_value"))
    region = str(offer.get("region", "")).strip()
    provider = str(offer.get("provider", "")).strip()
    cloud_id = str(offer.get("cloud_id", "")).strip()
    return "\n".join(
        [
            f"PRIME_AVAILABILITY_ID={availability_id}",
            f"SELECTED_GPU_TYPE={gpu_type}",
            f"SELECTED_GPU_COUNT={gpu_count}",
            f"HOURLY_RATE_USD={rate}",
            f"SELECTED_REGION={region}",
            f"SELECTED_PROVIDER={provider}",
            f"SELECTED_CLOUD_ID={cloud_id}",
        ]
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scan-json", required=True, help="Output from query_magi_offers.py")
    parser.add_argument("--tier", default="", choices=["4.5b", "24b"], help="Tier override (optional)")
    parser.add_argument("--policy", default="scripts/prime/magi_gpu_policies.json")
    parser.add_argument("--out-json", default="")
    parser.add_argument("--print-env", action="store_true", help="Print KEY=VALUE exports for shell eval")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    scan_path = Path(args.scan_json).expanduser()
    policy_path = (repo_root / args.policy).resolve() if not Path(args.policy).is_absolute() else Path(args.policy)
    scan = _load_json(scan_path)
    policy = _load_policy(policy_path)

    tier = args.tier.strip() or str(scan.get("tier", "")).strip()
    if not tier:
        raise SystemExit("[error] scan JSON missing 'tier'.")

    selected = _select_offer(scan, policy, tier)
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
        print(_export_env_block(selected))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
