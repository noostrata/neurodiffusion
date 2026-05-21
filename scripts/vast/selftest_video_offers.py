#!/usr/bin/env python3
"""
No-network tests for Vast video offer selection.
"""

from __future__ import annotations

from select_video_offer import _select


def test_realtime_prefers_gpu_rank_before_price() -> None:
    selected = _select(
        {
            "model": "krea",
            "offers": [
                {"offer_id": "cheap-h100", "gpu_name": "H100_SXM", "num_gpus": 1, "dph_total": 2.2},
                {"offer_id": "b200", "gpu_name": "B200", "num_gpus": 1, "dph_total": 4.8},
            ],
        },
        selection_goal="realtime",
        min_gpu_count=1,
        max_gpu_count=0,
        max_dph=None,
        runtime_tag="",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "b200"


def test_cost_prefers_price_before_gpu_rank() -> None:
    selected = _select(
        {
            "model": "krea",
            "offers": [
                {"offer_id": "cheap-h100", "gpu_name": "H100_SXM", "num_gpus": 1, "dph_total": 2.2},
                {"offer_id": "b200", "gpu_name": "B200", "num_gpus": 1, "dph_total": 4.8},
            ],
        },
        selection_goal="cost",
        min_gpu_count=1,
        max_gpu_count=0,
        max_dph=None,
        runtime_tag="",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "cheap-h100"


def test_min_gpu_count_filter() -> None:
    selected = _select(
        {
            "model": "magi",
            "offers": [
                {"offer_id": "one", "gpu_name": "H100_SXM", "num_gpus": 1, "dph_total": 2.2},
                {"offer_id": "four", "gpu_name": "H100_SXM", "num_gpus": 4, "dph_total": 8.8},
            ],
        },
        selection_goal="cost",
        min_gpu_count=4,
        max_gpu_count=0,
        max_dph=None,
        runtime_tag="",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "four"


def test_max_gpu_count_filter() -> None:
    selected = _select(
        {
            "model": "scope",
            "offers": [
                {"offer_id": "h200x2", "gpu_name": "H200", "num_gpus": 2, "dph_total": 7.7},
                {"offer_id": "h200x1", "gpu_name": "H200", "num_gpus": 1, "dph_total": 4.3},
            ],
        },
        selection_goal="cost",
        min_gpu_count=1,
        max_gpu_count=1,
        max_dph=None,
        runtime_tag="",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "h200x1"


def test_sm80_runtime_tag_filters_to_a100() -> None:
    selected = _select(
        {
            "model": "magi",
            "offers": [
                {"offer_id": "h200", "gpu_name": "H200", "num_gpus": 1, "dph_total": 1.9},
                {"offer_id": "a100", "gpu_name": "A100 80GB", "num_gpus": 1, "dph_total": 1.2},
            ],
        },
        selection_goal="cost",
        min_gpu_count=1,
        max_gpu_count=0,
        max_dph=None,
        runtime_tag="hopper_sm80_py310_torch240_cu124_20260217_prebuild1",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "a100"


def test_scope_cost_accepts_4090_tier() -> None:
    selected = _select(
        {
            "model": "scope",
            "offers": [
                {"offer_id": "l40s", "gpu_name": "L40S", "num_gpus": 1, "dph_total": 1.2},
                {"offer_id": "cheap4090", "gpu_name": "RTX 4090", "num_gpus": 1, "dph_total": 0.7},
            ],
        },
        selection_goal="cost",
        min_gpu_count=1,
        max_gpu_count=0,
        max_dph=None,
        runtime_tag="",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "cheap4090"


def test_longlive2_two_gpu_sm90_filter() -> None:
    selected = _select(
        {
            "model": "longlive2",
            "offers": [
                {"offer_id": "h200x1", "gpu_name": "H200", "num_gpus": 1, "dph_total": 3.8},
                {"offer_id": "h200x2", "gpu_name": "H200", "num_gpus": 2, "dph_total": 7.4},
                {"offer_id": "b200x2", "gpu_name": "B200", "num_gpus": 2, "dph_total": 11.0},
            ],
        },
        selection_goal="cost",
        min_gpu_count=2,
        max_gpu_count=2,
        max_dph=8.0,
        runtime_tag="longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "h200x2"


def test_sm120_runtime_tag_filters_to_5090() -> None:
    selected = _select(
        {
            "model": "longlive2",
            "offers": [
                {"offer_id": "h100", "gpu_name": "H100", "num_gpus": 1, "dph_total": 2.1},
                {"offer_id": "rtx5090", "gpu_name": "RTX 5090", "num_gpus": 1, "dph_total": 1.7},
            ],
        },
        selection_goal="cost",
        min_gpu_count=1,
        max_gpu_count=0,
        max_dph=None,
        runtime_tag="scope_auto_py312_torch2.9.1_cu128_sm120",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "rtx5090"


def test_sm100_runtime_tag_accepts_gb200() -> None:
    selected = _select(
        {
            "model": "longlive2",
            "offers": [
                {"offer_id": "h200", "gpu_name": "H200", "num_gpus": 1, "dph_total": 3.1},
                {"offer_id": "gb200", "gpu_name": "GB200", "num_gpus": 1, "dph_total": 9.5},
            ],
        },
        selection_goal="realtime",
        min_gpu_count=1,
        max_gpu_count=1,
        max_dph=12.0,
        runtime_tag="longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm100_prebuild1",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "gb200"


def test_blackwell_5090_one_gpu_cost_selection() -> None:
    selected = _select(
        {
            "model": "longlive2",
            "offers": [
                {"offer_id": "rtx5090-expensive", "gpu_name": "RTX 5090", "num_gpus": 1, "dph_total": 1.7},
                {"offer_id": "rtx5090-cheap", "gpu_name": "RTX 5090", "num_gpus": 1, "dph_total": 1.1},
                {"offer_id": "rtx5090x2", "gpu_name": "RTX 5090", "num_gpus": 2, "dph_total": 2.0},
            ],
        },
        selection_goal="cost",
        min_gpu_count=1,
        max_gpu_count=1,
        max_dph=2.5,
        runtime_tag="longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm120_prebuild1",
        allow_runtime_gpu_mismatch=False,
    )
    assert selected["selected_offer"]["offer_id"] == "rtx5090-cheap"


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"[ok] {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
