#!/usr/bin/env python3
"""
Autonomous Vast.ai matrix runner for Scope + LongLive realtime EEG validation.

The runner is safe by default: without --create-instance it writes a no-paid
plan. Paid work is delegated to run_scope_longlive_vast_smoke.sh, which handles
remote setup, local artifact pullback, and teardown for wrapper-created
instances.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
SMOKE_SCRIPT = SCRIPT_DIR / "run_scope_longlive_vast_smoke.sh"

DEFAULT_RUNTIME_TAG = "scope_auto_py312_torch2.9.1_cu128_sm100"
DEFAULT_TARGET_RES = "320x576"
DEFAULT_LOWER_RESOLUTIONS = "256x448,192x320"
DEFAULT_UPPER_RESOLUTIONS = "368x640,480x832"

CSV_FIELDS = [
    "row_idx",
    "attempt_idx",
    "matrix_run_id",
    "run_id",
    "tier",
    "phase",
    "condition",
    "gpu_regex",
    "offer_id",
    "gpu_name",
    "dph_total",
    "height",
    "width",
    "duration_s",
    "status",
    "return_code",
    "acceptance_passed",
    "fps",
    "first_frame_latency_s",
    "frame_count",
    "elapsed_s",
    "estimated_cost_usd",
    "local_dir",
    "flat_local_video",
    "report_path",
    "log_path",
    "error",
]


@dataclass(frozen=True)
class Resolution:
    height: int
    width: int

    @property
    def label(self) -> str:
        return f"{self.height}x{self.width}"


@dataclass(frozen=True)
class Tier:
    name: str
    gpu_regex: str
    max_dph: float
    mode: str


DEFAULT_TIERS = [
    Tier("cheap_mid", r"RTX.?5090|L40S|RTX.?6000|A6000", 2.50, "full"),
    Tier("hopper", r"H100|H200|GH200", 8.00, "full"),
    Tier("b200_known_good", r"B200", 8.00, "full"),
    Tier("rtx4090_lowres", r"RTX.?4090", 1.50, "low"),
]


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def parse_resolution(raw: str) -> Resolution:
    match = re.fullmatch(r"\s*(\d+)\s*x\s*(\d+)\s*", raw)
    if not match:
        raise argparse.ArgumentTypeError(f"invalid resolution '{raw}', expected HxW")
    height = int(match.group(1))
    width = int(match.group(2))
    if height <= 0 or width <= 0:
        raise argparse.ArgumentTypeError(f"invalid resolution '{raw}', dimensions must be positive")
    if height % 16 != 0 or width % 16 != 0:
        raise argparse.ArgumentTypeError(f"invalid resolution '{raw}', dimensions must be divisible by 16")
    return Resolution(height=height, width=width)


def parse_resolution_list(raw: str) -> list[Resolution]:
    if not raw.strip():
        return []
    return [parse_resolution(part) for part in raw.split(",") if part.strip()]


def parse_tiers(raw: str) -> list[Tier]:
    if not raw.strip():
        return DEFAULT_TIERS
    by_name = {tier.name: tier for tier in DEFAULT_TIERS}
    selected: list[Tier] = []
    for name in [part.strip() for part in raw.split(",") if part.strip()]:
        if name not in by_name:
            known = ", ".join(t.name for t in DEFAULT_TIERS)
            raise argparse.ArgumentTypeError(f"unknown tier '{name}', known tiers: {known}")
        selected.append(by_name[name])
    return selected


def run_cmd(cmd: list[str], *, cwd: Path, timeout_s: int | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def query_and_select_offer(
    *,
    tier: Tier,
    runtime_tag: str,
    work_dir: Path,
    row_idx: int,
    selection_goal: str,
    allow_runtime_gpu_mismatch: bool,
    scan_retries: int,
    scan_sleep_s: int,
) -> tuple[dict[str, Any] | None, str]:
    scan_json = work_dir / f"{row_idx:02d}_{tier.name}_scan.json"
    scan_csv = work_dir / f"{row_idx:02d}_{tier.name}_scan.csv"
    selected_json = work_dir / f"{row_idx:02d}_{tier.name}_selected.json"
    last_error = ""

    for scan_try in range(1, max(1, scan_retries) + 1):
        query_cmd = [
            "python3",
            str(REPO_ROOT / "scripts/vast/query_video_offers.py"),
            "--model",
            "scope",
            "--gpu-name-regex",
            tier.gpu_regex,
            "--out-json",
            str(scan_json),
            "--out-csv",
            str(scan_csv),
        ]
        query = run_cmd(query_cmd, cwd=REPO_ROOT)
        if query.returncode != 0:
            last_error = (query.stderr or query.stdout or "offer query failed").strip()
        else:
            select_cmd = [
                "python3",
                str(REPO_ROOT / "scripts/vast/select_video_offer.py"),
                "--scan-json",
                str(scan_json),
                "--selection-goal",
                selection_goal,
                "--runtime-tag",
                runtime_tag,
                "--max-dph",
                f"{tier.max_dph:.6f}",
                "--out-json",
                str(selected_json),
            ]
            if allow_runtime_gpu_mismatch:
                select_cmd.append("--allow-runtime-gpu-mismatch")
            selected = run_cmd(select_cmd, cwd=REPO_ROOT)
            if selected.returncode == 0 and selected_json.is_file():
                payload = load_json(selected_json)
                return payload.get("selected_offer") or {}, ""
            last_error = (selected.stderr or selected.stdout or "offer selection failed").strip()

        if scan_try < scan_retries:
            print(
                f"[matrix] no selected offer for tier={tier.name} try={scan_try}/{scan_retries}; "
                f"sleeping {scan_sleep_s}s",
                flush=True,
            )
            time.sleep(max(0, scan_sleep_s))

    return None, last_error


def plan_rows_for_tier(
    *,
    tier: Tier,
    target: Resolution,
    lower: list[Resolution],
    upper: list[Resolution],
) -> list[tuple[str, str, Resolution]]:
    if tier.mode == "low":
        return [("lowres", "always", res) for res in lower]
    rows = [("target", "always", target)]
    rows.extend(("upscale", "if_target_passes", res) for res in upper)
    rows.extend(("downscale", "if_target_fails", res) for res in lower)
    return rows


def actual_sequence_for_tier(
    *,
    tier: Tier,
    target: Resolution,
    lower: list[Resolution],
    upper: list[Resolution],
    target_passed: bool | None,
) -> list[tuple[str, str, Resolution]]:
    if tier.mode == "low":
        return [("lowres", "always", res) for res in lower]
    if target_passed is None:
        return [("target", "always", target)]
    if target_passed:
        return [("upscale", "target_passed", res) for res in upper]
    return [("downscale", "target_failed", res) for res in lower]


def estimate_cost_usd(dph_total: Any, seconds: float) -> float:
    try:
        dph = float(dph_total)
    except Exception:
        return 0.0
    return max(0.0, dph * max(0.0, seconds) / 3600.0)


def parse_smoke_report(report_path: Path) -> dict[str, Any]:
    if not report_path.is_file():
        return {}
    try:
        return load_json(report_path)
    except Exception:
        return {}


def value_or_blank(mapping: dict[str, Any], key: str) -> Any:
    value = mapping.get(key)
    return "" if value is None else value


def parse_instance_id_from_log(log_path: Path) -> str:
    if not log_path.is_file():
        return ""
    text = log_path.read_text(encoding="utf-8", errors="replace")
    matches = re.findall(r"^VAST_INSTANCE_ID=(\d+)\s*$", text, flags=re.MULTILINE)
    return matches[-1] if matches else ""


def terminate_instance(instance_id: str, log_path: Path) -> None:
    if not instance_id:
        return
    env = os.environ.copy()
    env["VAST_INSTANCE_ID"] = instance_id
    with log_path.open("a", encoding="utf-8") as f:
        f.write(f"\n[matrix] timeout cleanup: terminating owned instance {instance_id}\n")
        subprocess.run(
            ["bash", str(REPO_ROOT / "scripts/vast/terminate_instance.sh")],
            cwd=str(REPO_ROOT),
            env=env,
            stdout=f,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )


def run_smoke_attempt(
    *,
    args: argparse.Namespace,
    tier: Tier,
    offer: dict[str, Any],
    resolution: Resolution,
    phase: str,
    condition: str,
    matrix_run_id: str,
    attempt_idx: int,
    local_root: Path,
) -> dict[str, Any]:
    run_id = f"{matrix_run_id}_{attempt_idx:02d}_{tier.name}_{resolution.label}"
    local_dir = local_root / run_id
    flat_video = local_root / f"{run_id}_webrtc_capture.mp4"
    flat_frame = local_root / f"{run_id}_frame_000024.png"
    log_path = local_root / f"{run_id}_smoke.log"
    local_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        "bash",
        str(SMOKE_SCRIPT),
        "--create-instance",
        "--offer-id",
        str(offer.get("offer_id") or ""),
        "--gpu-regex",
        tier.gpu_regex,
        "--max-dph",
        f"{tier.max_dph:.6f}",
        "--runtime-tag",
        args.runtime_tag,
        "--duration-s",
        str(args.duration_s),
        "--height",
        str(resolution.height),
        "--width",
        str(resolution.width),
        "--local-out-dir",
        str(local_dir),
        "--min-fps",
        str(args.min_fps),
        "--max-first-frame-s",
        str(args.max_first_frame_s),
    ]
    if args.keep_instance:
        cmd.append("--keep-instance")
    if args.no_restore:
        cmd.append("--no-restore")
    if args.download_fallback:
        cmd.append("--download-fallback")

    env = os.environ.copy()
    env.update(
        {
            "SCOPE_VAST_RUN_ID": run_id,
            "SCOPE_VAST_LOCAL_OUT_DIR": str(local_dir),
            "SCOPE_VAST_FLAT_LOCAL_VIDEO": str(flat_video),
            "SCOPE_VAST_FLAT_LOCAL_FRAME": str(flat_frame),
            "SCOPE_VAST_GPU_REGEX": tier.gpu_regex,
            "SCOPE_VAST_MAX_DPH": f"{tier.max_dph:.6f}",
            "SCOPE_VAST_RUNTIME_TAG": args.runtime_tag,
        }
    )

    started = time.monotonic()
    timed_out = False
    rc = 0
    print(
        f"[matrix] attempt={attempt_idx} tier={tier.name} res={resolution.label} "
        f"gpu={offer.get('gpu_name')} offer={offer.get('offer_id')} dph={offer.get('dph_total')}",
        flush=True,
    )
    with log_path.open("w", encoding="utf-8") as log:
        log.write("[matrix] command: " + " ".join(cmd) + "\n\n")
        proc = subprocess.Popen(
            cmd,
            cwd=str(REPO_ROOT),
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            rc = proc.wait(timeout=args.max_attempt_wall_clock_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                rc = proc.wait(timeout=45)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                rc = proc.wait()

    elapsed = time.monotonic() - started
    if timed_out and not args.keep_instance:
        terminate_instance(parse_instance_id_from_log(log_path), log_path)

    report_path = local_dir / "run_report.json"
    report = parse_smoke_report(report_path)
    acceptance = report.get("acceptance") or {}
    benchmark = report.get("benchmark") or {}

    if timed_out:
        status = "TIMEOUT"
    elif report and acceptance.get("passed") is True:
        status = "PASS"
    elif report:
        status = "FAIL_ACCEPTANCE"
    else:
        text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
        status = "STALE_OFFER" if "no_such_ask" in text else "SMOKE_FAILED"

    return {
        "attempt_idx": attempt_idx,
        "matrix_run_id": matrix_run_id,
        "run_id": run_id,
        "tier": tier.name,
        "phase": phase,
        "condition": condition,
        "gpu_regex": tier.gpu_regex,
        "offer_id": offer.get("offer_id") or "",
        "gpu_name": offer.get("gpu_name") or "",
        "dph_total": offer.get("dph_total") or "",
        "height": resolution.height,
        "width": resolution.width,
        "duration_s": args.duration_s,
        "status": status,
        "return_code": rc,
        "acceptance_passed": bool(acceptance.get("passed")) if report else False,
        "fps": value_or_blank(benchmark, "fps"),
        "first_frame_latency_s": value_or_blank(benchmark, "first_frame_latency_s"),
        "frame_count": value_or_blank(benchmark, "frame_count"),
        "elapsed_s": round(elapsed, 3),
        "estimated_cost_usd": round(estimate_cost_usd(offer.get("dph_total"), elapsed), 4),
        "local_dir": str(local_dir),
        "flat_local_video": str(flat_video) if flat_video.is_file() else "",
        "report_path": str(report_path) if report_path.is_file() else "",
        "log_path": str(log_path),
        "error": "" if report else f"see {log_path}",
    }


def active_instance_summary() -> dict[str, Any]:
    proc = subprocess.run(
        ["vastai", "show", "instances", "--raw"],
        cwd=str(REPO_ROOT),
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return {"checked": False, "active_instance_count": None, "error": (proc.stderr or proc.stdout).strip()}
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"checked": False, "active_instance_count": None, "error": "could not parse vastai show instances"}
    count = len(payload) if isinstance(payload, list) else None
    return {"checked": True, "active_instance_count": count, "error": ""}


def write_reports(
    *,
    local_root: Path,
    matrix_run_id: str,
    args: argparse.Namespace,
    rows: list[dict[str, Any]],
    tiers: list[Tier],
    final_instances: dict[str, Any],
) -> tuple[Path, Path, Path]:
    local_root.mkdir(parents=True, exist_ok=True)
    csv_path = local_root / "matrix_report.csv"
    json_path = local_root / "matrix_report.json"
    md_path = local_root / "matrix_report.md"

    numbered_rows = []
    for idx, row in enumerate(rows, start=1):
        item = {"row_idx": idx}
        item.update(row)
        numbered_rows.append(item)

    with csv_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for row in numbered_rows:
            writer.writerow({field: row.get(field, "") for field in CSV_FIELDS})

    passed = [row for row in numbered_rows if row.get("status") == "PASS"]
    attempted = [row for row in numbered_rows if row.get("attempt_idx")]
    spend = sum(float(row.get("estimated_cost_usd") or 0.0) for row in numbered_rows)
    payload = {
        "matrix_run_id": matrix_run_id,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "paid_create_enabled": bool(args.create_instance),
        "plan_only": not bool(args.create_instance),
        "runtime_tag": args.runtime_tag,
        "duration_s": args.duration_s,
        "acceptance": {
            "min_fps": args.min_fps,
            "max_first_frame_s": args.max_first_frame_s,
        },
        "budget": {
            "max_budget_usd": args.max_budget_usd,
            "budget_estimate_s": args.budget_estimate_s,
            "estimated_spend_usd": round(spend, 4),
            "max_attempts": args.max_attempts,
        },
        "tiers": [tier.__dict__ for tier in tiers],
        "summary": {
            "rows": len(numbered_rows),
            "attempted": len(attempted),
            "passed": len(passed),
            "best_pass": passed[0] if passed else None,
            "final_instances": final_instances,
        },
        "rows": numbered_rows,
    }
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        f"# Scope LongLive Vast Matrix {matrix_run_id}",
        "",
        f"- paid create enabled: `{bool(args.create_instance)}`",
        f"- runtime tag: `{args.runtime_tag}`",
        f"- estimated spend: `${spend:.4f}` / `${args.max_budget_usd:.2f}`",
        f"- attempted paid runs: `{len(attempted)}`",
        f"- pass count: `{len(passed)}`",
        f"- final active Vast instances checked: `{final_instances.get('checked')}`",
        f"- final active Vast instance count: `{final_instances.get('active_instance_count')}`",
        "",
        "| # | Tier | Phase | GPU | Res HxW | Status | FPS | First frame | Video |",
        "| ---: | --- | --- | --- | --- | --- | ---: | ---: | --- |",
    ]
    for row in numbered_rows:
        video = row.get("flat_local_video") or ""
        video_cell = f"`{video}`" if video else ""
        lines.append(
            "| {row_idx} | `{tier}` | `{phase}` | `{gpu}` | `{height}x{width}` | `{status}` | "
            "{fps} | {first} | {video} |".format(
                row_idx=row.get("row_idx", ""),
                tier=row.get("tier", ""),
                phase=row.get("phase", ""),
                gpu=row.get("gpu_name") or row.get("gpu_regex", ""),
                height=row.get("height", ""),
                width=row.get("width", ""),
                status=row.get("status", ""),
                fps=row.get("fps", ""),
                first=row.get("first_frame_latency_s", ""),
                video=video_cell,
            )
        )
    lines.append("")
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return json_path, csv_path, md_path


def append_plan_row(
    rows: list[dict[str, Any]],
    *,
    args: argparse.Namespace,
    matrix_run_id: str,
    tier: Tier,
    phase: str,
    condition: str,
    resolution: Resolution,
    offer: dict[str, Any] | None,
    status: str,
    error: str = "",
) -> None:
    rows.append(
        {
            "attempt_idx": "",
            "matrix_run_id": matrix_run_id,
            "run_id": "",
            "tier": tier.name,
            "phase": phase,
            "condition": condition,
            "gpu_regex": tier.gpu_regex,
            "offer_id": (offer or {}).get("offer_id", ""),
            "gpu_name": (offer or {}).get("gpu_name", ""),
            "dph_total": (offer or {}).get("dph_total", ""),
            "height": resolution.height,
            "width": resolution.width,
            "duration_s": args.duration_s,
            "status": status,
            "return_code": "",
            "acceptance_passed": "",
            "fps": "",
            "first_frame_latency_s": "",
            "frame_count": "",
            "elapsed_s": "",
            "estimated_cost_usd": round(
                estimate_cost_usd((offer or {}).get("dph_total"), args.budget_estimate_s),
                4,
            ),
            "local_dir": "",
            "flat_local_video": "",
            "report_path": "",
            "log_path": "",
            "error": error,
        }
    )


def run_matrix(args: argparse.Namespace) -> int:
    matrix_run_id = args.matrix_run_id or f"scope_longlive_vast_matrix_{utc_stamp()}"
    local_root = Path(args.local_root).expanduser() if args.local_root else Path.home() / "Downloads" / matrix_run_id
    work_dir = SCRIPT_DIR / ".tmp" / "scope_longlive_matrix" / matrix_run_id
    work_dir.mkdir(parents=True, exist_ok=True)
    local_root.mkdir(parents=True, exist_ok=True)

    tiers = parse_tiers(args.tiers)
    target = parse_resolution(args.target_res)
    lower = parse_resolution_list(args.lower_resolutions)
    upper = parse_resolution_list(args.upper_resolutions)
    rows: list[dict[str, Any]] = []

    print(f"[matrix] matrix_run_id={matrix_run_id}")
    print(f"[matrix] local_root={local_root}")
    print(f"[matrix] paid_create_enabled={bool(args.create_instance)}")

    wall_start = time.monotonic()
    spent = 0.0
    paid_attempts = 0

    for tier in tiers:
        if time.monotonic() - wall_start > args.max_wall_clock_s:
            append_plan_row(
                rows,
                args=args,
                matrix_run_id=matrix_run_id,
                tier=tier,
                phase="wall_clock",
                condition="limit",
                resolution=target,
                offer=None,
                status="WALL_CLOCK_SKIPPED",
                error=f"max wall clock {args.max_wall_clock_s}s reached",
            )
            break

        if not args.create_instance:
            offer = None
            err = ""
            if not args.offline_plan:
                offer, err = query_and_select_offer(
                    tier=tier,
                    runtime_tag=args.runtime_tag,
                    work_dir=work_dir,
                    row_idx=len(rows) + 1,
                    selection_goal=args.selection_goal,
                    allow_runtime_gpu_mismatch=args.allow_runtime_gpu_mismatch,
                    scan_retries=args.scan_retries,
                    scan_sleep_s=args.scan_sleep_s,
                )
            for phase, condition, resolution in plan_rows_for_tier(
                tier=tier,
                target=target,
                lower=lower,
                upper=upper,
            ):
                append_plan_row(
                    rows,
                    args=args,
                    matrix_run_id=matrix_run_id,
                    tier=tier,
                    phase=phase,
                    condition=condition,
                    resolution=resolution,
                    offer=offer,
                    status="PLANNED" if offer or args.offline_plan else "NO_OFFER",
                    error="" if offer or args.offline_plan else err,
                )
            continue

        target_passed: bool | None = None
        while True:
            sequence = actual_sequence_for_tier(
                tier=tier,
                target=target,
                lower=lower,
                upper=upper,
                target_passed=target_passed,
            )
            if not sequence:
                break

            for phase, condition, resolution in sequence:
                if paid_attempts >= args.max_attempts:
                    append_plan_row(
                        rows,
                        args=args,
                        matrix_run_id=matrix_run_id,
                        tier=tier,
                        phase=phase,
                        condition="max_attempts",
                        resolution=resolution,
                        offer=None,
                        status="ATTEMPT_LIMIT_SKIPPED",
                        error=f"max attempts {args.max_attempts} reached",
                    )
                    json_path, csv_path, md_path = write_reports(
                        local_root=local_root,
                        matrix_run_id=matrix_run_id,
                        args=args,
                        rows=rows,
                        tiers=tiers,
                        final_instances=active_instance_summary(),
                    )
                    print(f"[matrix] json={json_path}")
                    print(f"[matrix] csv={csv_path}")
                    print(f"[matrix] md={md_path}")
                    return 0

                offer, err = query_and_select_offer(
                    tier=tier,
                    runtime_tag=args.runtime_tag,
                    work_dir=work_dir,
                    row_idx=len(rows) + 1,
                    selection_goal=args.selection_goal,
                    allow_runtime_gpu_mismatch=args.allow_runtime_gpu_mismatch,
                    scan_retries=args.scan_retries,
                    scan_sleep_s=args.scan_sleep_s,
                )
                if not offer:
                    append_plan_row(
                        rows,
                        args=args,
                        matrix_run_id=matrix_run_id,
                        tier=tier,
                        phase=phase,
                        condition=condition,
                        resolution=resolution,
                        offer=None,
                        status="NO_OFFER",
                        error=err,
                    )
                    break

                next_budget = estimate_cost_usd(offer.get("dph_total"), args.budget_estimate_s)
                if spent + next_budget > args.max_budget_usd:
                    append_plan_row(
                        rows,
                        args=args,
                        matrix_run_id=matrix_run_id,
                        tier=tier,
                        phase=phase,
                        condition="budget",
                        resolution=resolution,
                        offer=offer,
                        status="BUDGET_SKIPPED",
                        error=(
                            f"estimated next cost ${next_budget:.4f} would exceed "
                            f"max budget ${args.max_budget_usd:.2f}"
                        ),
                    )
                    break

                paid_attempts += 1
                row = run_smoke_attempt(
                    args=args,
                    tier=tier,
                    offer=offer,
                    resolution=resolution,
                    phase=phase,
                    condition=condition,
                    matrix_run_id=matrix_run_id,
                    attempt_idx=paid_attempts,
                    local_root=local_root,
                )
                spent += float(row.get("estimated_cost_usd") or 0.0)
                rows.append(row)

                if args.stop_after_first_pass and row.get("status") == "PASS":
                    json_path, csv_path, md_path = write_reports(
                        local_root=local_root,
                        matrix_run_id=matrix_run_id,
                        args=args,
                        rows=rows,
                        tiers=tiers,
                        final_instances=active_instance_summary(),
                    )
                    print(f"[matrix] json={json_path}")
                    print(f"[matrix] csv={csv_path}")
                    print(f"[matrix] md={md_path}")
                    return 0

                if phase == "target":
                    target_passed = row.get("status") == "PASS"
                    break

            if target_passed is None:
                break
            target_passed = True if target_passed else False
            if tier.mode == "low":
                break
            if sequence and sequence[0][0] == "target":
                continue
            break

    final_instances = active_instance_summary() if args.create_instance else {"checked": False, "active_instance_count": None, "error": "no paid run"}
    json_path, csv_path, md_path = write_reports(
        local_root=local_root,
        matrix_run_id=matrix_run_id,
        args=args,
        rows=rows,
        tiers=tiers,
        final_instances=final_instances,
    )
    print(f"[matrix] json={json_path}")
    print(f"[matrix] csv={csv_path}")
    print(f"[matrix] md={md_path}")
    return 0


def selftest() -> int:
    target = parse_resolution(DEFAULT_TARGET_RES)
    lower = parse_resolution_list(DEFAULT_LOWER_RESOLUTIONS)
    upper = parse_resolution_list(DEFAULT_UPPER_RESOLUTIONS)
    assert target == Resolution(320, 576)
    assert lower[-1] == Resolution(192, 320)
    assert upper[-1] == Resolution(480, 832)
    tiers_by_name = {tier.name: tier for tier in DEFAULT_TIERS}
    assert plan_rows_for_tier(tier=tiers_by_name["cheap_mid"], target=target, lower=lower, upper=upper)[0][0] == "target"
    assert all(
        row[0] == "lowres"
        for row in plan_rows_for_tier(
            tier=tiers_by_name["rtx4090_lowres"],
            target=target,
            lower=lower,
            upper=upper,
        )
    )
    fake_args = argparse.Namespace(
        create_instance=False,
        runtime_tag=DEFAULT_RUNTIME_TAG,
        duration_s=3,
        min_fps=24.0,
        max_first_frame_s=2.0,
        max_budget_usd=1.0,
        budget_estimate_s=30,
        max_attempts=1,
    )
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        rows: list[dict[str, Any]] = []
        append_plan_row(
            rows,
            args=fake_args,
            matrix_run_id="selftest",
            tier=DEFAULT_TIERS[0],
            phase="target",
            condition="always",
            resolution=target,
            offer={"offer_id": "1", "gpu_name": "RTX 5090", "dph_total": 1.2},
            status="PLANNED",
        )
        json_path, csv_path, md_path = write_reports(
            local_root=root,
            matrix_run_id="selftest",
            args=fake_args,
            rows=rows,
            tiers=DEFAULT_TIERS,
            final_instances={"checked": False, "active_instance_count": None, "error": "selftest"},
        )
        assert json_path.is_file()
        assert csv_path.is_file()
        assert md_path.is_file()
        payload = load_json(json_path)
        assert payload["summary"]["rows"] == 1
    print("[matrix-selftest] ok")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--create-instance", action="store_true", help="Enable paid Vast instance creation")
    parser.add_argument("--plan-only", action="store_true", help="Write a no-paid plan; default when --create-instance is absent")
    parser.add_argument("--offline-plan", action="store_true", help="Do not query Vast; just write the static attempt plan")
    parser.add_argument("--matrix-run-id", default="")
    parser.add_argument("--local-root", default="", help="Local matrix artifact directory")
    parser.add_argument("--runtime-tag", default=DEFAULT_RUNTIME_TAG)
    parser.add_argument("--tiers", default="", help="Comma list of default tier names to use")
    parser.add_argument("--selection-goal", choices=["cost", "realtime"], default="cost")
    parser.add_argument("--target-res", default=DEFAULT_TARGET_RES, help="Target HxW, divisible by 16")
    parser.add_argument("--lower-resolutions", default=DEFAULT_LOWER_RESOLUTIONS, help="Comma list of HxW probes after target failure")
    parser.add_argument("--upper-resolutions", default=DEFAULT_UPPER_RESOLUTIONS, help="Comma list of HxW probes after target pass")
    parser.add_argument("--duration-s", type=int, default=30)
    parser.add_argument("--min-fps", type=float, default=24.0)
    parser.add_argument("--max-first-frame-s", type=float, default=2.0)
    parser.add_argument("--max-budget-usd", type=float, default=20.0)
    parser.add_argument("--budget-estimate-s", type=int, default=1800, help="Conservative seconds charged per planned paid attempt")
    parser.add_argument("--max-attempts", type=int, default=10)
    parser.add_argument("--max-wall-clock-s", type=int, default=14400)
    parser.add_argument("--max-attempt-wall-clock-s", type=int, default=2400)
    parser.add_argument("--scan-retries", type=int, default=2)
    parser.add_argument("--scan-sleep-s", type=int, default=30)
    parser.add_argument("--keep-instance", action="store_true")
    parser.add_argument("--no-restore", action="store_true")
    parser.add_argument("--download-fallback", action="store_true")
    parser.add_argument("--stop-after-first-pass", action="store_true")
    parser.add_argument(
        "--allow-runtime-gpu-mismatch",
        dest="allow_runtime_gpu_mismatch",
        action="store_true",
        default=True,
        help="Allow B200-published Scope tuple reuse on non-B200 GPUs",
    )
    parser.add_argument(
        "--strict-runtime-gpu-match",
        dest="allow_runtime_gpu_mismatch",
        action="store_false",
        help="Filter offers by smXX architecture inferred from --runtime-tag",
    )
    parser.add_argument("--selftest", action="store_true", help="Run no-cost unit checks and exit")
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    if args.plan_only:
        args.create_instance = False
    if args.offline_plan and args.create_instance:
        parser.error("--offline-plan cannot be combined with --create-instance")
    if args.max_attempts < 1:
        parser.error("--max-attempts must be >= 1")
    if args.max_budget_usd <= 0:
        parser.error("--max-budget-usd must be positive")
    parse_tiers(args.tiers)
    parse_resolution(args.target_res)
    parse_resolution_list(args.lower_resolutions)
    parse_resolution_list(args.upper_resolutions)
    return run_matrix(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
