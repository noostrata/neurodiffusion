#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

RUN_ID="${LONGLIVE2_BENCH_RUN_ID:-longlive2_sp_benchmark_$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="${LONGLIVE2_BENCH_RUN_DIR:-${SCRIPT_DIR}/.tmp/${RUN_ID}}"
PROFILE="${LONGLIVE2_BENCH_PROFILE:-bf16_sp}"
HEIGHT="${LONGLIVE2_BENCH_HEIGHT:-480}"
WIDTH="${LONGLIVE2_BENCH_WIDTH:-832}"
FRAMES="${LONGLIVE2_BENCH_FRAMES:-32}"
DP_SIZE="${LONGLIVE2_BENCH_DP_SIZE:-1}"
SEED="${LONGLIVE2_BENCH_SEED:-0}"
PROMPT="${LONGLIVE2_BENCH_PROMPT:-A reactive neon tunnel breathes with smooth cinematic motion.}"
SAMPLING_STEPS="${LONGLIVE2_BENCH_SAMPLING_STEPS:-}"
SRC_DIR="${LONGLIVE2_SRC_DIR:-}"
DRY_RUN="${LONGLIVE2_BENCH_DRY_RUN:-0}"

usage() {
  cat <<EOF
Usage:
  bash VideoDiffusion/run_longlive2_sp_benchmark.sh [options]

Runs a same-prompt, same-seed LongLive2 SP comparison:
  A: sp_size=1, dp_size=${DP_SIZE}
  B: sp_size=2, dp_size=${DP_SIZE}

Options:
  --run-dir <path>              Benchmark artifact root (default: ${RUN_DIR})
  --profile <bf16_sp|nvfp4_s4|nvfp4_s2>
  --height <pixels>             Output height, divisible by 16 (default: ${HEIGHT})
  --width <pixels>              Output width, divisible by 16 (default: ${WIDTH})
  --frames <count>              Output frames, divisible by 8 (default: ${FRAMES})
  --dp-size <count>             Data-parallel group count (default: ${DP_SIZE})
  --seed <int>                  Shared seed (default: ${SEED})
  --prompt <text>               Shared prompt
  --sampling-steps <count>      Sampling steps override
  --src-dir <path>              LongLive2 checkout for run_longlive2_sp_offline.sh
  --dry-run                     Generate plans without launching torchrun
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      RUN_DIR="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --height)
      HEIGHT="$2"
      shift 2
      ;;
    --width)
      WIDTH="$2"
      shift 2
      ;;
    --frames)
      FRAMES="$2"
      shift 2
      ;;
    --dp-size)
      DP_SIZE="$2"
      shift 2
      ;;
    --seed)
      SEED="$2"
      shift 2
      ;;
    --prompt)
      PROMPT="$2"
      shift 2
      ;;
    --sampling-steps)
      SAMPLING_STEPS="$2"
      shift 2
      ;;
    --src-dir)
      SRC_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

run_case() {
  local label="$1"
  local sp_size="$2"
  local case_dir="${RUN_DIR}/${label}"
  mkdir -p "${case_dir}"
  local -a args=(
    --run-dir "${case_dir}"
    --profile "${PROFILE}"
    --height "${HEIGHT}"
    --width "${WIDTH}"
    --frames "${FRAMES}"
    --sp-size "${sp_size}"
    --dp-size "${DP_SIZE}"
    --seed "${SEED}"
    --prompt "${PROMPT}"
  )
  if [[ -n "${SAMPLING_STEPS}" ]]; then
    args+=(--sampling-steps "${SAMPLING_STEPS}")
  fi
  if [[ -n "${SRC_DIR}" ]]; then
    args+=(--src-dir "${SRC_DIR}")
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    args+=(--dry-run)
  fi

  local start end rc
  start="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  set +e
  bash "${SCRIPT_DIR}/run_longlive2_sp_offline.sh" "${args[@]}" 2>&1 | tee "${case_dir}/benchmark_wrapper.log"
  rc=${PIPESTATUS[0]}
  set -e
  end="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  python3 - "${case_dir}/case_summary.json" "${label}" "${sp_size}" "${DP_SIZE}" "${FRAMES}" "${start}" "${end}" "${rc}" "${DRY_RUN}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out, label, sp_size, dp_size, frames, start, end, rc, dry_run = sys.argv[1:]
start_f = float(start)
end_f = float(end)
elapsed = max(0.0, end_f - start_f)
frames_i = int(frames)
payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "label": label,
    "sp_size": int(sp_size),
    "dp_size": int(dp_size),
    "frames": frames_i,
    "return_code": int(rc),
    "dry_run": dry_run == "1",
    "wall_clock_s": round(elapsed, 6),
    "wall_fps": round(frames_i / elapsed, 6) if elapsed > 0 and dry_run != "1" else None,
}
Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  return "${rc}"
}

mkdir -p "${RUN_DIR}"
rc1=0
rc2=0
run_case "sp1" "1" || rc1=$?
run_case "sp2" "2" || rc2=$?

python3 - "${RUN_DIR}/sp_benchmark_report.json" "${RUN_ID}" "${RUN_DIR}" "${PROFILE}" "${HEIGHT}" "${WIDTH}" "${FRAMES}" "${DP_SIZE}" "${SEED}" "${rc1}" "${rc2}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out, run_id, run_dir, profile, height, width, frames, dp_size, seed, rc1, rc2 = sys.argv[1:]
root = Path(run_dir)
sp1 = json.loads((root / "sp1" / "case_summary.json").read_text(encoding="utf-8"))
sp2 = json.loads((root / "sp2" / "case_summary.json").read_text(encoding="utf-8"))
fps1 = sp1.get("wall_fps")
fps2 = sp2.get("wall_fps")
speedup = round(float(fps2) / float(fps1), 6) if fps1 and fps2 else None
payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "run_id": run_id,
    "run_dir": str(root),
    "profile": profile,
    "height": int(height),
    "width": int(width),
    "frames": int(frames),
    "dp_size": int(dp_size),
    "seed": int(seed),
    "sp1": sp1,
    "sp2": sp2,
    "speedup_sp2_over_sp1": speedup,
    "acceptance_hint": (
        "stop" if speedup is not None and speedup < 1.3
        else "research_or_continue" if speedup is not None and speedup < 1.6
        else "serious_live_candidate" if speedup is not None
        else "not_measured"
    ),
    "return_code": 0 if int(rc1) == 0 and int(rc2) == 0 else 1,
}
Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"[longlive2-sp-benchmark] report={out}")
if speedup is not None:
    print(f"[longlive2-sp-benchmark] speedup_sp2_over_sp1={speedup}")
PY

if [[ "${rc1}" -ne 0 || "${rc2}" -ne 0 ]]; then
  exit 1
fi
