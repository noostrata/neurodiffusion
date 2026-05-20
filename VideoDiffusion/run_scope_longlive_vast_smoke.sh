#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUNTIME_TAG="${SCOPE_VAST_RUNTIME_TAG:-scope_auto_py312_torch2.9.1_cu128_sm100}"
RUN_ID="${SCOPE_VAST_RUN_ID:-scope_longlive_vast_smoke_$(date -u +%Y%m%dT%H%M%SZ)}"
REMOTE_ROOT="${SCOPE_VAST_REMOTE_ROOT:-/workspace/neurodiffusion}"
REMOTE_VIDEO_DIR="${REMOTE_ROOT}/VideoDiffusion"
REMOTE_RUN_DIR="${SCOPE_VAST_REMOTE_RUN_DIR:-/workspace/neurodiffusion_runs/${RUN_ID}}"
REMOTE_R2_ENV="${REMOTE_ROOT}/.secrets/r2_full_access.env"
R2_ENV_FILE="${R2_ENV_FILE:-/Users/xenochain/agents/secrets/r2_full_access.env}"
R2_PREFIX="${R2_PREFIX:-neurodiffusion}"
LOCAL_OUT_DIR="${SCOPE_VAST_LOCAL_OUT_DIR:-${HOME}/Downloads/${RUN_ID}}"
FLAT_LOCAL_VIDEO="${SCOPE_VAST_FLAT_LOCAL_VIDEO:-${HOME}/Downloads/${RUN_ID}_webrtc_capture.mp4}"
FLAT_LOCAL_FRAME="${SCOPE_VAST_FLAT_LOCAL_FRAME:-${HOME}/Downloads/${RUN_ID}_frame_000024.png}"

CREATE_INSTANCE="${SCOPE_VAST_CREATE_INSTANCE:-0}"
KEEP_INSTANCE="${SCOPE_VAST_KEEP_INSTANCE:-0}"
DESTROY_ON_EXIT="${SCOPE_VAST_DESTROY_ON_EXIT:-}"
OFFER_ID="${VAST_OFFER_ID:-}"
GPU_REGEX="${SCOPE_VAST_GPU_REGEX:-RTX.?4090|RTX.?5090|L40S}"
MAX_DPH="${SCOPE_VAST_MAX_DPH:-1.50}"
SELECTION_GOAL="${SCOPE_VAST_SELECTION_GOAL:-cost}"
ALLOW_RUNTIME_GPU_MISMATCH="${SCOPE_VAST_ALLOW_RUNTIME_GPU_MISMATCH:-1}"
VAST_DISK_GB="${VAST_DISK_GB:-220}"
VAST_IMAGE="${VAST_IMAGE:-pytorch/pytorch:2.7.1-cuda12.8-cudnn9-devel}"
VAST_ENV="${VAST_ENV:--p 8000:8000 -p 8000:8000/udp}"
VAST_LABEL="${VAST_LABEL:-neurodiffusion_${RUN_ID}}"

SCOPE_PORT="${SCOPE_PORT:-8000}"
SCOPE_HEIGHT="${SCOPE_HEIGHT:-320}"
SCOPE_WIDTH="${SCOPE_WIDTH:-576}"
SCOPE_VACE_ENABLED="${SCOPE_VACE_ENABLED:-false}"
SCOPE_WAIT_TIMEOUT_S="${SCOPE_WAIT_TIMEOUT_S:-300}"
BENCHMARK_DURATION_S="${SCOPE_VAST_BENCHMARK_DURATION_S:-30}"
EEG_DURATION_S="${SCOPE_VAST_EEG_DURATION_S:-${BENCHMARK_DURATION_S}}"
MIN_FPS="${SCOPE_VAST_MIN_FPS:-24.0}"
MAX_FIRST_FRAME_LATENCY_S="${SCOPE_VAST_MAX_FIRST_FRAME_LATENCY_S:-2.0}"
PROMPT="${SCOPE_VAST_PROMPT:-A luminous red and blue neon tunnel breathing through crystalline hexagonal geometry, smooth camera drift, reactive abstract light.}"
RESTORE_TUPLE="${SCOPE_VAST_RESTORE_TUPLE:-1}"
DOWNLOAD_FALLBACK="${SCOPE_VAST_DOWNLOAD_FALLBACK:-0}"
SSH_READY_TIMEOUT_S="${SCOPE_VAST_SSH_READY_TIMEOUT_S:-240}"
SERVER_READY_TIMEOUT_S="${SCOPE_VAST_SERVER_READY_TIMEOUT_S:-180}"

SSH_KEY_PATH="${VAST_SSH_KEY_PATH:-${HOME}/.ssh/vast_neurodiffusion_rsa}"

usage() {
  cat <<EOF
Usage:
  bash VideoDiffusion/run_scope_longlive_vast_smoke.sh [options]

Safe default: requires VAST_INSTANCE_ID. To create a paid Vast instance, pass --create-instance.

Options:
  --create-instance             Query/select/provision a Vast instance before running
  --keep-instance               Do not destroy the instance on exit
  --instance-id <id>            Use an existing Vast instance
  --offer-id <id>               Use an explicit Vast offer id when creating
  --gpu-regex <regex>           Cheap-GPU filter for offer query (default: ${GPU_REGEX})
  --max-dph <usd>               Max selected hourly rate (default: ${MAX_DPH})
  --runtime-tag <tag>           R2 Scope runtime tuple (default: ${RUNTIME_TAG})
  --duration-s <seconds>        WebRTC benchmark duration (default: ${BENCHMARK_DURATION_S})
  --height <pixels>             LongLive output height, divisible by 16 (default: ${SCOPE_HEIGHT})
  --width <pixels>              LongLive output width, divisible by 16 (default: ${SCOPE_WIDTH})
  --local-out-dir <path>        Local artifact directory (default: ${LOCAL_OUT_DIR})
  --no-restore                  Skip R2 tuple restore and run setup/download path
  --download-fallback           If restore fails, download LongLive models from HF
  --min-fps <fps>               Acceptance FPS threshold (default: ${MIN_FPS})
  --max-first-frame-s <seconds> Acceptance first-frame threshold (default: ${MAX_FIRST_FRAME_LATENCY_S})

Environment:
  R2_ENV_FILE                   Local R2 env file copied temporarily to instance
  VAST_SSH_KEY_PATH             Vast SSH private key path
  SCOPE_VAST_ALLOW_RUNTIME_GPU_MISMATCH=1
                                Allow using the B200-published Scope tuple on cheaper GPUs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-instance)
      CREATE_INSTANCE="1"
      shift
      ;;
    --keep-instance)
      KEEP_INSTANCE="1"
      shift
      ;;
    --instance-id)
      VAST_INSTANCE_ID="$2"
      shift 2
      ;;
    --offer-id)
      OFFER_ID="$2"
      shift 2
      ;;
    --gpu-regex)
      GPU_REGEX="$2"
      shift 2
      ;;
    --max-dph)
      MAX_DPH="$2"
      shift 2
      ;;
    --runtime-tag)
      RUNTIME_TAG="$2"
      shift 2
      ;;
    --duration-s)
      BENCHMARK_DURATION_S="$2"
      EEG_DURATION_S="$2"
      shift 2
      ;;
    --height)
      SCOPE_HEIGHT="$2"
      shift 2
      ;;
    --width)
      SCOPE_WIDTH="$2"
      shift 2
      ;;
    --local-out-dir)
      LOCAL_OUT_DIR="$2"
      shift 2
      ;;
    --no-restore)
      RESTORE_TUPLE="0"
      shift
      ;;
    --download-fallback)
      DOWNLOAD_FALLBACK="1"
      shift
      ;;
    --min-fps)
      MIN_FPS="$2"
      shift 2
      ;;
    --max-first-frame-s)
      MAX_FIRST_FRAME_LATENCY_S="$2"
      shift 2
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

q() {
  printf "%q" "$1"
}

mark_phase() {
  local phase="$1"
  printf '[scope-vast-ts] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${phase}"
}

remote_ssh() {
  ssh -i "${SSH_KEY_PATH}" \
    -p "${VAST_SSH_PORT}" \
    -o BatchMode=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=6 \
    -o StrictHostKeyChecking=accept-new \
    "${VAST_SSH_USER}@${VAST_SSH_HOST}" "$@"
}

remote_scp_dir_from() {
  mkdir -p "$2"
  scp -i "${SSH_KEY_PATH}" \
    -P "${VAST_SSH_PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -r "${VAST_SSH_USER}@${VAST_SSH_HOST}:$1/." "$2/"
}

cleanup_remote_secret() {
  if [[ -n "${VAST_SSH_HOST:-}" ]]; then
    remote_ssh "rm -f $(q "${REMOTE_R2_ENV}"); rmdir $(q "${REMOTE_ROOT}/.secrets") 2>/dev/null || true" >/dev/null 2>&1 || true
  fi
}

cleanup_remote_processes() {
  if [[ -n "${VAST_SSH_HOST:-}" ]]; then
    remote_ssh "set +e; for f in $(q "${REMOTE_RUN_DIR}")/*.pid; do [[ -f \"\$f\" ]] && kill \"\$(cat \"\$f\")\" 2>/dev/null || true; done" >/dev/null 2>&1 || true
  fi
}

destroy_instance_if_needed() {
  local should_destroy="${DESTROY_ON_EXIT:-0}"
  if [[ "${KEEP_INSTANCE}" == "1" ]]; then
    should_destroy="0"
  elif [[ -z "${DESTROY_ON_EXIT}" && "${INSTANCE_CREATED:-0}" == "1" ]]; then
    should_destroy="1"
  fi
  if [[ "${should_destroy}" == "1" && -n "${VAST_INSTANCE_ID:-}" ]]; then
    VAST_INSTANCE_ID="${VAST_INSTANCE_ID}" bash "${REPO_ROOT}/scripts/vast/terminate_instance.sh" || true
  fi
}

finish() {
  local rc=$?
  trap - EXIT INT TERM
  cleanup_remote_secret
  cleanup_remote_processes
  destroy_instance_if_needed
  exit "${rc}"
}
trap finish EXIT INT TERM

wait_for_ssh_auth() {
  local deadline=$((SECONDS + SSH_READY_TIMEOUT_S))
  local last_rc=0
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if remote_ssh "true" >/dev/null 2>&1; then
      return 0
    fi
    last_rc=$?
    echo "[scope-vast] waiting for SSH auth (last_rc=${last_rc})" >&2
    sleep 5
  done
  echo "[error] SSH auth did not become ready within ${SSH_READY_TIMEOUT_S}s." >&2
  return "${last_rc}"
}

select_offer_if_needed() {
  if [[ -n "${OFFER_ID}" ]]; then
    return
  fi
  mkdir -p "${SCRIPT_DIR}/.tmp"
  local scan_json="${SCRIPT_DIR}/.tmp/${RUN_ID}_scope_offer_scan.json"
  local scan_csv="${SCRIPT_DIR}/.tmp/${RUN_ID}_scope_offer_scan.csv"
  local selected_json="${SCRIPT_DIR}/.tmp/${RUN_ID}_scope_offer_selected.json"
  echo "[scope-vast] querying offers gpu_regex=${GPU_REGEX} max_dph=${MAX_DPH}"
  python3 "${REPO_ROOT}/scripts/vast/query_video_offers.py" \
    --model scope \
    --gpu-name-regex "${GPU_REGEX}" \
    --out-json "${scan_json}" \
    --out-csv "${scan_csv}"
  select_args=(
    --scan-json "${scan_json}"
    --selection-goal "${SELECTION_GOAL}"
    --runtime-tag "${RUNTIME_TAG}"
    --out-json "${selected_json}"
  )
  if [[ -n "${MAX_DPH}" ]]; then
    select_args+=(--max-dph "${MAX_DPH}")
  fi
  if [[ "${ALLOW_RUNTIME_GPU_MISMATCH}" == "1" ]]; then
    select_args+=(--allow-runtime-gpu-mismatch)
  fi
  python3 "${REPO_ROOT}/scripts/vast/select_video_offer.py" "${select_args[@]}"
  OFFER_ID="$(python3 - "${selected_json}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["selected_offer"]["offer_id"])
PY
)"
  echo "[scope-vast] selected offer=${OFFER_ID}"
}

create_instance_if_requested() {
  INSTANCE_CREATED="0"
  if [[ "${CREATE_INSTANCE}" != "1" ]]; then
    : "${VAST_INSTANCE_ID:?Set VAST_INSTANCE_ID or pass --create-instance.}"
    return
  fi
  select_offer_if_needed
  mkdir -p "${SCRIPT_DIR}/.tmp"
  local provision_log="${SCRIPT_DIR}/.tmp/${RUN_ID}_provision.log"
  echo "[scope-vast] creating paid Vast instance offer=${OFFER_ID} label=${VAST_LABEL}"
  set +e
  VAST_OFFER_ID="${OFFER_ID}" \
  VAST_LABEL="${VAST_LABEL}" \
  VAST_DISK_GB="${VAST_DISK_GB}" \
  VAST_IMAGE="${VAST_IMAGE}" \
  VAST_ENV="${VAST_ENV}" \
    bash "${REPO_ROOT}/scripts/vast/provision_video_instance.sh" >"${provision_log}" 2>&1
  local rc=$?
  set -e
  sed -n '1,120p' "${provision_log}"
  if [[ "${rc}" -ne 0 ]]; then
    echo "[error] provision failed; log=${provision_log}" >&2
    exit "${rc}"
  fi
  VAST_INSTANCE_ID="$(awk -F= '/^VAST_INSTANCE_ID=/{print $2}' "${provision_log}" | tail -n1)"
  if [[ -z "${VAST_INSTANCE_ID}" ]]; then
    echo "[error] could not parse VAST_INSTANCE_ID from ${provision_log}" >&2
    exit 1
  fi
  INSTANCE_CREATED="1"
}

ensure_remote_system_deps() {
  remote_ssh "set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
need_apt=0
for cmd in git curl ffmpeg python3 rsync zstd; do
  if ! command -v \"\${cmd}\" >/dev/null 2>&1; then need_apt=1; fi
done
if [[ \"\${need_apt}\" == \"1\" ]]; then
  for _ in \$(seq 1 90); do
    if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x dpkg >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends git curl ca-certificates rsync ffmpeg python3-venv python3-pip zstd >/dev/null
fi
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
  if [[ -x /root/.local/bin/uv ]]; then
    ln -sf /root/.local/bin/uv /usr/local/bin/uv
  fi
fi
command -v uv >/dev/null
echo '[scope-vast] remote system deps ready'
"
}

sync_repo_to_remote() {
  echo "[scope-vast] syncing repo to ${REMOTE_ROOT}"
  remote_ssh "mkdir -p $(q "${REMOTE_ROOT}") $(q "${REMOTE_ROOT}/.secrets") $(q "${REMOTE_RUN_DIR}")"
  rsync -az \
    --exclude '.git' \
    --exclude 'VideoDiffusion/MAGI-1' \
    --exclude 'VideoDiffusion/.venv' \
    --exclude 'VideoDiffusion/.venv-krea' \
    --exclude 'VideoDiffusion/.vendors' \
    --exclude 'VideoDiffusion/.cache' \
    --exclude 'VideoDiffusion/.tmp' \
    --exclude 'VideoDiffusion/*.mp4' \
    --exclude 'ImageDiffusion/.venv' \
    --exclude '__pycache__' \
    -e "ssh -i ${SSH_KEY_PATH} -p ${VAST_SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
    "${REPO_ROOT}/" "${VAST_SSH_USER}@${VAST_SSH_HOST}:${REMOTE_ROOT}/"
}

copy_r2_secret() {
  if [[ ! -f "${R2_ENV_FILE}" ]]; then
    echo "[error] R2 env file not found: ${R2_ENV_FILE}" >&2
    exit 1
  fi
  scp -i "${SSH_KEY_PATH}" \
    -P "${VAST_SSH_PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    "${R2_ENV_FILE}" "${VAST_SSH_USER}@${VAST_SSH_HOST}:${REMOTE_R2_ENV}"
  remote_ssh "chmod 600 $(q "${REMOTE_R2_ENV}")"
}

remote_setup_scope() {
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); SCOPE_SKIP_BUILD=1 bash VideoDiffusion/setup_scope.sh 2>&1 | tee $(q "${REMOTE_RUN_DIR}/setup_scope.log")"
}

remote_restore_or_download() {
  if [[ "${RESTORE_TUPLE}" == "1" ]]; then
    echo "[scope-vast] restoring R2 tuple ${RUNTIME_TAG}"
    set +e
    remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); R2_ENV_FILE=$(q "${REMOTE_R2_ENV}") R2_PREFIX=$(q "${R2_PREFIX}") bash VideoDiffusion/restore_r2_prebuild_model.sh --model scope --mode tuple --runtime-tag $(q "${RUNTIME_TAG}") --apply-weights-target $(q "${REMOTE_VIDEO_DIR}/.cache/daydream-scope") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/restore_scope_tuple.log")"
    local rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      return
    fi
    if [[ "${DOWNLOAD_FALLBACK}" != "1" ]]; then
      echo "[error] R2 tuple restore failed and download fallback is disabled." >&2
      exit "${rc}"
    fi
    echo "[scope-vast] restore failed; falling back to deterministic model download"
  fi
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/download_scope_models.sh 2>&1 | tee $(q "${REMOTE_RUN_DIR}/download_scope_models.log")"
}

start_scope_server() {
  echo "[scope-vast] starting Scope server"
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); rm -f $(q "${REMOTE_RUN_DIR}/scope_server.pid"); SCOPE_AUTO_LOAD=0 SCOPE_PORT=$(q "${SCOPE_PORT}") nohup bash VideoDiffusion/run_scope_server.sh --host 0.0.0.0 --port $(q "${SCOPE_PORT}") -N > $(q "${REMOTE_RUN_DIR}/scope_server.log") 2>&1 < /dev/null & echo \$! > $(q "${REMOTE_RUN_DIR}/scope_server.pid")"
}

wait_for_scope_server() {
  local deadline=$((SECONDS + SERVER_READY_TIMEOUT_S))
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if remote_ssh "python3 -c $(q "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${SCOPE_PORT}/api/v1/pipeline/status', timeout=2).read()")" >/dev/null 2>&1; then
      echo "[scope-vast] Scope server ready"
      return 0
    fi
    remote_ssh "tail -20 $(q "${REMOTE_RUN_DIR}/scope_server.log") 2>/dev/null || true" || true
    sleep 5
  done
  echo "[error] Scope server did not become ready within ${SERVER_READY_TIMEOUT_S}s." >&2
  return 1
}

load_longlive() {
  echo "[scope-vast] loading LongLive"
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); SCOPE_PORT=$(q "${SCOPE_PORT}") SCOPE_HEIGHT=$(q "${SCOPE_HEIGHT}") SCOPE_WIDTH=$(q "${SCOPE_WIDTH}") SCOPE_VACE_ENABLED=$(q "${SCOPE_VACE_ENABLED}") SCOPE_WAIT_TIMEOUT_S=$(q "${SCOPE_WAIT_TIMEOUT_S}") bash VideoDiffusion/load_scope_longlive.sh 2>&1 | tee $(q "${REMOTE_RUN_DIR}/load_longlive.log")"
}

run_webrtc_and_eeg() {
  echo "[scope-vast] running WebRTC capture and synthetic EEG"
  local scope_py="${REMOTE_VIDEO_DIR}/.vendors/daydream-scope/.venv/bin/python"
  local remote_video="${REMOTE_RUN_DIR}/webrtc_capture.mp4"
  local remote_benchmark_json="${REMOTE_RUN_DIR}/webrtc_benchmark.json"
  local remote_frames="${REMOTE_RUN_DIR}/frames"
  local remote_eeg_jsonl="${REMOTE_RUN_DIR}/synthetic_eeg.jsonl"
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); mkdir -p $(q "${remote_frames}");
set +e
$(q "${scope_py}") VideoDiffusion/scope_webrtc_benchmark.py \
  --base-url http://127.0.0.1:$(q "${SCOPE_PORT}") \
  --pipeline-id longlive \
  --duration-s $(q "${BENCHMARK_DURATION_S}") \
  --prompt $(q "${PROMPT}") \
  --output-json $(q "${remote_benchmark_json}") \
  --output-video $(q "${remote_video}") \
  --frames-dir $(q "${remote_frames}") \
  --save-every-n-frames 24 \
  --max-saved-frames 16 \
  > $(q "${REMOTE_RUN_DIR}/webrtc_benchmark.stdout.log") 2> $(q "${REMOTE_RUN_DIR}/webrtc_benchmark.stderr.log") &
bench_pid=\$!
echo \${bench_pid} > $(q "${REMOTE_RUN_DIR}/webrtc_benchmark.pid")
sleep 2
$(q "${scope_py}") VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board mock \
  --mock-scenario alternating \
  --policy balancer \
  --sink stdout \
  --sink scope \
  --sink jsonl \
  --scope-osc-host 127.0.0.1 \
  --scope-osc-port $(q "${SCOPE_PORT}") \
  --scope-transition-steps 6 \
  --duration-s $(q "${EEG_DURATION_S}") \
  --log-jsonl $(q "${remote_eeg_jsonl}") \
  > $(q "${REMOTE_RUN_DIR}/synthetic_eeg.stdout.log") 2> $(q "${REMOTE_RUN_DIR}/synthetic_eeg.stderr.log")
eeg_rc=\$?
wait \${bench_pid}
bench_rc=\$?
echo \${eeg_rc} > $(q "${REMOTE_RUN_DIR}/synthetic_eeg.rc")
echo \${bench_rc} > $(q "${REMOTE_RUN_DIR}/webrtc_benchmark.rc")
exit 0"
}

write_local_report() {
  local report_path="${LOCAL_OUT_DIR}/run_report.json"
  python3 - "${report_path}" "${RUN_ID}" "${VAST_INSTANCE_ID:-}" "${RUNTIME_TAG}" "${LOCAL_OUT_DIR}" "${MIN_FPS}" "${MAX_FIRST_FRAME_LATENCY_S}" "${FLAT_LOCAL_VIDEO}" "${SCOPE_HEIGHT}" "${SCOPE_WIDTH}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
run_id, instance_id, runtime_tag = sys.argv[2:5]
local_dir = Path(sys.argv[5])
min_fps = float(sys.argv[6])
max_first = float(sys.argv[7])
flat_video = Path(sys.argv[8])
height = int(float(sys.argv[9]))
width = int(float(sys.argv[10]))

benchmark_path = local_dir / "webrtc_benchmark.json"
eeg_path = local_dir / "synthetic_eeg.jsonl"
benchmark_rc_path = local_dir / "webrtc_benchmark.rc"
eeg_rc_path = local_dir / "synthetic_eeg.rc"
benchmark = {}
if benchmark_path.is_file():
    benchmark = json.loads(benchmark_path.read_text(encoding="utf-8"))

eeg_records = []
if eeg_path.is_file():
    for line in eeg_path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                eeg_records.append(json.loads(line))
            except json.JSONDecodeError:
                pass
emit_count = sum(1 for row in eeg_records if row.get("emit"))
scope_emit_count = sum(1 for row in eeg_records if row.get("scope_osc_sent"))

def read_rc(path: Path):
    if not path.is_file():
        return None
    raw = path.read_text(encoding="utf-8").strip()
    try:
        return int(raw)
    except ValueError:
        return raw

benchmark_rc = read_rc(benchmark_rc_path)
eeg_rc = read_rc(eeg_rc_path)

video_path = local_dir / "webrtc_capture.mp4"
ffprobe = {}
if video_path.is_file():
    try:
        out = subprocess.check_output(
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
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        ffprobe = json.loads(out)
    except Exception as exc:
        ffprobe = {"error": str(exc)}

fps = float(benchmark.get("fps") or 0.0)
first = benchmark.get("first_frame_latency_s")
first_value = float(first) if first is not None else None
acceptance = {
    "min_fps": min_fps,
    "max_first_frame_latency_s": max_first,
    "fps_ok": fps >= min_fps,
    "first_frame_latency_ok": first_value is not None and first_value <= max_first,
    "frames_received_ok": int(benchmark.get("frame_count") or 0) > 0,
    "synthetic_eeg_scope_updates_ok": scope_emit_count > 0 or (scope_emit_count == 0 and emit_count > 0 and eeg_rc == 0),
    "local_video_ok": video_path.is_file() and video_path.stat().st_size > 0,
}
acceptance["passed"] = all(acceptance[k] for k in (
    "fps_ok",
    "first_frame_latency_ok",
    "frames_received_ok",
    "synthetic_eeg_scope_updates_ok",
    "local_video_ok",
))

payload = {
    "run_id": run_id,
    "vast_instance_id": instance_id,
    "runtime_tag": runtime_tag,
    "profile": {
        "height": height,
        "width": width,
    },
    "local_dir": str(local_dir),
    "flat_local_video": str(flat_video) if flat_video.is_file() else "",
    "benchmark": benchmark,
    "eeg": {
        "record_count": len(eeg_records),
        "emit_count": emit_count,
        "scope_emit_count": scope_emit_count,
        "scope_emit_count_fallback_used": scope_emit_count == 0 and emit_count > 0 and eeg_rc == 0,
    },
    "process_rc": {
        "webrtc_benchmark": benchmark_rc,
        "synthetic_eeg": eeg_rc,
    },
    "ffprobe": ffprobe,
    "acceptance": acceptance,
}
report_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload["acceptance"], indent=2, sort_keys=True))
raise SystemExit(0 if acceptance["passed"] else 2)
PY
}

pull_artifacts() {
  echo "[scope-vast] pulling artifacts to ${LOCAL_OUT_DIR}"
  mkdir -p "${LOCAL_OUT_DIR}"
  remote_scp_dir_from "${REMOTE_RUN_DIR}" "${LOCAL_OUT_DIR}"
  if [[ -f "${LOCAL_OUT_DIR}/webrtc_capture.mp4" ]]; then
    cp -f "${LOCAL_OUT_DIR}/webrtc_capture.mp4" "${FLAT_LOCAL_VIDEO}"
  fi
  if [[ -f "${LOCAL_OUT_DIR}/frames/frame_000024.png" ]]; then
    cp -f "${LOCAL_OUT_DIR}/frames/frame_000024.png" "${FLAT_LOCAL_FRAME}"
  fi
}

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  echo "[error] Vast SSH key not found: ${SSH_KEY_PATH}" >&2
  exit 1
fi

cd "${REPO_ROOT}"
mark_phase "create_instance_start"
create_instance_if_requested
mark_phase "create_instance_done"

mark_phase "resolve_ssh_start"
eval "$(VAST_INSTANCE_ID="${VAST_INSTANCE_ID}" bash scripts/vast/resolve_ssh.sh)"
mark_phase "resolve_ssh_done"
mark_phase "ssh_ready_wait_start"
wait_for_ssh_auth
mark_phase "ssh_ready_wait_done"

remote_gpu="$(remote_ssh "nvidia-smi --query-gpu=name --format=csv,noheader | head -n1" | tr -d '\r')"
echo "[scope-vast] run_id=${RUN_ID}"
echo "[scope-vast] instance=${VAST_INSTANCE_ID} gpu=${remote_gpu}"
echo "[scope-vast] runtime_tag=${RUNTIME_TAG}"

mark_phase "remote_system_deps_start"
ensure_remote_system_deps
mark_phase "remote_system_deps_done"
mark_phase "repo_sync_start"
sync_repo_to_remote
mark_phase "repo_sync_done"
if [[ "${RESTORE_TUPLE}" == "1" ]]; then
  mark_phase "copy_r2_secret_start"
  copy_r2_secret
  mark_phase "copy_r2_secret_done"
fi
mark_phase "setup_scope_start"
remote_setup_scope
mark_phase "setup_scope_done"
mark_phase "restore_or_download_start"
remote_restore_or_download
mark_phase "restore_or_download_done"
mark_phase "scope_server_start"
start_scope_server
mark_phase "scope_server_started"
mark_phase "scope_server_wait_start"
wait_for_scope_server
mark_phase "scope_server_wait_done"
mark_phase "longlive_load_start"
load_longlive
mark_phase "longlive_load_done"
mark_phase "webrtc_eeg_start"
run_webrtc_and_eeg
mark_phase "webrtc_eeg_done"
mark_phase "artifact_pull_start"
pull_artifacts
mark_phase "artifact_pull_done"
mark_phase "local_report_start"
write_local_report
mark_phase "local_report_done"
echo "[scope-vast] local_dir=${LOCAL_OUT_DIR}"
echo "[scope-vast] local_video=${FLAT_LOCAL_VIDEO}"
