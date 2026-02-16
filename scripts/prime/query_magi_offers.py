#!/usr/bin/env python3
"""
Query Prime Intellect availability for MAGI policy candidates and emit normalized scans.
"""

from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class QueryTarget:
    gpu_type: str
    gpu_count: int
    region: str


def _load_policy(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"[error] Policy file not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _tiers(policy: dict[str, Any]) -> dict[str, Any]:
    tiers = policy.get("tiers")
    if not isinstance(tiers, dict):
        raise SystemExit("[error] Policy missing object field 'tiers'.")
    return tiers


def _targets_for_tier(policy: dict[str, Any], tier: str, regions: list[str]) -> list[QueryTarget]:
    tiers = _tiers(policy)
    if tier not in tiers:
        raise SystemExit(f"[error] Unsupported tier '{tier}'. Available: {', '.join(sorted(tiers))}")

    tier_cfg = tiers[tier]
    candidates = tier_cfg.get("candidates", [])
    out: list[QueryTarget] = []
    for c in candidates:
        gpu_type = str(c.get("gpu_type", "")).strip()
        counts = c.get("gpu_counts", [])
        if not gpu_type or not isinstance(counts, list):
            continue
        for count in counts:
            try:
                n = int(count)
            except Exception:
                continue
            if n <= 0:
                continue
            for region in regions:
                out.append(QueryTarget(gpu_type=gpu_type, gpu_count=n, region=region))
    return out


def _run_prime_query(target: QueryTarget) -> tuple[dict[str, Any] | list[Any] | None, str | None]:
    cmd = [
        "prime",
        "availability",
        "list",
        "--gpu-type",
        target.gpu_type,
        "--gpu-count",
        str(target.gpu_count),
        "--regions",
        target.region,
        "-o",
        "json",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return None, proc.stderr.strip() or proc.stdout.strip() or "prime availability list failed"
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return None, f"json parse error: {exc}"
    return payload, None


def _parse_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except Exception:
        return None


def _extract_resources(payload: dict[str, Any] | list[Any]) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [x for x in payload if isinstance(x, dict)]
    if not isinstance(payload, dict):
        return []
    candidates = (
        payload.get("gpu_resources"),
        payload.get("gpuResources"),
        payload.get("resources"),
        payload.get("data"),
    )
    for c in candidates:
        if isinstance(c, list):
            return [x for x in c if isinstance(x, dict)]
    return []


def _normalize_resource(
    tier: str, target: QueryTarget, resource: dict[str, Any], query_elapsed_s: float
) -> dict[str, Any]:
    price_value = _parse_float(resource.get("price_value"))
    if price_value is None:
        price_value = _parse_float(resource.get("price_per_hour"))

    gpu_count = resource.get("gpu_count")
    if gpu_count is None:
        gpu_count = target.gpu_count
    try:
        gpu_count = int(gpu_count)
    except Exception:
        gpu_count = target.gpu_count

    return {
        "tier": tier,
        "query_gpu_type": target.gpu_type,
        "query_gpu_count": target.gpu_count,
        "query_region": target.region,
        "availability_id": resource.get("id") or resource.get("availability_id"),
        "cloud_id": resource.get("cloud_id"),
        "gpu_type": resource.get("gpu_type") or target.gpu_type,
        "gpu_count": gpu_count,
        "region": resource.get("region") or target.region,
        "location": resource.get("location"),
        "provider": resource.get("provider"),
        "socket": resource.get("socket"),
        "price_value": price_value,
        "price_per_hour": resource.get("price_per_hour"),
        "stock_status": resource.get("stock_status"),
        "security": resource.get("security"),
        "vcpus": resource.get("vcpus"),
        "memory_gb": resource.get("memory_gb"),
        "disk_gb": resource.get("disk_gb"),
        "gpu_memory": resource.get("gpu_memory"),
        "is_spot": resource.get("is_spot"),
        "query_elapsed_s": query_elapsed_s,
    }


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
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
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for row in rows:
            w.writerow({k: row.get(k) for k in fields})


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
    policy = _load_policy(policy_path)

    if args.regions.strip():
        regions = [r.strip() for r in args.regions.split(",") if r.strip()]
    else:
        regions = list(policy.get("regions_default", []))
    if not regions:
        raise SystemExit("[error] No regions configured.")

    targets = _targets_for_tier(policy, args.tier, regions)
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
    scans: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []

    for target in targets:
        t0 = time.monotonic()
        payload, err = _run_prime_query(target)
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

        for resource in _extract_resources(payload):
            scans.append(_normalize_resource(args.tier, target, resource, elapsed))

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

    _write_json(out_json, result)
    _write_csv(out_csv, scans)

    print(f"[query] tier={args.tier} targets={len(targets)} offers={len(scans)} errors={len(errors)}")
    print(f"[query] json={out_json}")
    print(f"[query] csv={out_csv}")
    if errors:
        print("[query] warnings:")
        for e in errors[:10]:
            print(
                f"  - {e['gpu_type']} x{e['gpu_count']} region={e['region']}: {e['error']}",
                file=sys.stderr,
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
