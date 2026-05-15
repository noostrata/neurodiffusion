#!/usr/bin/env python3
"""
Query Prime Intellect availability for MAGI policy candidates and emit normalized scans.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from offer_common import (
    extract_resources,
    load_policy,
    normalize_resource,
    run_prime_query,
    targets_for_tier,
    write_csv,
    write_json,
)


CSV_FIELDS = [
    "tier",
    "availability_id",
    "cloud_id",
    "gpu_type",
    "gpu_count",
    "region",
    "location",
    "provider",
    "socket",
    "price_value",
    "price_per_hour",
    "stock_status",
    "is_spot",
    "query_gpu_type",
    "query_gpu_count",
    "query_region",
    "query_elapsed_s",
]


def _default_out_paths(repo_root: Path, tier: str) -> tuple[Path, Path]:
    out_dir = repo_root / "VideoDiffusion" / ".tmp"
    return out_dir / f"magi_offer_scan_{tier}.json", out_dir / f"magi_offer_scan_{tier}.csv"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tier", required=True, choices=["4.5b", "24b"])
    parser.add_argument("--policy", default="scripts/prime/magi_gpu_policies.json")
    parser.add_argument("--regions", default="", help="Comma-separated regions override")
    parser.add_argument("--out-json", default="", help="Output JSON path")
    parser.add_argument("--out-csv", default="", help="Output CSV path")
    parser.add_argument("--dry-run", action="store_true", help="Discovery only; still writes scan artifacts")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    policy_path = (repo_root / args.policy).resolve() if not Path(args.policy).is_absolute() else Path(args.policy)
    policy = load_policy(policy_path)

    if args.regions.strip():
        regions = [r.strip() for r in args.regions.split(",") if r.strip()]
    else:
        regions = list(policy.get("regions_default", []))
    if not regions:
        raise SystemExit("[error] No regions configured.")

    targets = targets_for_tier(policy, args.tier, regions)
    if not targets:
        raise SystemExit("[error] No query targets generated from policy.")

    if args.out_json:
        out_json = Path(args.out_json).expanduser()
    else:
        out_json, _ = _default_out_paths(repo_root, args.tier)
    if args.out_csv:
        out_csv = Path(args.out_csv).expanduser()
    else:
        _, out_csv = _default_out_paths(repo_root, args.tier)

    started = int(time.time())
    scans: list[dict] = []
    errors: list[dict] = []

    for target in targets:
        t0 = time.monotonic()
        payload, err = run_prime_query(target)
        elapsed = time.monotonic() - t0
        if err is not None:
            errors.append(
                {
                    "gpu_type": target.gpu_type,
                    "gpu_count": target.gpu_count,
                    "region": target.region,
                    "error": err,
                }
            )
            continue

        assert payload is not None
        for resource in extract_resources(payload):
            scans.append(
                normalize_resource(
                    model=None,
                    tier=args.tier,
                    target=target,
                    resource=resource,
                    query_elapsed_s=elapsed,
                )
            )

    result = {
        "tier": args.tier,
        "policy_path": str(policy_path),
        "regions": regions,
        "query_targets": [t.__dict__ for t in targets],
        "offer_count": len(scans),
        "error_count": len(errors),
        "errors": errors,
        "offers": scans,
        "generated_at_epoch_s": started,
        "dry_run": bool(args.dry_run),
    }

    write_json(out_json, result)
    write_csv(out_csv, scans, CSV_FIELDS)

    print(f"[query] tier={args.tier} targets={len(targets)} offers={len(scans)} errors={len(errors)}")
    print(f"[query] json={out_json}")
    print(f"[query] csv={out_csv}")
    if errors:
        print("[query] warnings:")
        for error in errors[:10]:
            print(
                f"  - {error['gpu_type']} x{error['gpu_count']} region={error['region']}: {error['error']}",
                file=sys.stderr,
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
