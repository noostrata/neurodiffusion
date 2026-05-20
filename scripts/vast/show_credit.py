#!/usr/bin/env python3
"""Print a sanitized Vast.ai credit summary.

The Vast CLI user endpoint has changed shape before, so this helper tries the
CLI first and falls back to the direct current-user API using a locally
configured API key. It never prints the API key or user-identifying fields.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def extract_credit_usd(payload: Any) -> float | None:
    """Find the user's spendable Vast credit in a nested API payload."""

    if isinstance(payload, dict):
        for key in (
            "credit",
            "credits",
            "current_credit",
            "balance_usd",
            "balanceUSD",
            "balance",
        ):
            value = payload.get(key)
            if isinstance(value, (int, float)):
                return float(value)
            if isinstance(value, str):
                try:
                    return float(value)
                except ValueError:
                    pass
        for value in payload.values():
            found = extract_credit_usd(value)
            if found is not None:
                return found
    if isinstance(payload, list):
        for item in payload:
            found = extract_credit_usd(item)
            if found is not None:
                return found
    return None


def _query_cli() -> tuple[Any | None, str]:
    proc = subprocess.run(
        ["vastai", "show", "user", "--raw"],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return None, (proc.stderr or proc.stdout or "vastai show user failed").strip()
    try:
        return json.loads(proc.stdout), ""
    except json.JSONDecodeError as exc:
        return None, f"could not parse vastai show user JSON: {exc}"


def _read_api_key() -> tuple[str, str]:
    env_key = os.environ.get("VAST_API_KEY", "").strip()
    if env_key:
        return env_key, "env:VAST_API_KEY"
    key_path = Path.home() / ".config" / "vastai" / "vast_api_key"
    if key_path.is_file():
        api_key = key_path.read_text(encoding="utf-8").strip()
        if api_key:
            return api_key, str(key_path)
    return "", ""


def _query_direct_api() -> tuple[Any | None, str, str]:
    api_key, source = _read_api_key()
    if not api_key:
        return None, "", "no Vast API key found in VAST_API_KEY or ~/.config/vastai/vast_api_key"
    url = "https://console.vast.ai/api/v0/users/current?" + urllib.parse.urlencode({"api_key": api_key})
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8")), source, ""
    except Exception as exc:
        return None, source, f"direct Vast credit query failed: {type(exc).__name__}"


def credit_summary() -> dict[str, Any]:
    cli_payload, cli_error = _query_cli()
    source = "vastai show user --raw"
    payload = cli_payload
    fallback_error = ""
    if payload is None or extract_credit_usd(payload) is None:
        payload, key_source, fallback_error = _query_direct_api()
        source = "direct current-user API" if payload is not None else ""
        if key_source:
            source = f"{source} via local key file" if source else "local key file"

    credit = extract_credit_usd(payload)
    checked = credit is not None
    error = "" if checked else (fallback_error or cli_error or "credit field not found")
    return {
        "checked": checked,
        "credit_usd": round(float(credit), 6) if credit is not None else None,
        "source": source if checked else "",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "error": error,
        "cli_error": "" if cli_payload is not None else cli_error,
    }


def command_selftest() -> int:
    assert extract_credit_usd({"credit": "9.626478", "balance": 0}) == 9.626478
    assert extract_credit_usd({"user": {"credits": 3.25}}) == 3.25
    assert extract_credit_usd([{"balance_usd": "1.5"}]) == 1.5
    assert extract_credit_usd({"balance": "not-a-number"}) is None
    print("[vast-credit-selftest] ok")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-json", default="", help="Write sanitized credit summary JSON")
    parser.add_argument("--print-value", action="store_true", help="Print only the numeric credit")
    parser.add_argument("--min-credit-usd", type=float, default=0.0)
    parser.add_argument("--reserve-usd", type=float, default=0.0)
    parser.add_argument("--estimated-spend-usd", type=float, default=0.0)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)

    if args.selftest:
        return command_selftest()

    summary = credit_summary()
    required = max(float(args.min_credit_usd), float(args.estimated_spend_usd) + float(args.reserve_usd))
    credit = summary.get("credit_usd")
    budget_ok = bool(summary["checked"] and credit is not None and float(credit) >= required)
    summary["requirements"] = {
        "min_credit_usd": round(float(args.min_credit_usd), 6),
        "reserve_usd": round(float(args.reserve_usd), 6),
        "estimated_spend_usd": round(float(args.estimated_spend_usd), 6),
        "required_credit_usd": round(required, 6),
        "budget_ok": budget_ok,
    }

    if args.out_json:
        out = Path(args.out_json).expanduser()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.print_value:
        if credit is not None:
            print(credit)
    else:
        print(
            "[vast-credit] "
            f"checked={summary['checked']} credit_usd={credit} "
            f"required_usd={summary['requirements']['required_credit_usd']} "
            f"budget_ok={budget_ok} error={summary['error']}"
        )

    if not summary["checked"]:
        return 1
    if not budget_ok:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
