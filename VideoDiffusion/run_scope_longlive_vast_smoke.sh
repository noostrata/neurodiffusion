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
ARTIFACTS_ROOT="${NEURODIFFUSION_ARTIFACTS_ROOT:-${REPO_ROOT}/artifacts}"
LOCAL_MEDIA_DIR="${SCOPE_VAST_LOCAL_MEDIA_DIR:-${ARTIFACTS_ROOT}/media/scope-longlive/${RUN_ID}}"
LOCAL_OUT_DIR="${SCOPE_VAST_LOCAL_OUT_DIR:-${ARTIFACTS_ROOT}/runs/scope-longlive/${RUN_ID}}"
FLAT_LOCAL_VIDEO="${SCOPE_VAST_FLAT_LOCAL_VIDEO:-${LOCAL_MEDIA_DIR}/${RUN_ID}_webrtc_capture.mp4}"
FLAT_LOCAL_FRAME="${SCOPE_VAST_FLAT_LOCAL_FRAME:-${LOCAL_MEDIA_DIR}/${RUN_ID}_frame_000024.png}"
PHASE_LOG="${SCOPE_VAST_PHASE_LOG:-${LOCAL_OUT_DIR}/phase_markers.log}"
SWEEP_RESOLUTIONS="${SCOPE_VAST_SWEEP_RESOLUTIONS:-}"

CREATE_INSTANCE="${SCOPE_VAST_CREATE_INSTANCE:-0}"
KEEP_INSTANCE="${SCOPE_VAST_KEEP_INSTANCE:-0}"
DESTROY_ON_EXIT="${SCOPE_VAST_DESTROY_ON_EXIT:-}"
OFFER_ID="${VAST_OFFER_ID:-}"
GPU_REGEX="${SCOPE_VAST_GPU_REGEX:-RTX.?4090|RTX.?5090|L40S}"
MAX_DPH="${SCOPE_VAST_MAX_DPH:-1.50}"
MAX_GPU_COUNT="${SCOPE_VAST_MAX_GPU_COUNT:-1}"
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
  --max-gpu-count <count>       Max GPUs in selected offer; 0 disables limit (default: ${MAX_GPU_COUNT})
  --runtime-tag <tag>           R2 Scope runtime tuple (default: ${RUNTIME_TAG})
  --duration-s <seconds>        WebRTC benchmark duration (default: ${BENCHMARK_DURATION_S})
  --height <pixels>             LongLive output height, divisible by 16 (default: ${SCOPE_HEIGHT})
  --width <pixels>              LongLive output width, divisible by 16 (default: ${SCOPE_WIDTH})
  --resolutions <HxW,...>       Same-instance resolution sweep; creates per-resolution reports
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
    --max-gpu-count)
      MAX_GPU_COUNT="$2"
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
      PHASE_LOG="${SCOPE_VAST_PHASE_LOG:-$2/phase_markers.log}"
      shift 2
      ;;
    --resolutions)
      SWEEP_RESOLUTIONS="$2"
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
  local line
  line="$(printf '[scope-vast-ts] %s %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${phase}")"
  printf '%s\n' "${line}"
  mkdir -p "$(dirname -- "${PHASE_LOG}")"
  printf '%s\n' "${line}" >>"${PHASE_LOG}"
}

validate_resolution() {
  local raw="$1"
  if [[ ! "${raw}" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "[error] invalid resolution '${raw}', expected HxW" >&2
    exit 1
  fi
  local height="${raw%x*}"
  local width="${raw#*x}"
  if (( height <= 0 || width <= 0 || height % 16 != 0 || width % 16 != 0 )); then
    echo "[error] invalid resolution '${raw}', dimensions must be positive and divisible by 16" >&2
    exit 1
  fi
}

sweep_resolution_list() {
  if [[ -n "${SWEEP_RESOLUTIONS}" ]]; then
    local -a raw
    IFS=',' read -r -a raw <<<"${SWEEP_RESOLUTIONS}"
    for item in "${raw[@]}"; do
      item="${item//[[:space:]]/}"
      [[ -z "${item}" ]] && continue
      validate_resolution "${item}"
      printf '%s\n' "${item}"
    done
  else
    validate_resolution "${SCOPE_HEIGHT}x${SCOPE_WIDTH}"
    printf '%sx%s\n' "${SCOPE_HEIGHT}" "${SCOPE_WIDTH}"
  fi
}

is_sweep_mode() {
  [[ -n "${SWEEP_RESOLUTIONS}" ]]
}

flat_video_for_label() {
  local label="$1"
  if is_sweep_mode; then
    printf '%s/%s_%s_webrtc_capture.mp4\n' "${LOCAL_MEDIA_DIR}" "${RUN_ID}" "${label}"
  else
    printf '%s\n' "${FLAT_LOCAL_VIDEO}"
  fi
}

flat_frame_for_label() {
  local label="$1"
  if is_sweep_mode; then
    printf '%s/%s_%s_frame_000024.png\n' "${LOCAL_MEDIA_DIR}" "${RUN_ID}" "${label}"
  else
    printf '%s\n' "${FLAT_LOCAL_FRAME}"
  fi
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
    remote_ssh "set +e; find $(q "${REMOTE_RUN_DIR}") -type f -name '*.pid' 2>/dev/null | while IFS= read -r f; do [[ -f \"\$f\" ]] && kill \"\$(cat \"\$f\")\" 2>/dev/null || true; done" >/dev/null 2>&1 || true
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
  if [[ -n "${MAX_GPU_COUNT}" ]]; then
    select_args+=(--max-gpu-count "${MAX_GPU_COUNT}")
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
  local log_path="${1:-${REMOTE_RUN_DIR}/load_longlive.log}"
  echo "[scope-vast] loading LongLive"
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); SCOPE_PORT=$(q "${SCOPE_PORT}") SCOPE_HEIGHT=$(q "${SCOPE_HEIGHT}") SCOPE_WIDTH=$(q "${SCOPE_WIDTH}") SCOPE_VACE_ENABLED=$(q "${SCOPE_VACE_ENABLED}") SCOPE_WAIT_TIMEOUT_S=$(q "${SCOPE_WAIT_TIMEOUT_S}") bash VideoDiffusion/load_scope_longlive.sh 2>&1 | tee $(q "${log_path}")"
}

run_webrtc_and_eeg() {
  local active_remote_dir="${1:-${REMOTE_RUN_DIR}}"
  echo "[scope-vast] running WebRTC capture and synthetic EEG"
  local scope_py="${REMOTE_VIDEO_DIR}/.vendors/daydream-scope/.venv/bin/python"
  local remote_video="${active_remote_dir}/webrtc_capture.mp4"
  local remote_benchmark_json="${active_remote_dir}/webrtc_benchmark.json"
  local remote_frames="${active_remote_dir}/frames"
  local remote_eeg_jsonl="${active_remote_dir}/synthetic_eeg.jsonl"
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
	  > $(q "${active_remote_dir}/webrtc_benchmark.stdout.log") 2> $(q "${active_remote_dir}/webrtc_benchmark.stderr.log") &
bench_pid=\$!
echo \${bench_pid} > $(q "${active_remote_dir}/webrtc_benchmark.pid")
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
	  > $(q "${active_remote_dir}/synthetic_eeg.stdout.log") 2> $(q "${active_remote_dir}/synthetic_eeg.stderr.log")
eeg_rc=\$?
wait \${bench_pid}
bench_rc=\$?
echo \${eeg_rc} > $(q "${active_remote_dir}/synthetic_eeg.rc")
echo \${bench_rc} > $(q "${active_remote_dir}/webrtc_benchmark.rc")
exit 0"
}

write_local_report() {
  local report_path="$1"
  local report_run_id="$2"
  local report_local_dir="$3"
  local report_flat_video="$4"
  local report_height="$5"
  local report_width="$6"
  python3 "${SCRIPT_DIR}/scope_run_report.py" run \
    --report-path "${report_path}" \
    --run-id "${report_run_id}" \
    --instance-id "${VAST_INSTANCE_ID:-}" \
    --runtime-tag "${RUNTIME_TAG}" \
    --local-dir "${report_local_dir}" \
    --flat-video "${report_flat_video}" \
    --height "${report_height}" \
    --width "${report_width}" \
    --min-fps "${MIN_FPS}" \
    --max-first-frame-s "${MAX_FIRST_FRAME_LATENCY_S}" \
    --phase-log "${PHASE_LOG}" \
    --phase-report-path "${LOCAL_OUT_DIR}/phase_report.json" \
    --artifact-qa-path "${report_local_dir}/artifact_qa.json" \
    --contact-sheet-path "${report_local_dir}/contact_sheet.jpg"
}

pull_artifacts() {
  echo "[scope-vast] pulling artifacts to ${LOCAL_OUT_DIR}"
  mkdir -p "${LOCAL_OUT_DIR}"
  remote_scp_dir_from "${REMOTE_RUN_DIR}" "${LOCAL_OUT_DIR}"
}

copy_flat_artifacts() {
  local local_dir="$1"
  local flat_video="$2"
  local flat_frame="$3"
  mkdir -p "$(dirname -- "${flat_video}")" "$(dirname -- "${flat_frame}")"
  if [[ -f "${local_dir}/webrtc_capture.mp4" ]]; then
    cp -f "${local_dir}/webrtc_capture.mp4" "${flat_video}"
  fi
  if [[ -f "${local_dir}/frames/frame_000024.png" ]]; then
    cp -f "${local_dir}/frames/frame_000024.png" "${flat_frame}"
  fi
}

write_sweep_report() {
  local manifest_path="$1"
  set +e
  python3 "${SCRIPT_DIR}/scope_run_report.py" sweep \
    --report-path "${LOCAL_OUT_DIR}/sweep_report.json" \
    --markdown-path "${LOCAL_OUT_DIR}/sweep_report.md" \
    --manifest-tsv "${manifest_path}" \
    --run-id "${RUN_ID}" \
    --instance-id "${VAST_INSTANCE_ID:-}" \
    --runtime-tag "${RUNTIME_TAG}" \
    --local-root "${LOCAL_OUT_DIR}" \
    --phase-report-path "${LOCAL_OUT_DIR}/phase_report.json"
  local rc=$?
  set -e
  return "${rc}"
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

RESOLUTION_ITEMS=()
while IFS= read -r item; do
  RESOLUTION_ITEMS+=("${item}")
done < <(sweep_resolution_list)
if [[ "${#RESOLUTION_ITEMS[@]}" -eq 0 ]]; then
  echo "[error] no valid resolutions selected" >&2
  exit 1
fi

SWEEP_MANIFEST_REMOTE="${REMOTE_RUN_DIR}/sweep_manifest.tsv"
remote_ssh "printf 'label\theight\twidth\tlocal_dir\tflat_video\tflat_frame\treport_path\n' > $(q "${SWEEP_MANIFEST_REMOTE}")"
for resolution in "${RESOLUTION_ITEMS[@]}"; do
  SCOPE_HEIGHT="${resolution%x*}"
  SCOPE_WIDTH="${resolution#*x}"
  resolution_label="${SCOPE_HEIGHT}x${SCOPE_WIDTH}"
  if is_sweep_mode; then
    active_remote_dir="${REMOTE_RUN_DIR}/runs/${resolution_label}"
    active_local_dir="${LOCAL_OUT_DIR}/runs/${resolution_label}"
  else
    active_remote_dir="${REMOTE_RUN_DIR}"
    active_local_dir="${LOCAL_OUT_DIR}"
  fi
  active_flat_video="$(flat_video_for_label "${resolution_label}")"
  active_flat_frame="$(flat_frame_for_label "${resolution_label}")"
  active_report_path="${active_local_dir}/run_report.json"

  mark_phase "resolution_${resolution_label}_start"
  remote_ssh "mkdir -p $(q "${active_remote_dir}")"
  mark_phase "longlive_load_${resolution_label}_start"
  load_longlive "${active_remote_dir}/load_longlive.log"
  mark_phase "longlive_load_${resolution_label}_done"
  mark_phase "webrtc_eeg_${resolution_label}_start"
  run_webrtc_and_eeg "${active_remote_dir}"
  mark_phase "webrtc_eeg_${resolution_label}_done"
  mark_phase "resolution_${resolution_label}_done"

  remote_ssh "printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    $(q "${resolution_label}") \
    $(q "${SCOPE_HEIGHT}") \
    $(q "${SCOPE_WIDTH}") \
    $(q "${active_local_dir}") \
    $(q "${active_flat_video}") \
    $(q "${active_flat_frame}") \
    $(q "${active_report_path}") >> $(q "${SWEEP_MANIFEST_REMOTE}")"
done

mark_phase "artifact_pull_start"
pull_artifacts
mark_phase "artifact_pull_done"
mark_phase "local_report_start"
report_rc=0
while IFS= read -r resolution; do
  SCOPE_HEIGHT="${resolution%x*}"
  SCOPE_WIDTH="${resolution#*x}"
  resolution_label="${SCOPE_HEIGHT}x${SCOPE_WIDTH}"
  if is_sweep_mode; then
    active_local_dir="${LOCAL_OUT_DIR}/runs/${resolution_label}"
  else
    active_local_dir="${LOCAL_OUT_DIR}"
  fi
  active_flat_video="$(flat_video_for_label "${resolution_label}")"
  active_flat_frame="$(flat_frame_for_label "${resolution_label}")"
  copy_flat_artifacts "${active_local_dir}" "${active_flat_video}" "${active_flat_frame}"
  set +e
  write_local_report \
    "${active_local_dir}/run_report.json" \
    "${RUN_ID}${SWEEP_RESOLUTIONS:+_${resolution_label}}" \
    "${active_local_dir}" \
    "${active_flat_video}" \
    "${SCOPE_HEIGHT}" \
    "${SCOPE_WIDTH}"
  rc=$?
  set -e
  if ! is_sweep_mode && [[ "${rc}" -ne 0 ]]; then
    report_rc="${rc}"
  fi
done < <(printf '%s\n' "${RESOLUTION_ITEMS[@]}")
if is_sweep_mode; then
  set +e
  write_sweep_report "${LOCAL_OUT_DIR}/sweep_manifest.tsv"
  sweep_rc=$?
  set -e
  report_rc="${sweep_rc}"
fi
mark_phase "local_report_done"
echo "[scope-vast] local_dir=${LOCAL_OUT_DIR}"
echo "[scope-vast] local_video=${FLAT_LOCAL_VIDEO}"
if is_sweep_mode; then
  echo "[scope-vast] sweep_report=${LOCAL_OUT_DIR}/sweep_report.json"
fi
exit "${report_rc}"
