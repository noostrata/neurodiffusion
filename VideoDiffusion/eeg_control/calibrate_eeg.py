#!/usr/bin/env python3
"""Collect a local EEG baseline and write threshold suggestions."""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from VideoDiffusion.eeg_control.features import compute_features
    from VideoDiffusion.eeg_control.readers import ReaderContext, add_reader_args, create_reader_from_args
else:
    from .features import compute_features
    from .readers import ReaderContext, add_reader_args, create_reader_from_args


DEFAULT_OUTPUT = "VideoDiffusion/.tmp/eeg_calibration.json"


def _median_abs_dev(xs: list[float]) -> float:
    if not xs:
        return 0.0
    med = statistics.median(xs)
    return statistics.median([abs(x - med) for x in xs])


def _summary(values: list[float]) -> dict[str, float]:
    if not values:
        return {"median": 0.0, "mad": 0.0, "min": 0.0, "max": 0.0}
    return {
        "median": float(statistics.median(values)),
        "mad": float(_median_abs_dev(values)),
        "min": float(min(values)),
        "max": float(max(values)),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Calibrate local EEG thresholds for prompt control.")
    add_reader_args(parser)
    parser.add_argument("--duration-s", type=float, default=30.0)
    parser.add_argument("--window-s", type=float, default=2.0)
    parser.add_argument("--step-s", type=float, default=0.5)
    parser.add_argument("--label", default="baseline")
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)

    snapshots = []
    started = time.monotonic()
    reader = create_reader_from_args(args)

    with ReaderContext(reader) as eeg:
        sample_count = int(round(args.window_s * eeg.sampling_rate))
        time.sleep(min(args.window_s, 2.0))
        while (time.monotonic() - started) < args.duration_s:
            raw = eeg.get_window(sample_count)
            if raw is not None:
                snapshots.append(compute_features(raw, eeg.sampling_rate))
                print(f"[calibrate] collected={len(snapshots)}")
            time.sleep(args.step_s)

    if not snapshots:
        raise SystemExit("[error] no EEG windows collected")

    alpha_beta = [s.alpha_beta_ratio for s in snapshots]
    beta_alpha = [s.beta_alpha_ratio for s in snapshots]
    engagement = [s.engagement_ratio for s in snapshots]
    p2p = [s.peak_to_peak_uv for s in snapshots]
    rms = [s.rms_uv for s in snapshots]

    p2p_summary = _summary(p2p)
    rms_summary = _summary(rms)
    alpha_beta_summary = _summary(alpha_beta)
    beta_alpha_summary = _summary(beta_alpha)
    engagement_summary = _summary(engagement)

    thresholds = {
        "calm_alpha_beta_min": max(1.20, alpha_beta_summary["median"] + alpha_beta_summary["mad"]),
        "active_beta_alpha_min": max(1.20, beta_alpha_summary["median"] + beta_alpha_summary["mad"]),
        "active_engagement_min": max(0.80, engagement_summary["median"] + engagement_summary["mad"]),
        "switch_peak_to_peak_uv_min": max(125.0, p2p_summary["median"] + (4.0 * p2p_summary["mad"])),
        "switch_rms_uv_min": max(55.0, rms_summary["median"] + (4.0 * rms_summary["mad"])),
    }

    output = {
        "label": args.label,
        "created_at": time.time(),
        "board": args.board,
        "window_s": args.window_s,
        "step_s": args.step_s,
        "sample_windows": len(snapshots),
        "stats": {
            "alpha_beta_ratio": alpha_beta_summary,
            "beta_alpha_ratio": beta_alpha_summary,
            "engagement_ratio": engagement_summary,
            "peak_to_peak_uv": p2p_summary,
            "rms_uv": rms_summary,
        },
        "thresholds": thresholds,
    }

    out_path = Path(args.output).expanduser()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[calibrate] wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
