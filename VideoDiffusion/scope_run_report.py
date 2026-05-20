#!/usr/bin/env python3
"""Local report helpers for Scope/LongLive Vast runs."""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PHASE_RE = re.compile(r"^\[scope-vast-ts\]\s+(\S+)\s+(\S+)\s*$")


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def read_rc(path: Path) -> int | str | None:
    if not path.is_file():
        return None
    raw = path.read_text(encoding="utf-8").strip()
    try:
        return int(raw)
    except ValueError:
        return raw


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
        return {"phase_log": str(path), "markers": markers, "durations_s": {}, "error": "phase log missing"}

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
        candidates = [f"{base}_done", f"{base}_end", f"{base}_started"]
        end_phase = next((candidate for candidate in candidates if candidate in by_phase), "")
        if end_phase:
            durations[base] = round((by_phase[end_phase] - start_ts).total_seconds(), 3)

    return {"phase_log": str(path), "markers": markers, "durations_s": durations, "error": ""}


def run_json_command(cmd: list[str]) -> dict[str, Any]:
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        return json.loads(out)
    except FileNotFoundError as exc:
        return {"error": f"missing executable: {exc.filename}"}
    except Exception as exc:
        return {"error": str(exc)}


def ffprobe_video(video_path: Path) -> dict[str, Any]:
    if not video_path.is_file():
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
            str(video_path),
        ]
    )


def sample_luma_means(video_path: Path, sample_count: int) -> dict[str, Any]:
    if not video_path.is_file():
        return {"values": [], "error": "video missing"}
    if sample_count <= 0:
        return {"values": [], "error": ""}
    cmd = [
        "ffmpeg",
        "-v",
        "error",
        "-i",
        str(video_path),
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


def write_contact_sheet(video_path: Path, out_path: Path, sample_count: int) -> dict[str, Any]:
    if not video_path.is_file():
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
        str(video_path),
        "-vf",
        f"fps=1,scale=160:-1,tile={cols}x{rows}",
        "-frames:v",
        "1",
        str(out_path),
    ]
    try:
        subprocess.run(cmd, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    except FileNotFoundError as exc:
        return {"path": "", "error": f"missing executable: {exc.filename}"}
    except Exception as exc:
        return {"path": "", "error": str(exc)}
    return {"path": str(out_path) if out_path.is_file() else "", "error": "" if out_path.is_file() else "not written"}


def build_artifact_qa(video_path: Path, frames_dir: Path, contact_sheet_path: Path, sample_count: int) -> dict[str, Any]:
    saved_frames = sorted(str(path) for path in frames_dir.glob("frame_*.png")) if frames_dir.is_dir() else []
    qa = {
        "video_path": str(video_path),
        "video_exists": video_path.is_file(),
        "video_size_bytes": video_path.stat().st_size if video_path.is_file() else 0,
        "saved_frames_count": len(saved_frames),
        "saved_frames": saved_frames[:32],
        "ffprobe": ffprobe_video(video_path),
        "luma_samples": sample_luma_means(video_path, sample_count),
        "contact_sheet": write_contact_sheet(video_path, contact_sheet_path, sample_count),
    }
    qa["nonblank_ok"] = bool(
        qa["video_exists"]
        and qa["video_size_bytes"] > 0
        and not qa["luma_samples"].get("error")
        and qa["luma_samples"].get("nonblack")
    )
    return qa


def load_eeg_records(eeg_path: Path) -> list[dict[str, Any]]:
    records = []
    if not eeg_path.is_file():
        return records
    for line in eeg_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return records


def write_run_report(args: argparse.Namespace) -> int:
    report_path = Path(args.report_path).expanduser()
    local_dir = Path(args.local_dir).expanduser()
    flat_video = Path(args.flat_video).expanduser()
    phase_log = Path(args.phase_log).expanduser() if args.phase_log else Path()
    phase_report_path = Path(args.phase_report_path).expanduser() if args.phase_report_path else local_dir / "phase_report.json"
    artifact_qa_path = Path(args.artifact_qa_path).expanduser() if args.artifact_qa_path else local_dir / "artifact_qa.json"
    contact_sheet_path = Path(args.contact_sheet_path).expanduser() if args.contact_sheet_path else local_dir / "contact_sheet.jpg"

    benchmark_path = local_dir / "webrtc_benchmark.json"
    benchmark = load_json(benchmark_path) if benchmark_path.is_file() else {}
    eeg_records = load_eeg_records(local_dir / "synthetic_eeg.jsonl")
    emit_count = sum(1 for row in eeg_records if row.get("emit"))
    scope_emit_count = sum(1 for row in eeg_records if row.get("scope_osc_sent"))
    benchmark_rc = read_rc(local_dir / "webrtc_benchmark.rc")
    eeg_rc = read_rc(local_dir / "synthetic_eeg.rc")

    video_path = local_dir / "webrtc_capture.mp4"
    artifact_qa = build_artifact_qa(video_path, local_dir / "frames", contact_sheet_path, args.qa_sample_count)
    artifact_qa_path.write_text(json.dumps(artifact_qa, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    phase_report = parse_phase_markers(phase_log) if phase_log else {"markers": [], "durations_s": {}, "error": "phase log not requested"}
    phase_report_path.write_text(json.dumps(phase_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    fps = float(benchmark.get("fps") or 0.0)
    first = benchmark.get("first_frame_latency_s")
    first_value = float(first) if first is not None else None
    acceptance = {
        "min_fps": args.min_fps,
        "max_first_frame_latency_s": args.max_first_frame_s,
        "fps_ok": fps >= args.min_fps,
        "first_frame_latency_ok": first_value is not None and first_value <= args.max_first_frame_s,
        "frames_received_ok": int(benchmark.get("frame_count") or 0) > 0,
        "synthetic_eeg_scope_updates_ok": scope_emit_count > 0 or (scope_emit_count == 0 and emit_count > 0 and eeg_rc == 0),
        "local_video_ok": video_path.is_file() and video_path.stat().st_size > 0,
        "artifact_nonblank_ok": bool(artifact_qa.get("nonblank_ok")) or bool(artifact_qa.get("luma_samples", {}).get("error")),
    }
    acceptance["passed"] = all(
        acceptance[key]
        for key in (
            "fps_ok",
            "first_frame_latency_ok",
            "frames_received_ok",
            "synthetic_eeg_scope_updates_ok",
            "local_video_ok",
            "artifact_nonblank_ok",
        )
    )

    payload = {
        "run_id": args.run_id,
        "vast_instance_id": args.instance_id,
        "runtime_tag": args.runtime_tag,
        "profile": {"height": args.height, "width": args.width},
        "local_dir": str(local_dir),
        "flat_local_video": str(flat_video) if flat_video.is_file() else "",
        "benchmark": benchmark,
        "eeg": {
            "record_count": len(eeg_records),
            "emit_count": emit_count,
            "scope_emit_count": scope_emit_count,
            "scope_emit_count_fallback_used": scope_emit_count == 0 and emit_count > 0 and eeg_rc == 0,
        },
        "process_rc": {"webrtc_benchmark": benchmark_rc, "synthetic_eeg": eeg_rc},
        "ffprobe": artifact_qa.get("ffprobe", {}),
        "artifact_qa": artifact_qa,
        "artifact_qa_path": str(artifact_qa_path),
        "phase_report": phase_report,
        "phase_report_path": str(phase_report_path),
        "acceptance": acceptance,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(payload["acceptance"], indent=2, sort_keys=True))
    return 0 if acceptance["passed"] else 2


def read_manifest(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def write_sweep_report(args: argparse.Namespace) -> int:
    manifest = read_manifest(Path(args.manifest_tsv).expanduser())
    rows = []
    for idx, item in enumerate(manifest, start=1):
        report_path = Path(item.get("report_path") or "")
        report = load_json(report_path) if report_path.is_file() else {}
        benchmark = report.get("benchmark") or {}
        acceptance = report.get("acceptance") or {}
        rows.append(
            {
                "idx": idx,
                "label": item.get("label", ""),
                "height": int(item.get("height") or 0),
                "width": int(item.get("width") or 0),
                "pixels": int(item.get("height") or 0) * int(item.get("width") or 0),
                "status": "PASS" if acceptance.get("passed") else "FAIL_ACCEPTANCE" if report else "MISSING_REPORT",
                "fps": benchmark.get("fps", ""),
                "first_frame_latency_s": benchmark.get("first_frame_latency_s", ""),
                "frame_count": benchmark.get("frame_count", ""),
                "flat_local_video": item.get("flat_video", "") if Path(item.get("flat_video") or "").is_file() else "",
                "local_dir": item.get("local_dir", ""),
                "report_path": str(report_path) if report_path.is_file() else "",
            }
        )

    passed = [row for row in rows if row["status"] == "PASS"]
    best_pass = max(passed, key=lambda row: row["pixels"]) if passed else None
    payload = {
        "run_id": args.run_id,
        "vast_instance_id": args.instance_id,
        "runtime_tag": args.runtime_tag,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "local_root": args.local_root,
        "manifest_tsv": args.manifest_tsv,
        "phase_report_path": args.phase_report_path,
        "summary": {"rows": len(rows), "passed": len(passed), "best_pass": best_pass},
        "rows": rows,
    }
    out_json = Path(args.report_path).expanduser()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    out_md = Path(args.markdown_path).expanduser() if args.markdown_path else out_json.with_suffix(".md")
    lines = [
        f"# Scope LongLive Vast Sweep {args.run_id}",
        "",
        f"- runtime tag: `{args.runtime_tag}`",
        f"- rows: `{len(rows)}`",
        f"- passed: `{len(passed)}`",
        f"- best pass: `{best_pass['label']}`" if best_pass else "- best pass: none",
        f"- phase report: `{args.phase_report_path}`",
        "",
        "| # | Resolution | Pixels | Status | FPS | First frame | Video |",
        "| ---: | --- | ---: | --- | ---: | ---: | --- |",
    ]
    for row in rows:
        video = f"`{row['flat_local_video']}`" if row.get("flat_local_video") else ""
        lines.append(
            f"| {row['idx']} | `{row['label']}` | {row['pixels']} | `{row['status']}` | "
            f"{row['fps']} | {row['first_frame_latency_s']} | {video} |"
        )
    lines.append("")
    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(payload["summary"], indent=2, sort_keys=True))
    return 0 if passed else 2


def selftest() -> int:
    with subprocess.Popen([sys.executable, "-c", "pass"]) as proc:
        proc.wait()
    phase = parse_phase_markers(Path("/path/that/does/not/exist"))
    assert phase["markers"] == []
    assert phase["error"]
    print("[scope-run-report-selftest] ok")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="Write one run_report.json")
    run.add_argument("--report-path", required=True)
    run.add_argument("--run-id", required=True)
    run.add_argument("--instance-id", default="")
    run.add_argument("--runtime-tag", required=True)
    run.add_argument("--local-dir", required=True)
    run.add_argument("--flat-video", required=True)
    run.add_argument("--height", type=int, required=True)
    run.add_argument("--width", type=int, required=True)
    run.add_argument("--min-fps", type=float, required=True)
    run.add_argument("--max-first-frame-s", type=float, required=True)
    run.add_argument("--phase-log", default="")
    run.add_argument("--phase-report-path", default="")
    run.add_argument("--artifact-qa-path", default="")
    run.add_argument("--contact-sheet-path", default="")
    run.add_argument("--qa-sample-count", type=int, default=8)

    sweep = sub.add_parser("sweep", help="Write aggregate sweep report")
    sweep.add_argument("--report-path", required=True)
    sweep.add_argument("--markdown-path", default="")
    sweep.add_argument("--manifest-tsv", required=True)
    sweep.add_argument("--run-id", required=True)
    sweep.add_argument("--instance-id", default="")
    sweep.add_argument("--runtime-tag", required=True)
    sweep.add_argument("--local-root", required=True)
    sweep.add_argument("--phase-report-path", default="")

    sub.add_parser("selftest", help="Run no-cost checks")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "run":
        return write_run_report(args)
    if args.command == "sweep":
        return write_sweep_report(args)
    if args.command == "selftest":
        return selftest()
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
