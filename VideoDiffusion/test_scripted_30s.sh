#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PYTHON_BIN="${VIDEO_MAGE_PYTHON_BIN:-python3}"
TORCHRUN_BIN="${VIDEO_MAGE_TORCHRUN_BIN:-torchrun}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "[error] Python interpreter not found: ${PYTHON_BIN}" >&2
  exit 1
fi
if ! command -v "${TORCHRUN_BIN}" >/dev/null 2>&1; then
  echo "[error] torchrun not found: ${TORCHRUN_BIN}" >&2
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[error] ffmpeg not found." >&2
  exit 1
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "[error] ffprobe not found." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "[error] curl not found." >&2
  exit 1
fi

SCHEDULE_CSV="${SCHEDULE_CSV:-${SCRIPT_DIR}/prompt_schedules/cyberpunk_30s_hybrid.csv}"
if [ ! -f "${SCHEDULE_CSV}" ]; then
  echo "[error] Schedule file not found: ${SCHEDULE_CSV}" >&2
  exit 1
fi

BUDGET_USD="${BUDGET_USD:-15}"
HOURLY_RATE_USD="${HOURLY_RATE_USD:-}"
if [ -z "${HOURLY_RATE_USD}" ]; then
  echo "[error] HOURLY_RATE_USD is required. Example: HOURLY_RATE_USD=0.6068" >&2
  exit 1
fi

MAGI_TIER="${MAGI_TIER:-4p5b}"
case "${MAGI_TIER}" in
  4p5b|24b)
    ;;
  *)
    echo "[error] MAGI_TIER must be one of: 4p5b, 24b (got '${MAGI_TIER}')." >&2
    exit 1
    ;;
esac

MAGI_CONFIG_FILE="${MAGI_CONFIG_FILE:-}"
if [ -z "${MAGI_CONFIG_FILE}" ] && [ "${MAGI_TIER}" = "24b" ]; then
  MAGI_CONFIG_FILE="example/24B/24B_config.json"
fi
if [ -n "${MAGI_CONFIG_FILE}" ]; then
  if [[ "${MAGI_CONFIG_FILE}" != /* ]]; then
    if [ -f "${SCRIPT_DIR}/${MAGI_CONFIG_FILE}" ]; then
      MAGI_CONFIG_FILE="${SCRIPT_DIR}/${MAGI_CONFIG_FILE}"
    elif [ -f "${SCRIPT_DIR}/MAGI-1/${MAGI_CONFIG_FILE}" ]; then
      MAGI_CONFIG_FILE="${SCRIPT_DIR}/MAGI-1/${MAGI_CONFIG_FILE}"
    fi
  fi
  if [ ! -f "${MAGI_CONFIG_FILE}" ]; then
    echo "[error] MAGI_CONFIG_FILE not found: ${MAGI_CONFIG_FILE}" >&2
    exit 1
  fi
fi

CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
MAGI_CP_SIZE_OVERRIDE="${MAGI_CP_SIZE:-}"
MAGI_PP_SIZE_OVERRIDE="${MAGI_PP_SIZE:-}"

MAGI_VIDEO_SIZE_H="${MAGI_VIDEO_SIZE_H:-640}"
MAGI_VIDEO_SIZE_W="${MAGI_VIDEO_SIZE_W:-640}"
if [ "${MAGI_TIER}" = "24b" ]; then
  MAGI_NUM_STEPS="${MAGI_NUM_STEPS:-8}"
else
  MAGI_NUM_STEPS="${MAGI_NUM_STEPS:-16}"
fi
MAGI_NUM_FRAMES="${MAGI_NUM_FRAMES:-720}"
MAGI_WINDOW_SIZE="${MAGI_WINDOW_SIZE:-1}"
QUEUE_LEN="${QUEUE_LEN:-96}"
DROP_OLD_ON_PROMPT="${DROP_OLD_ON_PROMPT:-1}"
JPEG_QUALITY="${JPEG_QUALITY:-75}"
SERVER_PORT="${SERVER_PORT:-8000}"
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
BASE_URL="http://${SERVER_HOST}:${SERVER_PORT}"
TARGET_TPOC_S="${TARGET_TPOC_S:-1.0}"

SCHEDULE_POLL_S="${SCHEDULE_POLL_S:-0.25}"
SCHEDULE_TIMEOUT_S="${SCHEDULE_TIMEOUT_S:-180}"
SERVER_READY_TIMEOUT_S="${SERVER_READY_TIMEOUT_S:-240}"
CALIB_CHUNKS="${CALIB_CHUNKS:-6}"
CALIB_FRAMES="$((CALIB_CHUNKS * 24))"
CALIB_RUNG_LIST="${CALIB_RUNG_LIST:-}"
if [ -z "${CALIB_RUNG_LIST}" ]; then
  if [ "${MAGI_TIER}" = "24b" ]; then
    CALIB_RUNG_LIST="4,8"
  else
    CALIB_RUNG_LIST="1,3,4"
  fi
fi

SCRIPTED_RUN_TAG="${SCRIPTED_RUN_TAG:-}"
RUN_TAG_CLEAN="$(printf "%s" "${SCRIPTED_RUN_TAG}" | tr -cd 'A-Za-z0-9_.-')"

if [ -n "${RUN_TAG_CLEAN}" ]; then
  RUN_ID="scripted30s_${RUN_TAG_CLEAN}_$(date +%Y%m%d_%H%M%S)_${RANDOM}"
else
  RUN_ID="scripted30s_$(date +%Y%m%d_%H%M%S)_${RANDOM}"
fi
TMP_DIR="${SCRIPT_DIR}/.tmp"
mkdir -p "${TMP_DIR}"

OUTPUT_FILE="${VIDEO_SCRIPTED_OUTPUT:-${SCRIPT_DIR}/magi_scripted_30s.mp4}"
REPORT_JSON="${TMP_DIR}/${RUN_ID}_script_injection_report.json"
REPORT_CSV="${TMP_DIR}/${RUN_ID}_script_injection_report.csv"
SUMMARY_JSON="${TMP_DIR}/${RUN_ID}_summary.json"
CALIB_JSON="${TMP_DIR}/${RUN_ID}_calibration.json"
METRICS_JSON="${TMP_DIR}/${RUN_ID}_metrics.json"
FFPROBE_JSON="${TMP_DIR}/${RUN_ID}_ffprobe.json"
BUDGET_ABORT_FLAG="${TMP_DIR}/${RUN_ID}_budget_abort.flag"
CALIB_RESULTS_CSV="${TMP_DIR}/${RUN_ID}_calibration_results.csv"

START_TS_ISO="$(${PYTHON_BIN} - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat(timespec="seconds"))
PY
)"

STREAM_PID=""
FFMPEG_PID=""
WATCHDOG_PID=""
FINAL_STATUS="INIT"
FINAL_MESSAGE=""
SELECTED_NPROC=""
SELECTED_DEVICES=""
FINAL_STREAM_LOG=""

MAX_RUNTIME_SEC="$(${PYTHON_BIN} - <<PY
import math
budget = float("${BUDGET_USD}")
rate = float("${HOURLY_RATE_USD}")
if rate <= 0:
    raise SystemExit(2)
print(int(math.floor((budget * 0.90 / rate) * 3600)))
PY
)" || {
  echo "[error] Invalid BUDGET_USD or HOURLY_RATE_USD." >&2
  exit 1
}
if [ "${MAX_RUNTIME_SEC}" -le 0 ]; then
  echo "[error] MAX_RUNTIME_SEC computed to <=0. Check BUDGET_USD and HOURLY_RATE_USD." >&2
  exit 1
fi

IFS=',' read -r -a DEVICE_LIST <<< "${CUDA_VISIBLE_DEVICES}"
GPU_COUNT="${#DEVICE_LIST[@]}"
if [ "${GPU_COUNT}" -lt 1 ]; then
  echo "[error] No CUDA devices in CUDA_VISIBLE_DEVICES='${CUDA_VISIBLE_DEVICES}'." >&2
  exit 1
fi

first_prompt="$(${PYTHON_BIN} - "${SCHEDULE_CSV}" <<'PY'
import csv
import sys
path = sys.argv[1]
first = None
first_zero = None
with open(path, "r", encoding="utf-8", newline="") as f:
    r = csv.DictReader(f)
    for row in r:
        prompt = (row.get("prompt") or "").strip()
        if not prompt:
            continue
        if first is None:
            first = prompt
        try:
            start = int((row.get("start_chunk") or "").strip())
        except Exception:
            continue
        if start == 0 and first_zero is None:
            first_zero = prompt
            break
print(first_zero or first or "sunset over baltic sea")
PY
)"

cleanup() {
  if [ -n "${FFMPEG_PID}" ] && kill -0 "${FFMPEG_PID}" >/dev/null 2>&1; then
    kill "${FFMPEG_PID}" >/dev/null 2>&1 || true
    wait "${FFMPEG_PID}" >/dev/null 2>&1 || true
  fi
  if [ -n "${STREAM_PID}" ] && kill -0 "${STREAM_PID}" >/dev/null 2>&1; then
    kill "${STREAM_PID}" >/dev/null 2>&1 || true
    wait "${STREAM_PID}" >/dev/null 2>&1 || true
  fi
  if [ -n "${WATCHDOG_PID}" ] && kill -0 "${WATCHDOG_PID}" >/dev/null 2>&1; then
    kill "${WATCHDOG_PID}" >/dev/null 2>&1 || true
    wait "${WATCHDOG_PID}" >/dev/null 2>&1 || true
  fi
}

write_summary() {
  local status="$1"
  local message="$2"
  STATUS="${status}" MESSAGE="${message}" ${PYTHON_BIN} - <<PY
import json
import os
from datetime import datetime, timezone

def load_json(path):
    if not path or not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        try:
            return json.load(f)
        except Exception:
            return None

summary = {
    "run_id": "${RUN_ID}",
    "status": os.environ.get("STATUS", "UNKNOWN"),
    "message": os.environ.get("MESSAGE", ""),
    "start_ts": "${START_TS_ISO}",
    "end_ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "config": {
        "budget_usd": float("${BUDGET_USD}"),
        "hourly_rate_usd": float("${HOURLY_RATE_USD}"),
        "max_runtime_sec": int("${MAX_RUNTIME_SEC}"),
        "base_url": "${BASE_URL}",
        "magi_tier": "${MAGI_TIER}",
        "magi_config_file": "${MAGI_CONFIG_FILE}",
        "schedule_csv": "${SCHEDULE_CSV}",
        "cuda_visible_devices": "${CUDA_VISIBLE_DEVICES}",
        "selected_nproc": "${SELECTED_NPROC}",
        "selected_devices": "${SELECTED_DEVICES}",
        "video_size_h": int("${MAGI_VIDEO_SIZE_H}"),
        "video_size_w": int("${MAGI_VIDEO_SIZE_W}"),
        "num_steps": int("${MAGI_NUM_STEPS}"),
        "num_frames": int("${MAGI_NUM_FRAMES}"),
        "window_size": int("${MAGI_WINDOW_SIZE}"),
    },
    "artifacts": {
        "output_file": "${OUTPUT_FILE}",
        "schedule_report_json": "${REPORT_JSON}",
        "schedule_report_csv": "${REPORT_CSV}",
        "calibration_json": "${CALIB_JSON}",
        "metrics_json": "${METRICS_JSON}",
        "ffprobe_json": "${FFPROBE_JSON}",
        "final_stream_log": "${FINAL_STREAM_LOG}",
    },
    "schedule_report": load_json("${REPORT_JSON}"),
    "calibration": load_json("${CALIB_JSON}"),
    "metrics": load_json("${METRICS_JSON}"),
    "ffprobe": load_json("${FFPROBE_JSON}"),
}

with open("${SUMMARY_JSON}", "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
PY
}

on_err() {
  local line="$1"
  if [ -f "${BUDGET_ABORT_FLAG}" ]; then
    FINAL_STATUS="BUDGET_ABORT"
    FINAL_MESSAGE="Budget guard timeout reached."
  elif [ "${FINAL_STATUS}" = "INIT" ] || [ "${FINAL_STATUS}" = "OK" ]; then
    FINAL_STATUS="FAILED"
    FINAL_MESSAGE="Command failed at line ${line}."
  fi
}

on_term() {
  if [ -f "${BUDGET_ABORT_FLAG}" ]; then
    FINAL_STATUS="BUDGET_ABORT"
    FINAL_MESSAGE="Budget guard timeout reached."
  else
    FINAL_STATUS="TERMINATED"
    FINAL_MESSAGE="Received termination signal."
  fi
  exit 124
}

on_exit() {
  cleanup
  if [ -f "${BUDGET_ABORT_FLAG}" ]; then
    FINAL_STATUS="BUDGET_ABORT"
    if [ -z "${FINAL_MESSAGE}" ]; then
      FINAL_MESSAGE="Budget guard timeout reached."
    fi
  fi
  if [ "${FINAL_STATUS}" = "INIT" ]; then
    FINAL_STATUS="OK"
    FINAL_MESSAGE="Run completed."
  fi
  write_summary "${FINAL_STATUS}" "${FINAL_MESSAGE}"
  echo "[result] status=${FINAL_STATUS}"
  echo "[result] summary=${SUMMARY_JSON}"
  echo "[result] output=${OUTPUT_FILE}"
  echo "[result] schedule_report=${REPORT_JSON}"
}

trap 'on_err ${LINENO}' ERR
trap on_term TERM INT
trap on_exit EXIT

(
  sleep "${MAX_RUNTIME_SEC}"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${BUDGET_ABORT_FLAG}"
  echo "[budget] Max runtime reached (${MAX_RUNTIME_SEC}s). Triggering abort." >&2
  kill -TERM "$$" >/dev/null 2>&1 || true
) &
WATCHDOG_PID="$!"

wait_for_server() {
  local timeout_s="$1"
  local deadline=$((SECONDS + timeout_s))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if curl -fsS "${BASE_URL}/stats" >/dev/null 2>&1; then
      return 0
    fi
    if [ -n "${STREAM_PID}" ] && ! kill -0 "${STREAM_PID}" >/dev/null 2>&1; then
      echo "[error] Stream process exited before server became ready." >&2
      return 1
    fi
    sleep 1
  done
  echo "[error] Timed out waiting for ${BASE_URL}/stats" >&2
  return 1
}

device_subset() {
  local n="$1"
  if [ "${n}" -gt "${GPU_COUNT}" ]; then
    return 1
  fi
  local out=""
  local i=0
  while [ "${i}" -lt "${n}" ]; do
    if [ -n "${out}" ]; then
      out+=","
    fi
    out+="${DEVICE_LIST[${i}]}"
    i=$((i + 1))
  done
  echo "${out}"
}

start_stream() {
  local nproc="$1"
  local devices="$2"
  local num_frames="$3"
  local log_path="$4"
  local init_prompt="$5"

  export CUDA_VISIBLE_DEVICES="${devices}"
  export SERVER_PORT
  export QUEUE_LEN
  export DROP_OLD_ON_PROMPT
  export JPEG_QUALITY
  export MAGI_VIDEO_SIZE_H
  export MAGI_VIDEO_SIZE_W
  export MAGI_NUM_STEPS
  export MAGI_NUM_FRAMES="${num_frames}"
  export MAGI_WINDOW_SIZE
  if [ -n "${MAGI_CONFIG_FILE}" ]; then
    export MAGI_CONFIG_FILE
  else
    unset MAGI_CONFIG_FILE || true
  fi
  export MAGI_INITIAL_PROMPT="${init_prompt}"
  export MAGI_CP_SIZE="${MAGI_CP_SIZE_OVERRIDE:-${nproc}}"
  export MAGI_PP_SIZE="${MAGI_PP_SIZE_OVERRIDE:-1}"

  if [ "${nproc}" -gt 1 ]; then
    "${TORCHRUN_BIN}" --standalone --nproc_per_node="${nproc}" realtime_magi_stream.py >"${log_path}" 2>&1 &
  else
    "${PYTHON_BIN}" realtime_magi_stream.py >"${log_path}" 2>&1 &
  fi
  STREAM_PID="$!"
}

stop_stream() {
  if [ -n "${STREAM_PID}" ] && kill -0 "${STREAM_PID}" >/dev/null 2>&1; then
    kill "${STREAM_PID}" >/dev/null 2>&1 || true
    wait "${STREAM_PID}" >/dev/null 2>&1 || true
  fi
  STREAM_PID=""
}

collect_chunk_timings() {
  local output_json="$1"
  local target_chunks="$2"
  local poll_s="$3"
  local timeout_s="$4"
  ${PYTHON_BIN} - "${BASE_URL}" "${output_json}" "${target_chunks}" "${poll_s}" "${timeout_s}" <<'PY'
import json
import sys
import time
import urllib.request
import urllib.error

url, out_path, target_raw, poll_raw, timeout_raw = sys.argv[1:]
target = int(target_raw)
poll_s = float(poll_raw)
timeout_s = float(timeout_raw)

start = time.monotonic()
seen = set()
chunks = []

while time.monotonic() - start <= timeout_s:
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/stats", timeout=10) as resp:
            stats = json.loads(resp.read().decode("utf-8", errors="replace"))
    except Exception:
        time.sleep(poll_s)
        continue

    chunk_idx = stats.get("chunk_idx")
    gen_time = stats.get("last_gen_time_s")
    if isinstance(chunk_idx, int) and chunk_idx not in seen and gen_time is not None:
        seen.add(chunk_idx)
        try:
            gen_time = float(gen_time)
        except Exception:
            gen_time = None
        chunks.append(
            {
                "chunk_idx": chunk_idx,
                "gen_time_s": gen_time,
                "last_prompt": stats.get("last_prompt"),
            }
        )
        if len(chunks) >= target:
            break

    time.sleep(poll_s)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"chunks": chunks, "target_chunks": target}, f, indent=2)

if len(chunks) < target:
    raise SystemExit(2)
PY
}

printf "rung_nproc,devices,status,chunk_count,steady_mean_s,steady_p90_s,pass,stream_log,timings_json\n" > "${CALIB_RESULTS_CSV}"

echo "[info] Starting calibration ladder (1 -> 3 -> 4 GPUs when available)"
IFS=',' read -r -a CALIB_RUNGS <<< "${CALIB_RUNG_LIST}"
LAST_TESTED_NPROC=""
LAST_TESTED_DEVICES=""
for rung in "${CALIB_RUNGS[@]}"; do
  rung="$(echo "${rung}" | xargs)"
  if [ -z "${rung}" ]; then
    continue
  fi
  if ! [[ "${rung}" =~ ^[0-9]+$ ]]; then
    echo "[warn] Skipping invalid rung '${rung}'"
    continue
  fi
  if [ "${rung}" -gt "${GPU_COUNT}" ]; then
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "${rung}" "" "skipped_insufficient_devices" "0" "" "" "0" "" "" >> "${CALIB_RESULTS_CSV}"
    continue
  fi

  devices="$(device_subset "${rung}")"
  rung_log="${TMP_DIR}/${RUN_ID}_calib_${rung}gpu_stream.log"
  rung_timings="${TMP_DIR}/${RUN_ID}_calib_${rung}gpu_timings.json"

  echo "[info] Calibration rung nproc=${rung} devices=${devices}"
  start_stream "${rung}" "${devices}" "${CALIB_FRAMES}" "${rung_log}" "${first_prompt}"
  wait_for_server "${SERVER_READY_TIMEOUT_S}"
  if ! collect_chunk_timings "${rung_timings}" "${CALIB_CHUNKS}" "${SCHEDULE_POLL_S}" "${SCHEDULE_TIMEOUT_S}"; then
    stop_stream
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "${rung}" "${devices}" "failed_collect" "0" "" "" "0" "${rung_log}" "${rung_timings}" >> "${CALIB_RESULTS_CSV}"
    continue
  fi
  stop_stream

  read -r chunk_count steady_mean steady_p90 <<<"$(${PYTHON_BIN} - "${rung_timings}" <<'PY'
import json
import statistics
import sys

def pctl(xs, p):
    if not xs:
        return float("nan")
    ys = sorted(xs)
    if len(ys) == 1:
        return ys[0]
    k = (len(ys) - 1) * p
    f = int(k)
    c = min(f + 1, len(ys) - 1)
    if f == c:
        return ys[f]
    return ys[f] * (c - k) + ys[c] * (k - f)

with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
times = [float(c["gen_time_s"]) for c in payload.get("chunks", []) if c.get("gen_time_s") is not None]
steady = times[1:] if len(times) > 1 else times
count = len(times)
mean = statistics.mean(steady) if steady else float("nan")
p90 = pctl(steady, 0.90) if steady else float("nan")
print(count, mean, p90)
PY
)"

  rung_pass="$(${PYTHON_BIN} - <<PY
p90 = float("${steady_p90}")
target = float("${TARGET_TPOC_S}")
print(1 if p90 <= target else 0)
PY
)"

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "${rung}" "${devices}" "ok" "${chunk_count}" "${steady_mean}" "${steady_p90}" "${rung_pass}" "${rung_log}" "${rung_timings}" >> "${CALIB_RESULTS_CSV}"

  LAST_TESTED_NPROC="${rung}"
  LAST_TESTED_DEVICES="${devices}"
  if [ -z "${SELECTED_NPROC}" ] && [ "${rung_pass}" = "1" ]; then
    SELECTED_NPROC="${rung}"
    SELECTED_DEVICES="${devices}"
    echo "[info] Selected rung nproc=${SELECTED_NPROC} (steady p90 ${steady_p90}s <= ${TARGET_TPOC_S}s)"
    break
  fi
done

if [ -z "${SELECTED_NPROC}" ]; then
  if [ -n "${LAST_TESTED_NPROC}" ]; then
    SELECTED_NPROC="${LAST_TESTED_NPROC}"
    SELECTED_DEVICES="${LAST_TESTED_DEVICES}"
    echo "[warn] No rung met target TPOC; falling back to highest tested nproc=${SELECTED_NPROC}"
  else
    FINAL_STATUS="FAILED"
    FINAL_MESSAGE="Calibration ladder had no runnable rung for current CUDA_VISIBLE_DEVICES."
    exit 1
  fi
fi

${PYTHON_BIN} - "${CALIB_RESULTS_CSV}" "${CALIB_JSON}" "${SELECTED_NPROC}" "${TARGET_TPOC_S}" <<'PY'
import csv
import json
import sys
from datetime import datetime, timezone

csv_path, out_path, selected_nproc, target_tpoc = sys.argv[1:]
rows = []
with open(csv_path, "r", encoding="utf-8", newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        rows.append(row)

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "target_tpoc_s": float(target_tpoc),
    "selected_nproc": int(selected_nproc),
    "rungs": rows,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY

echo "[info] Starting final 30s scripted run (nproc=${SELECTED_NPROC}, devices=${SELECTED_DEVICES})"
FINAL_STREAM_LOG="${TMP_DIR}/${RUN_ID}_final_stream.log"
start_stream "${SELECTED_NPROC}" "${SELECTED_DEVICES}" "${MAGI_NUM_FRAMES}" "${FINAL_STREAM_LOG}" "${first_prompt}"
wait_for_server "${SERVER_READY_TIMEOUT_S}"

rm -f "${OUTPUT_FILE}"
ffmpeg -hide_banner -loglevel warning -y \
  -framerate 24 \
  -f mjpeg \
  -i "${BASE_URL}/stream" \
  -frames:v "${MAGI_NUM_FRAMES}" \
  -r 24 \
  -c:v libx264 \
  -pix_fmt yuv420p \
  -movflags +faststart \
  "${OUTPUT_FILE}" > "${TMP_DIR}/${RUN_ID}_ffmpeg.log" 2>&1 &
FFMPEG_PID="$!"

set +e
${PYTHON_BIN} "${SCRIPT_DIR}/run_prompt_schedule.py" \
  --url "${BASE_URL}" \
  --schedule-csv "${SCHEDULE_CSV}" \
  --poll "${SCHEDULE_POLL_S}" \
  --timeout "${SCHEDULE_TIMEOUT_S}" \
  --report-json "${REPORT_JSON}" \
  --report-csv "${REPORT_CSV}"
SCHEDULE_RC=$?
set -e
if [ "${SCHEDULE_RC}" -ne 0 ] && [ "${SCHEDULE_RC}" -ne 2 ]; then
  FINAL_STATUS="FAILED"
  FINAL_MESSAGE="run_prompt_schedule.py failed with exit code ${SCHEDULE_RC}."
  exit 1
fi

wait "${FFMPEG_PID}"
FFMPEG_PID=""
stop_stream

if [ -f "${BUDGET_ABORT_FLAG}" ]; then
  FINAL_STATUS="BUDGET_ABORT"
  FINAL_MESSAGE="Budget guard timeout reached during final run."
  exit 124
fi

ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,duration \
  -of json "${OUTPUT_FILE}" > "${FFPROBE_JSON}"

read -r frame_count duration_s <<<"$(${PYTHON_BIN} - "${FFPROBE_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
streams = payload.get("streams", [])
if not streams:
    raise SystemExit(2)
stream = streams[0]
frames = int(stream.get("nb_read_frames") or 0)
duration = float(stream.get("duration") or 0.0)
print(frames, duration)
PY
)"

if [ "${frame_count}" -lt "${MAGI_NUM_FRAMES}" ]; then
  FINAL_STATUS="FAILED"
  FINAL_MESSAGE="Output frame count ${frame_count} is below expected ${MAGI_NUM_FRAMES}."
  exit 1
fi

read -r cue_count applied_within fidelity miss_count <<<"$(${PYTHON_BIN} - "${REPORT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    report = json.load(f)
cues = report.get("cues", [])
cue_count = len(cues)
applied_within = 0
misses = 0
for cue in cues:
    if cue.get("status") != "applied":
        misses += 1
        continue
    try:
        lat_chunks = int(cue.get("latency_chunks"))
    except Exception:
        misses += 1
        continue
    if lat_chunks <= 1:
        applied_within += 1
fidelity = (applied_within / cue_count) if cue_count else 0.0
print(cue_count, applied_within, fidelity, misses)
PY
)"

read -r final_chunk_count steady_chunk_count steady_p90 steady_mean <<<"$(${PYTHON_BIN} - "${FINAL_STREAM_LOG}" <<'PY'
import re
import statistics
import sys

def pctl(xs, p):
    if not xs:
        return float("nan")
    ys = sorted(xs)
    if len(ys) == 1:
        return ys[0]
    k = (len(ys) - 1) * p
    f = int(k)
    c = min(f + 1, len(ys) - 1)
    if f == c:
        return ys[f]
    return ys[f] * (c - k) + ys[c] * (k - f)

times = []
pattern = re.compile(r"total=([0-9.]+)s")
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        m = pattern.search(line)
        if m:
            times.append(float(m.group(1)))
steady = times[1:] if len(times) > 1 else times
mean = statistics.mean(steady) if steady else float("nan")
p90 = pctl(steady, 0.9) if steady else float("nan")
print(len(times), len(steady), p90, mean)
PY
)"

${PYTHON_BIN} - <<PY
import json

payload = {
    "frame_count": int("${frame_count}"),
    "duration_s": float("${duration_s}"),
    "cue_count": int("${cue_count}"),
    "applied_within_1_chunk": int("${applied_within}"),
    "cue_fidelity_ratio": float("${fidelity}"),
    "miss_count": int("${miss_count}"),
    "final_chunk_count": int("${final_chunk_count}"),
    "steady_chunk_count": int("${steady_chunk_count}"),
    "steady_tpoc_p90_s": float("${steady_p90}"),
    "steady_tpoc_mean_s": float("${steady_mean}"),
    "target_tpoc_s": float("${TARGET_TPOC_S}"),
}
with open("${METRICS_JSON}", "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY

fidelity_ok="$(${PYTHON_BIN} - <<PY
print(1 if float("${fidelity}") >= 0.95 else 0)
PY
)"
tpoc_ok="$(${PYTHON_BIN} - <<PY
print(1 if float("${steady_p90}") <= float("${TARGET_TPOC_S}") else 0)
PY
)"

if [ "${fidelity_ok}" != "1" ]; then
  FINAL_STATUS="FAILED"
  FINAL_MESSAGE="Cue fidelity below threshold: ${fidelity} < 0.95."
  exit 1
fi
if [ "${tpoc_ok}" != "1" ]; then
  FINAL_STATUS="FAILED"
  FINAL_MESSAGE="Steady-state p90 TPOC ${steady_p90}s exceeds target ${TARGET_TPOC_S}s."
  exit 1
fi

FINAL_STATUS="OK"
FINAL_MESSAGE="Scripted 30s run completed within fidelity and latency targets."
