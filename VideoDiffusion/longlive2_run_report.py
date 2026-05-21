#!/usr/bin/env python3
"""Create local QA reports for LongLive2 sequence-parallel runs."""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SAVED_RE = re.compile(r"(?:Saved|saved|write|wrote)[^:\n]*:\s*(\S+\.mp4)")
ERROR_RE = re.compile(r"(Traceback|RuntimeError|CUDA out of memory|Exception|error:)", re.IGNORECASE)
SP_RE = re.compile(r"(Ulysses|sequence parallel|\bsp_size\b|\[SP\])", re.IGNORECASE)
PHASE_RE = re.compile(r"^\[longlive2-vast-ts\]\s+(\S+)\s+(\S+)\s*$")


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def parse_iso_utc(raw: str) -> datetime:
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    parsed = datetime.fromisoformat(raw)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def parse_phase_markers(path: Path) -> dict[str, Any]:
    markers: list[dict[str, Any]] = []
    if not path.is_file():
        return {
            "phase_log": str(path),
            "markers": markers,
            "durations_s": {},
            "total_elapsed_s": None,
            "error": "phase log missing",
        }

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = PHASE_RE.match(line.strip())
        if not match:
            continue
        ts_raw, phase = match.groups()
        try:
            ts = parse_iso_utc(ts_raw)
        except ValueError:
            continue
        markers.append({"ts": ts.isoformat().replace("+00:00", "Z"), "phase": phase})

    by_phase = {row["phase"]: parse_iso_utc(row["ts"]) for row in markers}
    durations: dict[str, float] = {}
    for phase, start_ts in by_phase.items():
        if not phase.endswith("_start"):
            continue
        base = phase[: -len("_start")]
        candidates = [f"{base}_done", f"{base}_end", f"{base}_failed"]
        end_phase = next((candidate for candidate in candidates if candidate in by_phase), "")
        if end_phase:
            durations[base] = round((by_phase[end_phase] - start_ts).total_seconds(), 3)

    total_elapsed_s = None
    if len(markers) >= 2:
        total_elapsed_s = round(
            (parse_iso_utc(markers[-1]["ts"]) - parse_iso_utc(markers[0]["ts"])).total_seconds(),
            3,
        )

    return {
        "phase_log": str(path),
        "markers": markers,
        "durations_s": durations,
        "total_elapsed_s": total_elapsed_s,
        "error": "",
    }


def _selected_offer_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    offer = payload.get("selected_offer")
    if isinstance(offer, dict):
        return offer
    if "offer_id" in payload:
        return payload
    return {}


def _float_or_none(value: Any) -> float | None:
    try:
        if value in (None, ""):
            return None
        return float(value)
    except Exception:
        return None


def run_json_command(cmd: list[str]) -> dict[str, Any]:
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        return json.loads(out)
    except FileNotFoundError as exc:
        return {"error": f"missing executable: {exc.filename}"}
    except Exception as exc:
        return {"error": str(exc)}


def ffprobe_video(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {"error": "video missing"}
    return run_json_command(
        [
            "ffprobe",
            "-v",
            "error",
            "-count_frames",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=nb_read_frames,duration,width,height,avg_frame_rate",
            "-of",
            "json",
            str(path),
        ]
    )


def sample_luma_means(path: Path, sample_count: int) -> dict[str, Any]:
    if not path.is_file():
        return {"values": [], "error": "video missing"}
    if sample_count <= 0:
        return {"values": [], "error": ""}
    cmd = [
        "ffmpeg",
        "-v",
        "error",
        "-i",
        str(path),
        "-vf",
        "fps=1,scale=1:1,format=gray",
        "-frames:v",
        str(sample_count),
        "-f",
        "rawvideo",
        "-",
    ]
    try:
        raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
    except FileNotFoundError as exc:
        return {"values": [], "error": f"missing executable: {exc.filename}"}
    except Exception as exc:
        return {"values": [], "error": str(exc)}
    values = [int(byte) for byte in raw[:sample_count]]
    if not values:
        return {"values": [], "error": "no sampled luma bytes"}
    return {
        "values": values,
        "mean": round(statistics.fmean(values), 3),
        "min": min(values),
        "max": max(values),
        "nonblack": statistics.fmean(values) > 3.0,
        "error": "",
    }


def write_contact_sheet(path: Path, out_path: Path, sample_count: int) -> dict[str, Any]:
    if not path.is_file():
        return {"path": "", "error": "video missing"}
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cols = min(5, max(1, sample_count))
    rows = max(1, (sample_count + cols - 1) // cols)
    cmd = [
        "ffmpeg",
        "-v",
        "error",
        "-y",
        "-i",
        str(path),
        "-vf",
        f"fps=1,scale=160:-1,tile={cols}x{rows}",
        "-frames:v",
        "1",
        str(out_path),
    ]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, check=True)
    except FileNotFoundError as exc:
        return {"path": "", "error": f"missing executable: {exc.filename}"}
    except Exception as exc:
        return {"path": "", "error": str(exc)}
    return {"path": str(out_path) if out_path.is_file() else "", "error": "" if out_path.is_file() else "not written"}


def parse_scalar_config_value(config_path: Path, key: str) -> str:
    if not config_path.is_file():
        return ""
    pattern = re.compile(rf"^\s*{re.escape(key)}:\s*(.+?)\s*$")
    for line in config_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = pattern.match(line)
        if not match:
            continue
        raw = match.group(1).strip()
        if raw in {"null", "~"}:
            return ""
        if (raw.startswith("'") and raw.endswith("'")) or (raw.startswith('"') and raw.endswith('"')):
            return raw[1:-1].replace("''", "'")
        return raw
    return ""


def find_videos(run_dir: Path, config_path: Path, log_paths: list[str]) -> list[Path]:
    candidates: set[Path] = set()
    output_folder = parse_scalar_config_value(config_path, "output_folder")
    if output_folder:
        candidates.update(Path(output_folder).expanduser().glob("*.mp4"))
        candidates.update(Path(output_folder).expanduser().rglob("*.mp4"))
    candidates.update(run_dir.glob("*.mp4"))
    candidates.update((run_dir / "videos").glob("*.mp4"))
    candidates.update((run_dir / "videos").rglob("*.mp4"))
    for raw in log_paths:
        candidates.add(Path(raw).expanduser())
    existing = [path for path in candidates if path.is_file()]
    return sorted(existing, key=lambda p: (p.stat().st_mtime, str(p)), reverse=True)


def parse_torchrun_log(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {"path": str(path), "exists": False, "sp_markers": [], "saved_paths": [], "errors": []}
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    saved_paths: list[str] = []
    errors: list[str] = []
    sp_markers: list[str] = []
    for line in lines:
        for match in SAVED_RE.finditer(line):
            saved_paths.append(match.group(1))
        if ERROR_RE.search(line):
            errors.append(line[-500:])
        if SP_RE.search(line):
            sp_markers.append(line[-500:])
    return {
        "path": str(path),
        "exists": True,
        "line_count": len(lines),
        "sp_markers": sp_markers[:32],
        "saved_paths": saved_paths[:32],
        "errors": errors[-32:],
        "tail": lines[-40:],
    }


def _strip_unit(raw: str) -> float | None:
    cleaned = re.sub(r"[^0-9.]+", "", raw or "")
    if not cleaned:
        return None
    try:
        return float(cleaned)
    except ValueError:
        return None


def parse_gpu_telemetry(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {"path": str(path), "exists": False, "samples": 0, "gpus": []}
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace", newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)
    by_gpu: dict[str, dict[str, Any]] = {}
    for row in rows:
        idx = str(row.get("index") or row.get(" index") or "").strip()
        name = str(row.get("name") or row.get(" name") or "").strip()
        key = idx or name or "unknown"
        util = _strip_unit(str(row.get("utilization.gpu [%]") or row.get(" utilization.gpu [%]") or ""))
        mem_used = _strip_unit(str(row.get("memory.used [MiB]") or row.get(" memory.used [MiB]") or ""))
        mem_total = _strip_unit(str(row.get("memory.total [MiB]") or row.get(" memory.total [MiB]") or ""))
        entry = by_gpu.setdefault(
            key,
            {
                "index": idx,
                "name": name,
                "samples": 0,
                "max_utilization_pct": 0.0,
                "max_memory_used_mib": 0.0,
                "memory_total_mib": mem_total,
            },
        )
        entry["samples"] += 1
        if util is not None:
            entry["max_utilization_pct"] = max(float(entry["max_utilization_pct"]), util)
        if mem_used is not None:
            entry["max_memory_used_mib"] = max(float(entry["max_memory_used_mib"]), mem_used)
        if mem_total is not None:
            entry["memory_total_mib"] = mem_total
    return {"path": str(path), "exists": True, "samples": len(rows), "gpus": list(by_gpu.values())}


def build_artifact_qa(video_path: Path | None, out_dir: Path, sample_count: int) -> dict[str, Any]:
    if video_path is None:
        return {"video_path": "", "video_exists": False, "video_size_bytes": 0, "nonblank_ok": False}
    out_dir.mkdir(parents=True, exist_ok=True)
    qa = {
        "video_path": str(video_path),
        "video_exists": video_path.is_file(),
        "video_size_bytes": video_path.stat().st_size if video_path.is_file() else 0,
        "ffprobe": ffprobe_video(video_path),
        "luma_samples": sample_luma_means(video_path, sample_count),
        "contact_sheet": write_contact_sheet(video_path, out_dir / "contact_sheet.jpg", sample_count),
    }
    qa["nonblank_ok"] = bool(
        qa["video_exists"]
        and qa["video_size_bytes"] > 0
        and not qa["luma_samples"].get("error")
        and qa["luma_samples"].get("nonblack")
    )
    return qa


def write_report(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).expanduser().resolve()
    config_path = Path(args.config).expanduser().resolve() if args.config else run_dir / "longlive2_inference.yaml"
    report_path = Path(args.report_path).expanduser().resolve() if args.report_path else run_dir / "run_report.json"
    artifact_qa_path = run_dir / "artifact_qa.json"

    log = parse_torchrun_log(run_dir / "torchrun.log")
    videos = find_videos(run_dir, config_path, list(log.get("saved_paths") or []))
    selected_video = videos[0] if videos else None
    artifact_qa = build_artifact_qa(selected_video, run_dir / "qa", args.qa_sample_count)
    artifact_qa_path.write_text(json.dumps(artifact_qa, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    launch_plan = load_json(run_dir / "launch_plan.json")
    run_timing = load_json(run_dir / "run_timing.json")
    gpu_telemetry = parse_gpu_telemetry(run_dir / "gpu_telemetry.csv")
    acceptance = {
        "require_video": not args.allow_missing_video,
        "video_exists_ok": bool(selected_video and selected_video.is_file()) or args.allow_missing_video,
        "torchrun_errors_ok": not bool(log.get("errors")),
        "sp_marker_present": bool(log.get("sp_markers")) or int(launch_plan.get("nproc_per_node") or 1) <= 1,
        "telemetry_present": bool(gpu_telemetry.get("samples")) or args.allow_missing_telemetry,
        "artifact_nonblank_ok": bool(artifact_qa.get("nonblank_ok")) or args.allow_missing_video or bool(
            artifact_qa.get("luma_samples", {}).get("error")
        ),
        "wall_fps_ok": args.min_wall_fps <= 0
        or (_float_or_none(run_timing.get("wall_render_fps")) or 0.0) >= args.min_wall_fps,
    }
    acceptance["passed"] = all(
        acceptance[key]
        for key in (
            "video_exists_ok",
            "torchrun_errors_ok",
            "sp_marker_present",
            "telemetry_present",
            "artifact_nonblank_ok",
            "wall_fps_ok",
        )
    )

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "run_dir": str(run_dir),
        "config_path": str(config_path),
        "launch_plan": launch_plan,
        "run_timing": run_timing,
        "torchrun_log": log,
        "gpu_telemetry": gpu_telemetry,
        "videos": [str(path) for path in videos],
        "selected_video": str(selected_video) if selected_video else "",
        "artifact_qa": artifact_qa,
        "acceptance": acceptance,
    }
    report_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[longlive2-report] report={report_path}")
    print(f"[longlive2-report] selected_video={payload['selected_video']}")
    return 0 if acceptance["passed"] else 1


def write_phase_report(args: argparse.Namespace) -> int:
    phase_log = Path(args.phase_log).expanduser().resolve()
    out_path = Path(args.out).expanduser().resolve()
    selected_offer_payload = load_json(Path(args.selected_offer_json).expanduser()) if args.selected_offer_json else {}
    credit_payload = load_json(Path(args.credit_json).expanduser()) if args.credit_json else {}
    offer = _selected_offer_from_payload(selected_offer_payload)
    dph_total = _float_or_none(offer.get("dph_total"))
    phase_report = parse_phase_markers(phase_log)
    total_elapsed_s = _float_or_none(phase_report.get("total_elapsed_s"))
    observed_spend_usd = None
    if dph_total is not None and total_elapsed_s is not None:
        observed_spend_usd = round(dph_total * total_elapsed_s / 3600.0, 6)
    planned_spend_usd = None
    if dph_total is not None and args.budget_estimate_min > 0:
        planned_spend_usd = round(dph_total * args.budget_estimate_min / 60.0, 6)

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "run_id": args.run_id,
        "exit_code": args.exit_code,
        "local_out_dir": args.local_out_dir,
        "phase_report": phase_report,
        "selected_offer": {
            "offer_id": offer.get("offer_id"),
            "gpu_name": offer.get("gpu_name"),
            "num_gpus": offer.get("num_gpus"),
            "dph_total": offer.get("dph_total"),
            "reliability": offer.get("reliability"),
            "cuda_max_good": offer.get("cuda_max_good"),
        },
        "credit_check": {
            "checked": credit_payload.get("checked"),
            "credit_usd": credit_payload.get("credit_usd"),
            "requirements": credit_payload.get("requirements", {}),
            "error": credit_payload.get("error", ""),
        },
        "budget": {
            "max_alive_min": args.max_alive_min,
            "budget_estimate_min": args.budget_estimate_min,
            "planned_spend_usd": planned_spend_usd,
            "observed_spend_usd_from_phase_elapsed": observed_spend_usd,
            "note": "Observed spend is estimated from first to last wrapper phase marker and selected dph_total.",
        },
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[longlive2-phase-report] report={out_path}")
    return 0


def command_selftest() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        run_dir = root / "run"
        run_dir.mkdir()
        (run_dir / "launch_plan.json").write_text(
            json.dumps({"run_id": "selftest", "nproc_per_node": 2, "entrypoint": "inference_sp.py"}) + "\n",
            encoding="utf-8",
        )
        (run_dir / "torchrun.log").write_text(
            "[SP] Parallelism: sp_size=2 dp_size=1\n[SP] Saved: /tmp/missing.mp4\n",
            encoding="utf-8",
        )
        (run_dir / "gpu_telemetry.csv").write_text(
            "timestamp,index,name,utilization.gpu [%],memory.used [MiB],memory.total [MiB]\n"
            "2026-05-21 00:00:00,0,H200,91 %,12000 MiB,143000 MiB\n"
            "2026-05-21 00:00:00,1,H200,88 %,11800 MiB,143000 MiB\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(
            run_dir=str(run_dir),
            config="",
            report_path="",
            qa_sample_count=3,
            allow_missing_video=True,
            allow_missing_telemetry=False,
            min_wall_fps=0.0,
        )
        rc = write_report(args)
        report = load_json(run_dir / "run_report.json")
        assert rc == 0
        assert report["launch_plan"]["nproc_per_node"] == 2
        assert len(report["gpu_telemetry"]["gpus"]) == 2
        assert report["acceptance"]["passed"]
        phase_log = run_dir / "phase_markers.log"
        phase_log.write_text(
            "[longlive2-vast-ts] 2026-05-21T00:00:00Z setup_start\n"
            "[longlive2-vast-ts] 2026-05-21T00:00:05Z setup_done\n"
            "[longlive2-vast-ts] 2026-05-21T00:00:05Z longlive2_run_start\n"
            "[longlive2-vast-ts] 2026-05-21T00:00:17Z longlive2_run_done\n",
            encoding="utf-8",
        )
        selected = run_dir / "selected_offer.json"
        selected.write_text(
            json.dumps({"selected_offer": {"offer_id": "1", "gpu_name": "H200", "num_gpus": 2, "dph_total": 7.2}})
            + "\n",
            encoding="utf-8",
        )
        phase_args = argparse.Namespace(
            phase_log=str(phase_log),
            out=str(run_dir / "phase_report.json"),
            run_id="selftest",
            exit_code=0,
            local_out_dir=str(run_dir),
            selected_offer_json=str(selected),
            credit_json="",
            max_alive_min=45.0,
            budget_estimate_min=30.0,
        )
        assert write_phase_report(phase_args) == 0
        phase_report = load_json(run_dir / "phase_report.json")
        assert phase_report["phase_report"]["durations_s"]["setup"] == 5.0
        assert phase_report["phase_report"]["durations_s"]["longlive2_run"] == 12.0
        assert phase_report["budget"]["planned_spend_usd"] == 3.6
    print("[longlive2-report-selftest] ok")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    report = sub.add_parser("report", help="Write a LongLive2 run report")
    report.add_argument("--run-dir", required=True)
    report.add_argument("--config", default="")
    report.add_argument("--report-path", default="")
    report.add_argument("--qa-sample-count", type=int, default=5)
    report.add_argument("--allow-missing-video", action="store_true")
    report.add_argument("--allow-missing-telemetry", action="store_true")
    report.add_argument("--min-wall-fps", type=float, default=0.0)
    report.set_defaults(func=write_report)

    phase = sub.add_parser("phase-report", help="Write a wrapper phase/cost report")
    phase.add_argument("--phase-log", required=True)
    phase.add_argument("--out", required=True)
    phase.add_argument("--run-id", required=True)
    phase.add_argument("--exit-code", type=int, default=0)
    phase.add_argument("--local-out-dir", default="")
    phase.add_argument("--selected-offer-json", default="")
    phase.add_argument("--credit-json", default="")
    phase.add_argument("--max-alive-min", type=float, default=0.0)
    phase.add_argument("--budget-estimate-min", type=float, default=0.0)
    phase.set_defaults(func=write_phase_report)

    selftest = sub.add_parser("selftest", help="Run no-cost report checks")
    selftest.set_defaults(func=lambda _args: command_selftest())
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
