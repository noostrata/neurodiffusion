#!/usr/bin/env python3
"""Systematic neurofeedback session runner for OpenBCI -> art/video control."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from VideoDiffusion.eeg_control.features import ExponentialFeatureSmoother, compute_features
    from VideoDiffusion.eeg_control.policies import available_policies, get_policy
    from VideoDiffusion.eeg_control.readers import ReaderContext, add_reader_args, create_reader_from_args
    from VideoDiffusion.eeg_control.sinks import CompositeSink, JsonlSink, PromptHttpSink, ScheduleCsvSink, ScopeOscSink, StdoutSink
    from VideoDiffusion.eeg_control.state import NeuroStateEstimator
else:
    from .features import ExponentialFeatureSmoother, compute_features
    from .policies import available_policies, get_policy
    from .readers import ReaderContext, add_reader_args, create_reader_from_args
    from .sinks import CompositeSink, JsonlSink, PromptHttpSink, ScheduleCsvSink, ScopeOscSink, StdoutSink
    from .state import NeuroStateEstimator


def _build_sinks(args: argparse.Namespace) -> CompositeSink:
    sinks = []
    sink_names = args.sink or ["stdout", "jsonl"]
    for name in sink_names:
        if name == "stdout":
            sinks.append(StdoutSink())
        elif name == "jsonl":
            sinks.append(JsonlSink(args.log_jsonl))
        elif name == "http":
            sinks.append(PromptHttpSink(args.url, timeout_s=args.http_timeout_s))
        elif name == "scope":
            sinks.append(
                ScopeOscSink(
                    host=args.scope_osc_host,
                    port=args.scope_osc_port,
                    timeout_s=args.scope_osc_timeout_s,
                    transition_steps=args.scope_transition_steps,
                    interpolation_method=args.scope_interpolation_method,
                    send_noise_scale=not args.scope_disable_noise_scale,
                    noise_min=args.scope_noise_min,
                    noise_max=args.scope_noise_max,
                    reset_cache_on_transition=not args.scope_disable_transition_cache_reset,
                    manage_cache=not args.scope_disable_manage_cache,
                )
            )
        elif name == "schedule":
            sinks.append(ScheduleCsvSink(args.schedule_csv, hold_chunks=args.schedule_hold_chunks))
        else:
            raise ValueError(f"Unknown sink: {name}")
    return CompositeSink(sinks)


class EmitGate:
    def __init__(self, *, cooldown_s: float, consecutive_windows: int):
        self.cooldown_s = cooldown_s
        self.consecutive_windows = max(1, consecutive_windows)
        self._candidate_key: str | None = None
        self._candidate_count = 0
        self._last_emit_key: str | None = None
        self._last_emit_at = 0.0

    def update(self, *, key: str, has_prompt: bool, momentary: bool, now: float) -> tuple[bool, int]:
        if key != self._candidate_key:
            self._candidate_key = key
            self._candidate_count = 1
        else:
            self._candidate_count += 1

        stable = self._candidate_count >= self.consecutive_windows
        cooled_down = (now - self._last_emit_at) >= self.cooldown_s
        changed = key != self._last_emit_key
        emit = has_prompt and stable and cooled_down and (changed or momentary)
        if emit:
            self._last_emit_key = key
            self._last_emit_at = now
        return emit, self._candidate_count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run a neurofeedback art-control session.")
    add_reader_args(parser)
    parser.add_argument("--policy", choices=available_policies(), default="balancer")
    parser.add_argument("--sink", action="append", choices=("stdout", "jsonl", "http", "scope", "schedule"), help="May be repeated")
    parser.add_argument("--url", default="http://127.0.0.1:8765", help="MAGI/fake video control base URL for --sink http")
    parser.add_argument("--scope-osc-host", default="127.0.0.1", help="Scope OSC host for --sink scope")
    parser.add_argument("--scope-osc-port", type=int, default=8000, help="Scope OSC UDP port for --sink scope")
    parser.add_argument("--scope-osc-timeout-s", type=float, default=1.0)
    parser.add_argument("--scope-transition-steps", type=int, default=6)
    parser.add_argument("--scope-interpolation-method", choices=("linear", "slerp"), default="linear")
    parser.add_argument("--scope-disable-noise-scale", action="store_true")
    parser.add_argument("--scope-noise-min", type=float, default=0.35)
    parser.add_argument("--scope-noise-max", type=float, default=0.85)
    parser.add_argument("--scope-disable-transition-cache-reset", action="store_true")
    parser.add_argument("--scope-disable-manage-cache", action="store_true")
    parser.add_argument("--duration-s", type=float, default=0.0, help="Stop after this many seconds; 0 means run until Ctrl-C")
    parser.add_argument("--window-s", type=float, default=4.0, help="EEG feature window length")
    parser.add_argument("--step-s", type=float, default=0.5, help="Seconds between feature decisions")
    parser.add_argument("--warmup-s", type=float, default=2.0)
    parser.add_argument("--smoothing-alpha", type=float, default=0.35)
    parser.add_argument("--cooldown-s", type=float, default=3.0)
    parser.add_argument("--consecutive-windows", type=int, default=2)
    parser.add_argument("--log-jsonl", default="VideoDiffusion/.tmp/neurofeedback_session.jsonl")
    parser.add_argument("--schedule-csv", default="VideoDiffusion/.tmp/neurofeedback_prompt_schedule.csv")
    parser.add_argument("--schedule-hold-chunks", type=int, default=4)
    parser.add_argument("--http-timeout-s", type=float, default=5.0)
    args = parser.parse_args(argv)

    if args.window_s <= 0 or args.step_s <= 0:
        raise SystemExit("[error] --window-s and --step-s must be positive")

    reader = create_reader_from_args(args)
    smoother = ExponentialFeatureSmoother(args.smoothing_alpha)
    estimator = NeuroStateEstimator()
    policy = get_policy(args.policy)
    gate = EmitGate(cooldown_s=args.cooldown_s, consecutive_windows=args.consecutive_windows)
    sinks = _build_sinks(args)

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
                now = time.monotonic()
                if args.duration_s > 0 and (now - started) >= args.duration_s:
                    break
                raw = eeg.get_window(sample_count)
                if raw is None:
                    time.sleep(min(args.step_s, 0.25))
                    continue

                features = smoother.update(compute_features(raw, eeg.sampling_rate))
                neuro_state = estimator.estimate(features)
                command = policy.command_for(neuro_state)
                emit, candidate_count = gate.update(
                    key=f"{command.policy}:{command.state}:{command.prompt or ''}",
                    has_prompt=bool(command.prompt),
                    momentary=command.state == "transition",
                    now=now,
                )

                record = {
                    "ts": time.time(),
                    "seq": seq,
                    "board": args.board,
                    "policy": args.policy,
                    "emit": emit,
                    "candidate_count": candidate_count,
                    "features": features.to_jsonable(),
                    "neuro_state": neuro_state.to_jsonable(),
                    "command": command.to_jsonable(),
                }
                sinks.handle(record)

                seq += 1
                time.sleep(args.step_s)
    finally:
        sinks.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
