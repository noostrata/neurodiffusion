#!/usr/bin/env python3
"""Drive MAGI-compatible video prompts from OpenBCI/BrainFlow EEG features."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from VideoDiffusion.eeg_control.features import ExponentialFeatureSmoother, compute_features
    from VideoDiffusion.eeg_control.prompt_controller import PromptController, load_json_file
    from VideoDiffusion.eeg_control.readers import ReaderContext, add_reader_args, create_reader_from_args
    from VideoDiffusion.eeg_control.video_client import VideoControlClient
else:
    from .features import ExponentialFeatureSmoother, compute_features
    from .prompt_controller import PromptController, load_json_file
    from .readers import ReaderContext, add_reader_args, create_reader_from_args
    from .video_client import VideoControlClient


DEFAULT_PROMPT_MAP = Path(__file__).with_name("prompt_map.example.json")


def _load_calibration(path: str) -> dict | None:
    if not path:
        return None
    return load_json_file(path)


def _open_log(path: str):
    if not path:
        return None
    p = Path(path).expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    return p.open("a", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Map OpenBCI/EEG features to video prompt updates.")
    add_reader_args(parser)
    parser.add_argument("--url", default="http://127.0.0.1:8765", help="MAGI/fake video control base URL")
    parser.add_argument("--prompt-map", default=str(DEFAULT_PROMPT_MAP), help="Prompt map JSON")
    parser.add_argument("--calibration", default="", help="Optional calibration JSON from calibrate_eeg.py")
    parser.add_argument("--duration-s", type=float, default=0.0, help="Stop after this many seconds; 0 means run until Ctrl-C")
    parser.add_argument("--window-s", type=float, default=2.0, help="EEG feature window length")
    parser.add_argument("--step-s", type=float, default=0.5, help="Seconds between feature decisions")
    parser.add_argument("--warmup-s", type=float, default=2.0, help="Warmup before first decision")
    parser.add_argument("--smoothing-alpha", type=float, default=0.35, help="EMA feature smoothing alpha")
    parser.add_argument("--cooldown-s", type=float, default=None, help="Override prompt cooldown")
    parser.add_argument("--consecutive-windows", type=int, default=None, help="Override stability window count")
    parser.add_argument("--dry-run", action="store_true", help="Classify and log without sending prompts")
    parser.add_argument("--log-jsonl", default="VideoDiffusion/.tmp/eeg_prompt_control.jsonl")
    parser.add_argument("--print-every", type=int, default=1, help="Print every N decisions")
    args = parser.parse_args(argv)

    if args.window_s <= 0 or args.step_s <= 0:
        raise SystemExit("[error] --window-s and --step-s must be positive")

    prompt_map = load_json_file(args.prompt_map)
    calibration = _load_calibration(args.calibration)
    controller = PromptController(
        prompt_map,
        calibration=calibration,
        cooldown_s=args.cooldown_s,
        consecutive_windows=args.consecutive_windows,
    )
    smoother = ExponentialFeatureSmoother(args.smoothing_alpha)
    client = VideoControlClient(args.url)
    reader = create_reader_from_args(args)
    log_f = _open_log(args.log_jsonl)

    started = time.monotonic()
    seq = 0
    try:
        with ReaderContext(reader) as eeg:
            sample_count = int(round(args.window_s * eeg.sampling_rate))
            if sample_count < 8:
                raise SystemExit("[error] feature window is too small for this sampling rate")
            if args.warmup_s > 0:
                time.sleep(args.warmup_s)

            while True:
                if args.duration_s > 0 and (time.monotonic() - started) >= args.duration_s:
                    break
                raw = eeg.get_window(sample_count)
                if raw is None:
                    time.sleep(min(args.step_s, 0.25))
                    continue

                features = smoother.update(compute_features(raw, eeg.sampling_rate))
                decision = controller.update(features)
                sent = None
                error = None

                if decision.should_send and decision.prompt:
                    if args.dry_run:
                        sent = {"dry_run": True, "prompt": decision.prompt}
                    else:
                        try:
                            sent = client.set_prompt(decision.prompt)
                        except Exception as exc:
                            error = str(exc)

                stats = None
                if not args.dry_run:
                    try:
                        stats = client.get_stats()
                    except Exception as exc:
                        if error is None:
                            error = str(exc)

                record = {
                    "ts": time.time(),
                    "seq": seq,
                    "board": args.board,
                    "state": decision.state,
                    "reason": decision.reason,
                    "candidate_count": decision.candidate_count,
                    "should_send": decision.should_send,
                    "prompt": decision.prompt,
                    "sent": sent,
                    "stats": stats,
                    "error": error,
                    "features": features.to_jsonable(),
                }
                if log_f is not None:
                    log_f.write(json.dumps(record, sort_keys=True) + "\n")
                    log_f.flush()

                if args.print_every > 0 and (seq % args.print_every == 0):
                    marker = "SEND" if decision.should_send else "hold"
                    if error:
                        marker = "error"
                    print(
                        f"[{seq:05d}] {marker:5s} state={decision.state:12s} "
                        f"count={decision.candidate_count:02d} "
                        f"alpha_beta={features.alpha_beta_ratio:.2f} "
                        f"beta_alpha={features.beta_alpha_ratio:.2f} "
                        f"p2p={features.peak_to_peak_uv:.1f}uv | {decision.reason}"
                    )

                seq += 1
                time.sleep(args.step_s)
    finally:
        if log_f is not None:
            log_f.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
