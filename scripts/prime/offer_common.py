#!/usr/bin/env python3
"""
Shared Prime Intellect offer query/selection helpers.

The public entrypoints stay as thin CLI scripts so existing runbooks and shell
wrappers keep working, while the parsing and deterministic selection rules live
in one place.
"""

from __future__ import annotations

import csv
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class QueryTarget:
    gpu_type: str
    gpu_count: int
    region: str
    rank_hint: int = 999999
    preferred_attention: str = "auto"


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"[error] File not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def load_policy(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"[error] Policy file not found: {path}")
    return load_json(path)


def default_policy(repo_root: Path, model: str) -> Path:
    if model == "krea":
        return repo_root / "scripts/prime/krea_gpu_policies.json"
    return repo_root / "scripts/prime/magi_gpu_policies.json"


def tiers(policy: dict[str, Any]) -> dict[str, Any]:
    tier_map = policy.get("tiers")
    if not isinstance(tier_map, dict):
        raise SystemExit("[error] Policy missing object field 'tiers'.")
    return tier_map


def targets_for_tier(policy: dict[str, Any], tier: str, regions: list[str]) -> list[QueryTarget]:
    tier_map = tiers(policy)
    if tier not in tier_map:
        raise SystemExit(f"[error] Unsupported tier '{tier}'. Available: {', '.join(sorted(tier_map))}")

    out: list[QueryTarget] = []
    for candidate in tier_map[tier].get("candidates", []):
        gpu_type = str(candidate.get("gpu_type", "")).strip()
        counts = candidate.get("gpu_counts", [])
        if not gpu_type or not isinstance(counts, list):
            continue
        rank_hint = int(candidate.get("rank_hint", 999999))
        preferred_attention = str(candidate.get("preferred_attention", "auto")).strip() or "auto"
        for count in counts:
            try:
                gpu_count = int(count)
            except Exception:
                continue
            if gpu_count <= 0:
                continue
            for region in regions:
                out.append(
                    QueryTarget(
                        gpu_type=gpu_type,
                        gpu_count=gpu_count,
                        region=region,
                        rank_hint=rank_hint,
                        preferred_attention=preferred_attention,
                    )
                )
    return out


def run_prime_query(target: QueryTarget) -> tuple[dict[str, Any] | list[Any] | None, str | None]:
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


def parse_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except Exception:
        return None


def extract_resources(payload: dict[str, Any] | list[Any]) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [x for x in payload if isinstance(x, dict)]
    if not isinstance(payload, dict):
        return []
    for candidate in (
        payload.get("gpu_resources"),
        payload.get("gpuResources"),
        payload.get("resources"),
        payload.get("data"),
    ):
        if isinstance(candidate, list):
            return [x for x in candidate if isinstance(x, dict)]
    return []


def normalize_resource(
    *,
    model: str | None,
    tier: str,
    target: QueryTarget,
    resource: dict[str, Any],
    query_elapsed_s: float,
) -> dict[str, Any]:
    price_value = parse_float(resource.get("price_value"))
    if price_value is None:
        price_value = parse_float(resource.get("price_per_hour"))

    gpu_count = resource.get("gpu_count")
    if gpu_count is None:
        gpu_count = target.gpu_count
    try:
        gpu_count = int(gpu_count)
    except Exception:
        gpu_count = target.gpu_count

    row = {
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
        "rank_hint": target.rank_hint,
        "preferred_attention": target.preferred_attention,
    }
    if model is not None:
        row["model"] = model
    return row


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)


def write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k) for k in fields})


def slug(raw: str) -> str:
    return "".join(c if c.isalnum() else "_" for c in raw).strip("_").lower() or "default"


def region_rank(regions: list[str]) -> dict[str, int]:
    return {region: i for i, region in enumerate(regions)}


def select_offer(
    *,
    scan: dict[str, Any],
    policy: dict[str, Any],
    tier: str,
    selection_goal: str,
    min_gpu_count_override: int,
    exclude_availability_ids: set[str] | None = None,
    realtime_rank_first: bool = False,
) -> dict[str, Any]:
    tier_map = policy.get("tiers", {})
    if tier not in tier_map:
        raise SystemExit(f"[error] Tier '{tier}' missing in policy.")

    tier_cfg = tier_map[tier]
    min_viable = int(tier_cfg.get("min_viable_nproc", 1))
    realtime_min = int(tier_cfg.get("realtime_min_nproc", min_viable))
    required_gpu_count = min_viable
    if selection_goal == "realtime":
        required_gpu_count = max(required_gpu_count, realtime_min)
    if min_gpu_count_override > 0:
        required_gpu_count = max(required_gpu_count, min_gpu_count_override)

    excluded = exclude_availability_ids or set()
    region_idx = region_rank(list(policy.get("regions_default", [])))
    filtered: list[dict[str, Any]] = []
    excluded_count = 0
    for offer in scan.get("offers", []):
        try:
            gpu_count = int(offer.get("gpu_count"))
            price = float(offer.get("price_value"))
        except Exception:
            continue
        availability_id = str(offer.get("availability_id", "")).strip()
        if availability_id and availability_id in excluded:
            excluded_count += 1
            continue
        if gpu_count < required_gpu_count:
            continue
        if price <= 0:
            continue
        filtered.append(offer)

    if not filtered:
        raise SystemExit(
            f"[error] No offers satisfy required_gpu_count={required_gpu_count} for tier={tier}. "
            f"Excluded availability ids={len(excluded)} matched={excluded_count}. "
            "Try a broader region set, reduce minimum GPU count, or use --selection-goal cost."
        )

    def rank_hint(offer: dict[str, Any]) -> int:
        try:
            return int(offer.get("rank_hint", 999999))
        except Exception:
            return 999999

    def sort_key(offer: dict[str, Any]) -> tuple:
        price = float(offer.get("price_value"))
        gpu_count = int(offer.get("gpu_count"))
        region = str(offer.get("region", ""))
        provider = str(offer.get("provider", ""))
        if realtime_rank_first and selection_goal == "realtime":
            return (
                rank_hint(offer),
                price,
                -gpu_count,
                region_idx.get(region, 10**6),
                provider,
            )
        return (
            price,
            rank_hint(offer) if realtime_rank_first else 0,
            -gpu_count,
            region_idx.get(region, 10**6),
            provider,
        )

    best = sorted(filtered, key=sort_key)[0]
    return {
        "model": scan.get("model"),
        "tier": tier,
        "selection_goal": selection_goal,
        "min_viable_nproc": min_viable,
        "realtime_min_nproc": realtime_min,
        "required_gpu_count": required_gpu_count,
        "selected_offer": best,
        "selection_rule": [
            "realtime_rank_first: rank_hint -> lower price_value -> higher gpu_count -> region order -> provider lexical",
            "default: lower price_value -> higher gpu_count -> region order -> provider lexical",
        ],
        "candidate_count": len(filtered),
        "excluded_availability_ids": sorted(excluded),
    }


def export_env_block(selected: dict[str, Any], *, include_model: bool) -> str:
    offer = selected["selected_offer"]
    availability_id = str(offer.get("availability_id", "")).strip()
    gpu_type = str(offer.get("gpu_type", "")).strip()
    gpu_count = int(offer.get("gpu_count"))
    rate = float(offer.get("price_value"))
    region = str(offer.get("region", "")).strip()
    provider = str(offer.get("provider", "")).strip()
    cloud_id = str(offer.get("cloud_id", "")).strip()

    lines: list[str] = []
    if include_model:
        model = str(selected.get("model") or offer.get("model") or "magi").strip()
        attn = str(offer.get("preferred_attention", "auto")).strip() or "auto"
        lines.extend([f"VIDEO_MODEL={model}", f"ATTN_BACKEND={attn}"])

    lines.extend(
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
    return "\n".join(lines)
