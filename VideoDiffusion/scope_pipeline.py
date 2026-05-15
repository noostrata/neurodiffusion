#!/usr/bin/env python3
"""CLI helpers for Daydream Scope pipeline load/status operations."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from eeg_control.scope_client import ScopeApiClient
else:
    from .eeg_control.scope_client import ScopeApiClient


def _bool_arg(raw: str) -> bool:
    value = raw.strip().lower()
    if value in {"1", "true", "yes", "y", "on"}:
        return True
    if value in {"0", "false", "no", "n", "off"}:
        return False
    raise argparse.ArgumentTypeError(f"expected boolean, got {raw!r}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Control a Daydream Scope pipeline over the REST API.")
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--timeout-s", type=float, default=300.0)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="Print /api/v1/pipeline/status")

    load = sub.add_parser("load", help="Load one or more pipeline ids")
    load.add_argument("--pipeline-id", action="append", required=True, help="May be repeated; preprocessors first")
    load.add_argument("--height", type=int, default=320)
    load.add_argument("--width", type=int, default=576)
    load.add_argument("--seed", type=int, default=42)
    load.add_argument("--vae-type", default="wan")
    load.add_argument("--vace-enabled", type=_bool_arg, default=False)
    load.add_argument("--wait", action="store_true")
    load.add_argument("--poll-s", type=float, default=1.0)

    load_longlive = sub.add_parser("load-longlive", help="Load the LongLive pipeline")
    load_longlive.add_argument("--height", type=int, default=320)
    load_longlive.add_argument("--width", type=int, default=576)
    load_longlive.add_argument("--seed", type=int, default=42)
    load_longlive.add_argument("--vae-type", default="wan")
    load_longlive.add_argument("--vace-enabled", type=_bool_arg, default=False)
    load_longlive.add_argument("--wait", action="store_true")
    load_longlive.add_argument("--poll-s", type=float, default=1.0)

    args = parser.parse_args(argv)
    client = ScopeApiClient(args.base_url, timeout_s=min(30.0, max(1.0, args.timeout_s)))

    if args.command == "status":
        print(json.dumps(client.get_pipeline_status(), indent=2, sort_keys=True))
        return 0

    if args.command == "load-longlive":
        pipeline_ids = ["longlive"]
    else:
        pipeline_ids = args.pipeline_id

    load_params = {
        "height": args.height,
        "width": args.width,
        "seed": args.seed,
        "vae_type": args.vae_type,
        "vace_enabled": args.vace_enabled,
    }
    result = client.load_pipeline(pipeline_ids, load_params=load_params)
    if args.wait:
        result = client.wait_for_pipeline_loaded(timeout_s=args.timeout_s, poll_s=args.poll_s)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
