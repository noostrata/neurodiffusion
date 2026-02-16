#!/usr/bin/env python3
"""
Run a chunk-aligned prompt schedule against realtime_magi_stream.py.

Schedule CSV schema:
    cue_id,start_chunk,end_chunk,prompt
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


REQUIRED_COLUMNS = ("cue_id", "start_chunk", "end_chunk", "prompt")


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _join_url(base: str, path: str) -> str:
    return base.rstrip("/") + path


def _http_json(method: str, url: str, payload: dict | None, timeout_s: float) -> dict:
    body = None
    headers = {}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url=url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace") if hasattr(exc, "read") else str(exc)
        raise RuntimeError(f"HTTP {exc.code} {method} {url}: {err}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Request failed {method} {url}: {exc}") from exc

    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Non-JSON response from {url}: {raw[:200]}") from exc


def _get_stats(base_url: str, timeout_s: float) -> dict:
    return _http_json("GET", _join_url(base_url, "/stats"), payload=None, timeout_s=timeout_s)


def _set_prompt(base_url: str, prompt: str, timeout_s: float) -> dict:
    return _http_json("POST", _join_url(base_url, "/prompt"), payload={"prompt": prompt}, timeout_s=timeout_s)


def _as_int(value, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default


@dataclass(frozen=True)
class Cue:
    cue_id: str
    start_chunk: int
    end_chunk: int
    prompt: str


def _load_schedule(csv_path: Path) -> list[Cue]:
    if not csv_path.is_file():
        raise SystemExit(f"[error] Schedule CSV not found: {csv_path}")

    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        columns = tuple(reader.fieldnames or ())
        missing = [c for c in REQUIRED_COLUMNS if c not in columns]
        if missing:
            raise SystemExit(
                f"[error] Missing required CSV column(s): {', '.join(missing)}. "
                f"Expected: {', '.join(REQUIRED_COLUMNS)}"
            )

        cues: list[Cue] = []
        for row_idx, row in enumerate(reader, start=2):
            cue_id = (row.get("cue_id") or "").strip()
            prompt = (row.get("prompt") or "").strip()
            if not cue_id:
                raise SystemExit(f"[error] Row {row_idx}: cue_id cannot be empty.")
            if not prompt:
                raise SystemExit(f"[error] Row {row_idx}: prompt cannot be empty.")

            try:
                start_chunk = int((row.get("start_chunk") or "").strip())
            except Exception as exc:
                raise SystemExit(f"[error] Row {row_idx}: start_chunk must be an integer.") from exc
            try:
                end_chunk = int((row.get("end_chunk") or "").strip())
            except Exception as exc:
                raise SystemExit(f"[error] Row {row_idx}: end_chunk must be an integer.") from exc

            if start_chunk < 0:
                raise SystemExit(f"[error] Row {row_idx}: start_chunk must be >= 0.")
            if end_chunk < start_chunk:
                raise SystemExit(f"[error] Row {row_idx}: end_chunk must be >= start_chunk.")

            cues.append(Cue(cue_id=cue_id, start_chunk=start_chunk, end_chunk=end_chunk, prompt=prompt))

    if not cues:
        raise SystemExit("[error] Schedule CSV is empty.")
    return cues


def _wait_for_server(base_url: str, timeout_s: float, poll_s: float) -> dict:
    deadline = time.monotonic() + timeout_s
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            return _get_stats(base_url, timeout_s=5)
        except Exception as exc:  # noqa: PERF203
            last_err = exc
            time.sleep(poll_s)
    raise TimeoutError(f"Server not ready at {base_url} after {timeout_s:.0f}s: {last_err}")


def _wait_for_chunk(base_url: str, target_chunk: int, timeout_s: float, poll_s: float) -> dict:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        stats = _get_stats(base_url, timeout_s=10)
        chunk_idx = _as_int(stats.get("chunk_idx"), -1)
        if chunk_idx >= target_chunk:
            return stats
        time.sleep(poll_s)
    raise TimeoutError(f"Chunk did not reach {target_chunk} within {timeout_s:.0f}s.")


def _wait_for_prompt_applied(
    *,
    base_url: str,
    cue: Cue,
    timeout_s: float,
    poll_s: float,
) -> tuple[dict, float]:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        stats = _get_stats(base_url, timeout_s=10)
        chunk_idx = _as_int(stats.get("chunk_idx"), -1)
        last_prompt = stats.get("last_prompt")
        if chunk_idx >= cue.start_chunk and last_prompt == cue.prompt:
            return stats, time.monotonic()
        time.sleep(poll_s)
    raise TimeoutError(
        f"Prompt for cue={cue.cue_id} not applied by chunk>={cue.start_chunk} within {timeout_s:.0f}s."
    )


def _percentile(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    if p <= 0:
        return min(xs)
    if p >= 1:
        return max(xs)
    ys = sorted(xs)
    k = (len(ys) - 1) * p
    lower = int(k)
    upper = min(lower + 1, len(ys) - 1)
    if lower == upper:
        return ys[lower]
    return ys[lower] * (upper - k) + ys[upper] * (k - lower)


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def _write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["cue_id", "start_chunk", "applied_chunk", "latency_s", "latency_chunks", "status"]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k) for k in fields})


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Run chunk-wise prompt schedule against MAGI stream server.")
    parser.add_argument("--url", default="http://localhost:8000", help="Base URL for realtime_magi_stream.py")
    parser.add_argument("--schedule-csv", required=True, help="CSV with cue_id,start_chunk,end_chunk,prompt")
    parser.add_argument("--poll", type=float, default=0.25, help="Polling interval in seconds")
    parser.add_argument("--timeout", type=float, default=120.0, help="Timeout per wait stage in seconds")
    parser.add_argument("--report-json", required=True, help="Path to JSON report output")
    parser.add_argument("--report-csv", required=True, help="Path to CSV report output")
    args = parser.parse_args(argv)

    base_url = args.url.rstrip("/")
    schedule_path = Path(args.schedule_csv).expanduser()
    cues = _load_schedule(schedule_path)

    run_id = f"prompt_schedule_{int(time.time())}"
    started_at = _utc_now_iso()

    server_stats = _wait_for_server(base_url, timeout_s=args.timeout, poll_s=args.poll)
    initial_chunk = _as_int(server_stats.get("chunk_idx"), -1)

    cue_results: list[dict] = []
    for idx, cue in enumerate(cues, start=1):
        wait_target = max(cue.start_chunk - 1, -1)
        now_stats = _wait_for_chunk(base_url, target_chunk=wait_target, timeout_s=args.timeout, poll_s=args.poll)
        send_chunk_idx = _as_int(now_stats.get("chunk_idx"), -1)
        sent_wall = _utc_now_iso()
        t0 = time.monotonic()
        _set_prompt(base_url, cue.prompt, timeout_s=10)

        result = {
            "cue_id": cue.cue_id,
            "start_chunk": cue.start_chunk,
            "end_chunk": cue.end_chunk,
            "status": "timeout",
            "sent_chunk_idx": send_chunk_idx,
            "sent_at": sent_wall,
            "applied_at": None,
            "applied_chunk": None,
            "latency_s": None,
            "latency_chunks": None,
        }

        try:
            applied_stats, t1 = _wait_for_prompt_applied(
                base_url=base_url,
                cue=cue,
                timeout_s=args.timeout,
                poll_s=args.poll,
            )
            applied_chunk = _as_int(applied_stats.get("chunk_idx"), -1)
            latency_s = t1 - t0
            latency_chunks = applied_chunk - cue.start_chunk
            result.update(
                status="applied",
                applied_at=_utc_now_iso(),
                applied_chunk=applied_chunk,
                latency_s=latency_s,
                latency_chunks=latency_chunks,
            )
            print(
                f"[{idx:02d}/{len(cues)}] cue={cue.cue_id} start={cue.start_chunk} "
                f"applied_chunk={applied_chunk} latency_s={latency_s:.2f} latency_chunks={latency_chunks}"
            )
        except TimeoutError as exc:
            result["error"] = str(exc)
            print(f"[{idx:02d}/{len(cues)}] cue={cue.cue_id} TIMEOUT: {exc}")

        cue_results.append(result)

    finished_at = _utc_now_iso()
    applied = [r for r in cue_results if r["status"] == "applied"]
    misses = [r for r in cue_results if r["status"] != "applied"]
    lat_s = [float(r["latency_s"]) for r in applied if r.get("latency_s") is not None]
    lat_chunks = [int(r["latency_chunks"]) for r in applied if r.get("latency_chunks") is not None]

    metrics = {
        "cue_count": len(cue_results),
        "applied_count": len(applied),
        "miss_count": len(misses),
        "latency_s_mean": statistics.mean(lat_s) if lat_s else None,
        "latency_s_p50": _percentile(lat_s, 0.50),
        "latency_s_p90": _percentile(lat_s, 0.90),
        "latency_s_p95": _percentile(lat_s, 0.95),
        "latency_s_max": max(lat_s) if lat_s else None,
        "latency_chunks_mean": statistics.mean(lat_chunks) if lat_chunks else None,
        "latency_chunks_p90": _percentile([float(x) for x in lat_chunks], 0.90) if lat_chunks else None,
        "latency_chunks_max": max(lat_chunks) if lat_chunks else None,
    }

    status = "ok" if not misses else "partial"
    report = {
        "run_id": run_id,
        "status": status,
        "start_ts": started_at,
        "end_ts": finished_at,
        "config": {
            "url": base_url,
            "schedule_csv": str(schedule_path),
            "poll_s": args.poll,
            "timeout_s": args.timeout,
            "initial_chunk_idx": initial_chunk,
        },
        "metrics": metrics,
        "cues": cue_results,
    }

    json_path = Path(args.report_json).expanduser()
    csv_path = Path(args.report_csv).expanduser()
    _write_json(json_path, report)
    _write_csv(csv_path, cue_results)

    print("[summary] prompt schedule execution")
    print(f"  run_id  : {run_id}")
    print(f"  cues    : {metrics['cue_count']}")
    print(f"  applied : {metrics['applied_count']}")
    print(f"  misses  : {metrics['miss_count']}")
    print(f"  p50_s   : {metrics['latency_s_p50']}")
    print(f"  p90_s   : {metrics['latency_s_p90']}")
    print(f"  p95_s   : {metrics['latency_s_p95']}")
    print(f"  max_s   : {metrics['latency_s_max']}")
    print(f"  report  : {json_path}")
    print(f"  csv     : {csv_path}")

    return 0 if status == "ok" else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
