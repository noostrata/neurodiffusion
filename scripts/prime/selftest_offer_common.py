#!/usr/bin/env python3
"""
Small no-network tests for Prime offer selection invariants.
"""

from __future__ import annotations

from offer_common import QueryTarget, normalize_resource, select_offer, targets_for_tier


def _policy() -> dict:
    return {
        "regions_default": ["eu_north", "united_states"],
        "tiers": {
            "4.5b": {
                "min_viable_nproc": 1,
                "realtime_min_nproc": 4,
                "candidates": [
                    {"gpu_type": "A100_80GB", "gpu_counts": [1, 4]},
                    {"gpu_type": "H100_80GB", "gpu_counts": [4]},
                ],
            },
            "realtime": {
                "min_viable_nproc": 1,
                "realtime_min_nproc": 1,
                "candidates": [
                    {"gpu_type": "B200_180GB", "gpu_counts": [1], "rank_hint": 1, "preferred_attention": "flash"},
                    {"gpu_type": "H100_80GB", "gpu_counts": [1], "rank_hint": 2, "preferred_attention": "sage"},
                ],
            },
        },
    }


def _scan(*offers: dict, model: str | None = None, tier: str = "4.5b") -> dict:
    out = {"tier": tier, "offers": list(offers)}
    if model is not None:
        out["model"] = model
    return out


def test_targets_preserve_model_policy_metadata() -> None:
    targets = targets_for_tier(_policy(), "realtime", ["eu_north"])
    assert len(targets) == 2
    assert targets[0].gpu_type == "B200_180GB"
    assert targets[0].rank_hint == 1
    assert targets[0].preferred_attention == "flash"


def test_normalize_resource_falls_back_to_query_values() -> None:
    row = normalize_resource(
        model="krea",
        tier="realtime",
        target=QueryTarget("H100_80GB", 1, "eu_north", rank_hint=2, preferred_attention="sage"),
        resource={"id": "abc123", "price_per_hour": "2.29"},
        query_elapsed_s=0.5,
    )
    assert row["model"] == "krea"
    assert row["availability_id"] == "abc123"
    assert row["gpu_type"] == "H100_80GB"
    assert row["gpu_count"] == 1
    assert row["region"] == "eu_north"
    assert row["price_value"] == 2.29
    assert row["preferred_attention"] == "sage"


def test_magi_selection_is_price_first() -> None:
    selected = select_offer(
        scan=_scan(
            {"availability_id": "expensive", "gpu_count": 4, "price_value": 10, "region": "eu_north", "provider": "a"},
            {"availability_id": "cheap", "gpu_count": 4, "price_value": 5, "region": "eu_north", "provider": "b"},
        ),
        policy=_policy(),
        tier="4.5b",
        selection_goal="realtime",
        min_gpu_count_override=0,
        realtime_rank_first=False,
    )
    assert selected["selected_offer"]["availability_id"] == "cheap"
    assert selected["required_gpu_count"] == 4


def test_magi_selection_excludes_stale_ids() -> None:
    selected = select_offer(
        scan=_scan(
            {"availability_id": "stale", "gpu_count": 4, "price_value": 1, "region": "eu_north", "provider": "a"},
            {"availability_id": "fresh", "gpu_count": 4, "price_value": 2, "region": "eu_north", "provider": "b"},
        ),
        policy=_policy(),
        tier="4.5b",
        selection_goal="realtime",
        min_gpu_count_override=0,
        exclude_availability_ids={"stale"},
        realtime_rank_first=False,
    )
    assert selected["selected_offer"]["availability_id"] == "fresh"


def test_video_realtime_selection_is_rank_first() -> None:
    selected = select_offer(
        scan=_scan(
            {
                "availability_id": "b200",
                "gpu_count": 1,
                "price_value": 4.89,
                "rank_hint": 1,
                "preferred_attention": "flash",
                "region": "eu_north",
                "provider": "a",
            },
            {
                "availability_id": "h100",
                "gpu_count": 1,
                "price_value": 2.29,
                "rank_hint": 2,
                "preferred_attention": "sage",
                "region": "eu_north",
                "provider": "b",
            },
            model="krea",
            tier="realtime",
        ),
        policy=_policy(),
        tier="realtime",
        selection_goal="realtime",
        min_gpu_count_override=0,
        realtime_rank_first=True,
    )
    assert selected["selected_offer"]["availability_id"] == "b200"


def test_video_cost_selection_is_price_first() -> None:
    selected = select_offer(
        scan=_scan(
            {"availability_id": "b200", "gpu_count": 1, "price_value": 4.89, "rank_hint": 1, "region": "eu_north", "provider": "a"},
            {"availability_id": "h100", "gpu_count": 1, "price_value": 2.29, "rank_hint": 2, "region": "eu_north", "provider": "b"},
            model="krea",
            tier="realtime",
        ),
        policy=_policy(),
        tier="realtime",
        selection_goal="cost",
        min_gpu_count_override=0,
        realtime_rank_first=True,
    )
    assert selected["selected_offer"]["availability_id"] == "h100"


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"[ok] {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
