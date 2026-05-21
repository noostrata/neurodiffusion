#!/usr/bin/env python3
"""
Query Vast.ai offers for neurodiffusion video runtimes and emit normalized scan artifacts.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


DEFAULT_QUERY = (
    "verified=True datacenter=True reliability>0.99 rentable=True "
    "num_gpus>=1 gpu_ram>=40 disk_space>200 disk_bw>1000 "
    "inet_up>500 inet_down>500 direct_port_count>=2"
)

DEFAULT_QUERY_BY_MODEL = {
    "magi": DEFAULT_QUERY,
    "krea": DEFAULT_QUERY,
    "scope": (
        "verified=True datacenter=True reliability>0.99 rentable=True "
        "num_gpus>=1 gpu_ram>=24 disk_space>200 disk_bw>1000 "
        "inet_up>500 inet_down>500 direct_port_count>=2 cuda_max_good>=12.8"
    ),
    "longlive2": (
        "verified=True datacenter=True reliability>0.99 rentable=True "
        "num_gpus>=1 gpu_ram>=24 disk_space>260 disk_bw>1000 "
        "inet_up>500 inet_down>500 direct_port_count>=2 cuda_max_good>=12.8"
    ),
}

MODEL_GPU_REGEX = {
    "magi": r"(B200|H200|H100|GH200|A100|A6000|RTX.?6000|RTX.?4090|L40S)",
    "krea": r"(B200|H200|H100|GH200|L40S|RTX.?6000|A6000|RTX.?5090)",
    "scope": r"(B200|H200|H100|GH200|L40S|RTX.?6000|A6000|RTX.?5090|RTX.?4090)",
    "longlive2": r"(GB200|B200|H200|H100|GH200|RTX.?6000|RTX.?5090)",
}

CSV_FIELDS = [
    "offer_id",
    "gpu_name",
    "num_gpus",
    "gpu_ram_gb",
    "dph_total",
    "reliability",
    "datacenter",
    "verified",
    "rentable",
    "location",
    "machine_id",
    "inet_up",
    "inet_down",
    "disk_space",
    "disk_bw",
    "direct_port_count",
    "cuda_max_good",
]


def _run_vast_search(query: str) -> tuple[list[dict[str, Any]], str | None]:
    cmd = ["vastai", "search", "offers", query, "--raw", "-o", "dph_total"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return [], proc.stderr.strip() or proc.stdout.strip() or "vastai search offers failed"
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return [], f"json parse error: {exc}"
    if isinstance(payload, dict):
        if isinstance(payload.get("offers"), list):
            payload = payload["offers"]
        elif isinstance(payload.get("results"), list):
            payload = payload["results"]
    if not isinstance(payload, list):
        return [], "unexpected vastai search payload shape"
    return [x for x in payload if isinstance(x, dict)], None


def _first_value(row: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in row and row[key] not in (None, ""):
            return row[key]
    return None


def _to_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except Exception:
        return None


def _to_int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(float(value))
    except Exception:
        return None


def _to_bool(value: Any) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    raw = str(value).strip().lower()
    if raw in {"1", "true", "yes", "y"}:
        return True
    if raw in {"0", "false", "no", "n"}:
        return False
    return None


def _normalize_offer(raw: dict[str, Any]) -> dict[str, Any]:
    gpu_name = str(_first_value(raw, "gpu_name", "gpu_name_str", "gpu_display_name") or "").strip()
    return {
        "offer_id": _first_value(raw, "id", "offer_id", "ask_contract_id"),
        "gpu_name": gpu_name,
        "num_gpus": _to_int(_first_value(raw, "num_gpus", "gpu_count")),
        "gpu_ram_gb": _to_float(_first_value(raw, "gpu_ram", "gpu_mem", "gpu_memory")),
        "dph_total": _to_float(_first_value(raw, "dph_total", "price", "price_value", "cost_per_hour")),
        "reliability": _to_float(raw.get("reliability")),
        "datacenter": _to_bool(raw.get("datacenter")),
        "verified": _to_bool(raw.get("verified")),
        "rentable": _to_bool(raw.get("rentable")),
        "location": _first_value(raw, "geolocation", "location", "country", "region"),
        "machine_id": _first_value(raw, "machine_id", "machine_id_str"),
        "inet_up": _to_float(raw.get("inet_up")),
        "inet_down": _to_float(raw.get("inet_down")),
        "disk_space": _to_float(raw.get("disk_space")),
        "disk_bw": _to_float(raw.get("disk_bw")),
        "direct_port_count": _to_int(raw.get("direct_port_count")),
        "cuda_max_good": _to_float(raw.get("cuda_max_good")),
        "raw": raw,
    }


def _default_paths(repo_root: Path, model: str) -> tuple[Path, Path]:
    out_dir = repo_root / "VideoDiffusion" / ".tmp"
    return out_dir / f"vast_video_offer_scan_{model}.json", out_dir / f"vast_video_offer_scan_{model}.csv"


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k) for k in CSV_FIELDS})


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=["magi", "krea", "scope", "longlive2"], default="magi")
    parser.add_argument("--query", default="", help="Vast search expression")
    parser.add_argument("--gpu-name-regex", default="", help="Optional local regex filter for gpu_name")
    parser.add_argument("--out-json", default="")
    parser.add_argument("--out-csv", default="")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    out_json, out_csv = _default_paths(repo_root, args.model)
    if args.out_json:
        out_json = Path(args.out_json).expanduser()
    if args.out_csv:
        out_csv = Path(args.out_csv).expanduser()

    started = int(time.time())
    query = args.query.strip() or DEFAULT_QUERY_BY_MODEL[args.model]
    raw_offers, error = _run_vast_search(query)
    normalized = [_normalize_offer(row) for row in raw_offers]

    gpu_regex = args.gpu_name_regex.strip() or MODEL_GPU_REGEX[args.model]
    if gpu_regex:
        rx = re.compile(gpu_regex, re.IGNORECASE)
        normalized = [row for row in normalized if rx.search(str(row.get("gpu_name") or ""))]

    result = {
        "provider": "vastai",
        "model": args.model,
        "query": query,
        "gpu_name_regex": gpu_regex,
        "offer_count": len(normalized),
        "error": error,
        "generated_at_epoch_s": started,
        "offers": normalized,
    }
    _write_json(out_json, result)
    _write_csv(out_csv, normalized)

    print(f"[vast-query] model={args.model} offers={len(normalized)} error={error or ''}")
    print(f"[vast-query] json={out_json}")
    print(f"[vast-query] csv={out_csv}")
    if error:
        print(f"[vast-query] warning: {error}", file=sys.stderr)
    return 0 if not error else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
