#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUNTIME_TAG="${LONGLIVE2_VAST_RUNTIME_TAG:-longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1}"
RUN_ID="${LONGLIVE2_VAST_RUN_ID:-longlive2_sp_vast_smoke_$(date -u +%Y%m%dT%H%M%SZ)}"
REMOTE_ROOT="${LONGLIVE2_VAST_REMOTE_ROOT:-/workspace/neurodiffusion}"
REMOTE_VIDEO_DIR="${REMOTE_ROOT}/VideoDiffusion"
REMOTE_RUN_DIR="${LONGLIVE2_VAST_REMOTE_RUN_DIR:-/workspace/neurodiffusion_runs/${RUN_ID}}"
REMOTE_R2_ENV="${REMOTE_ROOT}/.secrets/r2_full_access.env"
R2_ENV_FILE="${R2_ENV_FILE:-/Users/xenochain/agents/secrets/r2_full_access.env}"
R2_PREFIX="${R2_PREFIX:-neurodiffusion}"
LOCAL_OUT_DIR="${LONGLIVE2_VAST_LOCAL_OUT_DIR:-${HOME}/Downloads/${RUN_ID}}"
PHASE_LOG="${LONGLIVE2_VAST_PHASE_LOG:-${LOCAL_OUT_DIR}/phase_markers.log}"

CREATE_INSTANCE="${LONGLIVE2_VAST_CREATE_INSTANCE:-0}"
KEEP_INSTANCE="${LONGLIVE2_VAST_KEEP_INSTANCE:-0}"
DESTROY_ON_EXIT="${LONGLIVE2_VAST_DESTROY_ON_EXIT:-}"
OFFER_ID="${VAST_OFFER_ID:-}"
GPU_REGEX="${LONGLIVE2_VAST_GPU_REGEX:-H200|H100|GH200|B200|GB200}"
MIN_GPU_COUNT="${LONGLIVE2_VAST_MIN_GPU_COUNT:-2}"
MAX_GPU_COUNT="${LONGLIVE2_VAST_MAX_GPU_COUNT:-2}"
MAX_DPH="${LONGLIVE2_VAST_MAX_DPH:-8.00}"
SELECTION_GOAL="${LONGLIVE2_VAST_SELECTION_GOAL:-cost}"
ALLOW_RUNTIME_GPU_MISMATCH="${LONGLIVE2_VAST_ALLOW_RUNTIME_GPU_MISMATCH:-0}"
VAST_DISK_GB="${VAST_DISK_GB:-300}"
VAST_IMAGE="${VAST_IMAGE:-pytorch/pytorch:2.8.0-cuda12.8-cudnn9-devel}"
VAST_ENV="${VAST_ENV:-}"
VAST_LABEL="${VAST_LABEL:-neurodiffusion_${RUN_ID}}"

LONGLIVE2_PROFILE="${LONGLIVE2_PROFILE:-bf16_sp}"
LONGLIVE2_HEIGHT="${LONGLIVE2_HEIGHT:-704}"
LONGLIVE2_WIDTH="${LONGLIVE2_WIDTH:-1280}"
LONGLIVE2_FRAMES="${LONGLIVE2_FRAMES:-128}"
LONGLIVE2_SP_SIZE="${LONGLIVE2_SP_SIZE:-2}"
LONGLIVE2_DP_SIZE="${LONGLIVE2_DP_SIZE:-1}"
LONGLIVE2_SAMPLING_STEPS="${LONGLIVE2_SAMPLING_STEPS:-}"
LONGLIVE2_PROMPT="${LONGLIVE2_PROMPT:-A reactive neon tunnel breathes with smooth cinematic motion.}"
LONGLIVE2_SCHEDULE_CSV="${LONGLIVE2_SCHEDULE_CSV:-}"
LONGLIVE2_SHOT_PROMPTS="${LONGLIVE2_SHOT_PROMPTS:-}"
LONGLIVE2_SHOT_DURATIONS="${LONGLIVE2_SHOT_DURATIONS:-}"
RESTORE_TUPLE="${LONGLIVE2_VAST_RESTORE_TUPLE:-1}"
DOWNLOAD_FALLBACK="${LONGLIVE2_VAST_DOWNLOAD_FALLBACK:-0}"
INCLUDE_WAN="${LONGLIVE2_VAST_INCLUDE_WAN:-0}"
DRY_RUN="${LONGLIVE2_VAST_DRY_RUN:-0}"
SSH_READY_TIMEOUT_S="${LONGLIVE2_VAST_SSH_READY_TIMEOUT_S:-240}"

SSH_KEY_PATH="${VAST_SSH_KEY_PATH:-${HOME}/.ssh/vast_neurodiffusion_rsa}"

usage() {
  cat <<EOF
Usage:
  bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh [options]

Safe default: requires VAST_INSTANCE_ID. To create a paid Vast instance, pass --create-instance.

Options:
  --create-instance             Query/select/provision a paid Vast instance before running
  --keep-instance               Do not destroy the instance on exit
  --instance-id <id>            Use an existing Vast instance
  --offer-id <id>               Use an explicit Vast offer id when creating
  --gpu-regex <regex>           Offer GPU filter (default: ${GPU_REGEX})
  --min-gpu-count <count>       Minimum GPUs in selected offer (default: ${MIN_GPU_COUNT})
  --max-gpu-count <count>       Maximum GPUs in selected offer; 0 disables limit (default: ${MAX_GPU_COUNT})
  --max-dph <usd>               Max selected hourly rate (default: ${MAX_DPH})
  --runtime-tag <tag>           R2 LongLive2 runtime tuple (default: ${RUNTIME_TAG})
  --profile <bf16_sp|nvfp4_s4|nvfp4_s2>
                                  LongLive2 profile (default: ${LONGLIVE2_PROFILE})
  --height <pixels>             Output height, divisible by 16 (default: ${LONGLIVE2_HEIGHT})
  --width <pixels>              Output width, divisible by 16 (default: ${LONGLIVE2_WIDTH})
  --frames <count>              Output frames, divisible by 8 (default: ${LONGLIVE2_FRAMES})
  --sp-size <count>             Sequence-parallel size (default: ${LONGLIVE2_SP_SIZE})
  --dp-size <count>             Data-parallel group count (default: ${LONGLIVE2_DP_SIZE})
  --prompt <text>               Text prompt for smoke generation
  --schedule-csv <path>         Remote/repo EEG schedule CSV for prompt blocks
  --shot-prompt <text>          Multi-shot prompt; may be repeated
  --shot-duration <blocks>      Block count for each --shot-prompt
  --local-out-dir <path>        Local artifact directory (default: ${LOCAL_OUT_DIR})
  --no-restore                  Skip R2 tuple restore and run setup/download path
  --download-fallback           If restore fails, download LongLive2 model artifacts from HF
  --include-wan                 Also download Wan2.2 base assets during fallback
  --allow-runtime-gpu-mismatch  Allow smXX runtime tag to select another GPU family
  --dry-run                     Print the plan; do not call Vast or SSH
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
    --min-gpu-count)
      MIN_GPU_COUNT="$2"
      shift 2
      ;;
    --max-gpu-count)
      MAX_GPU_COUNT="$2"
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
    --profile)
      LONGLIVE2_PROFILE="$2"
      shift 2
      ;;
    --height)
      LONGLIVE2_HEIGHT="$2"
      shift 2
      ;;
    --width)
      LONGLIVE2_WIDTH="$2"
      shift 2
      ;;
    --frames)
      LONGLIVE2_FRAMES="$2"
      shift 2
      ;;
    --sp-size)
      LONGLIVE2_SP_SIZE="$2"
      shift 2
      ;;
    --dp-size)
      LONGLIVE2_DP_SIZE="$2"
      shift 2
      ;;
    --sampling-steps)
      LONGLIVE2_SAMPLING_STEPS="$2"
      shift 2
      ;;
    --prompt)
      LONGLIVE2_PROMPT="$2"
      shift 2
      ;;
    --schedule-csv)
      LONGLIVE2_SCHEDULE_CSV="$2"
      shift 2
      ;;
    --shot-prompt)
      if [[ -n "${LONGLIVE2_SHOT_PROMPTS}" ]]; then
        LONGLIVE2_SHOT_PROMPTS="${LONGLIVE2_SHOT_PROMPTS}"$'\n'"$2"
      else
        LONGLIVE2_SHOT_PROMPTS="$2"
      fi
      shift 2
      ;;
    --shot-duration)
      if [[ -n "${LONGLIVE2_SHOT_DURATIONS}" ]]; then
        LONGLIVE2_SHOT_DURATIONS="${LONGLIVE2_SHOT_DURATIONS},$2"
      else
        LONGLIVE2_SHOT_DURATIONS="$2"
      fi
      shift 2
      ;;
    --local-out-dir)
      LOCAL_OUT_DIR="$2"
      PHASE_LOG="${LONGLIVE2_VAST_PHASE_LOG:-$2/phase_markers.log}"
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
    --include-wan)
      INCLUDE_WAN="1"
      shift
      ;;
    --allow-runtime-gpu-mismatch)
      ALLOW_RUNTIME_GPU_MISMATCH="1"
      shift
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

case "${LONGLIVE2_PROFILE}" in
  bf16|bf16_sp)
    LONGLIVE2_PROFILE="bf16_sp"
    ;;
  nvfp4|nvfp4_s4|nvfp4_4step)
    LONGLIVE2_PROFILE="nvfp4_s4"
    ;;
  nvfp4_s2|nvfp4_2step)
    LONGLIVE2_PROFILE="nvfp4_s2"
    ;;
  *)
    echo "[error] unsupported LongLive2 profile '${LONGLIVE2_PROFILE}'." >&2
    exit 1
    ;;
esac

runtime_arch_from_tag() {
  local tag="$1"
  if [[ "${tag}" =~ (^|[_-])(sm[0-9]+)([_-]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

validate_profile_runtime_tuple() {
  local arch
  arch="$(runtime_arch_from_tag "${RUNTIME_TAG}")"
  if [[ "${LONGLIVE2_PROFILE}" == nvfp4* ]]; then
    if [[ "${RESTORE_TUPLE}" == "1" && "${arch}" != "sm100" && "${arch}" != "sm120" && "${ALLOW_RUNTIME_GPU_MISMATCH}" != "1" ]]; then
      echo "[error] ${LONGLIVE2_PROFILE} is the LongLive2 NVFP4 path. The paper's limitation says NVFP4 acceleration is Blackwell-only, so use an sm100/sm120 runtime tag or pass --allow-runtime-gpu-mismatch only for intentional debugging." >&2
      exit 1
    fi
    if [[ "${GPU_REGEX}" =~ A100|H100|H200|GH200 ]] && [[ ! "${GPU_REGEX}" =~ B200|GB200|5090|RTX.?50|RTX.?60 ]] && [[ "${ALLOW_RUNTIME_GPU_MISMATCH}" != "1" ]]; then
      echo "[error] ${LONGLIVE2_PROFILE} with GPU regex '${GPU_REGEX}' targets non-Blackwell GPUs. Use bf16_sp for Hopper/Ampere SP, or choose B200/GB200/RTX50-class offers." >&2
      exit 1
    fi
  fi
  if [[ "${LONGLIVE2_PROFILE}" == "bf16_sp" && "${arch}" == "sm100" ]]; then
    echo "[longlive2-vast] note: bf16_sp on Blackwell is valid for proof/debug, but it is not the paper's max-FPS NVFP4 lane." >&2
  fi
}

validate_profile_runtime_tuple

q() {
  printf "%q" "$1"
}

mark_phase() {
  local phase="$1"
  local line
  line="$(printf '[longlive2-vast-ts] %s %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${phase}")"
  printf '%s\n' "${line}"
  mkdir -p "$(dirname -- "${PHASE_LOG}")"
  printf '%s\n' "${line}" >>"${PHASE_LOG}"
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
    echo "[longlive2-vast] waiting for SSH auth (last_rc=${last_rc})" >&2
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
  local scan_json="${SCRIPT_DIR}/.tmp/${RUN_ID}_longlive2_offer_scan.json"
  local scan_csv="${SCRIPT_DIR}/.tmp/${RUN_ID}_longlive2_offer_scan.csv"
  local selected_json="${SCRIPT_DIR}/.tmp/${RUN_ID}_longlive2_offer_selected.json"
  echo "[longlive2-vast] querying offers gpu_regex=${GPU_REGEX} max_dph=${MAX_DPH}"
  python3 "${REPO_ROOT}/scripts/vast/query_video_offers.py" \
    --model longlive2 \
    --gpu-name-regex "${GPU_REGEX}" \
    --out-json "${scan_json}" \
    --out-csv "${scan_csv}"
  select_args=(
    --scan-json "${scan_json}"
    --selection-goal "${SELECTION_GOAL}"
    --min-gpu-count "${MIN_GPU_COUNT}"
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
  echo "[longlive2-vast] selected offer=${OFFER_ID}"
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
  echo "[longlive2-vast] creating paid Vast instance offer=${OFFER_ID} label=${VAST_LABEL}"
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
echo '[longlive2-vast] remote system deps ready'
"
}

sync_repo_to_remote() {
  echo "[longlive2-vast] syncing repo to ${REMOTE_ROOT}"
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

remote_setup_longlive2_clone_only() {
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/setup_longlive2.sh --profile $(q "${LONGLIVE2_PROFILE}") --skip-build 2>&1 | tee $(q "${REMOTE_RUN_DIR}/setup_longlive2_clone.log")"
}

remote_restore_or_download() {
  if [[ "${RESTORE_TUPLE}" == "1" ]]; then
    echo "[longlive2-vast] restoring R2 tuple ${RUNTIME_TAG}"
    set +e
    remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); R2_ENV_FILE=$(q "${REMOTE_R2_ENV}") R2_PREFIX=$(q "${R2_PREFIX}") bash VideoDiffusion/restore_r2_prebuild_model.sh --model longlive2 --mode tuple --runtime-tag $(q "${RUNTIME_TAG}") --apply-venv-target $(q "${REMOTE_VIDEO_DIR}/.vendors/LongLive2/.venv") --apply-weights-target $(q "${REMOTE_VIDEO_DIR}/.cache/longlive2") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/restore_longlive2_tuple.log")"
    local rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      return
    fi
    if [[ "${DOWNLOAD_FALLBACK}" != "1" ]]; then
      echo "[error] R2 tuple restore failed and download fallback is disabled." >&2
      exit "${rc}"
    fi
    echo "[longlive2-vast] restore failed; falling back to setup and model download"
  fi
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/setup_longlive2.sh --profile $(q "${LONGLIVE2_PROFILE}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/setup_longlive2_build.log")"
  download_args=(--profile "${LONGLIVE2_PROFILE}")
  if [[ "${INCLUDE_WAN}" == "1" ]]; then
    download_args+=(--include-wan)
  fi
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/download_longlive2_models.sh $(printf '%q ' "${download_args[@]}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/download_longlive2_models.log")"
}

remote_run_smoke() {
  run_args=(
    --profile "${LONGLIVE2_PROFILE}"
    --run-dir "${REMOTE_RUN_DIR}/offline"
    --height "${LONGLIVE2_HEIGHT}"
    --width "${LONGLIVE2_WIDTH}"
    --frames "${LONGLIVE2_FRAMES}"
    --sp-size "${LONGLIVE2_SP_SIZE}"
    --dp-size "${LONGLIVE2_DP_SIZE}"
    --prompt "${LONGLIVE2_PROMPT}"
  )
  if [[ -n "${LONGLIVE2_SAMPLING_STEPS}" ]]; then
    run_args+=(--sampling-steps "${LONGLIVE2_SAMPLING_STEPS}")
  fi
  if [[ -n "${LONGLIVE2_SCHEDULE_CSV}" ]]; then
    run_args+=(--schedule-csv "${LONGLIVE2_SCHEDULE_CSV}")
  fi
  if [[ -n "${LONGLIVE2_SHOT_PROMPTS}" ]]; then
    while IFS= read -r shot_prompt; do
      [[ -z "${shot_prompt}" ]] && continue
      run_args+=(--shot-prompt "${shot_prompt}")
    done <<<"${LONGLIVE2_SHOT_PROMPTS}"
  fi
  if [[ -n "${LONGLIVE2_SHOT_DURATIONS}" ]]; then
    IFS=',' read -r -a shot_duration_values <<<"${LONGLIVE2_SHOT_DURATIONS}"
    for shot_duration in "${shot_duration_values[@]}"; do
      [[ -z "${shot_duration}" ]] && continue
      run_args+=(--shot-duration "${shot_duration}")
    done
  fi
  remote_ssh "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/run_longlive2_sp_offline.sh $(printf '%q ' "${run_args[@]}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/run_longlive2_sp_offline.wrapper.log")"
}

pull_artifacts() {
  echo "[longlive2-vast] pulling artifacts to ${LOCAL_OUT_DIR}"
  mkdir -p "${LOCAL_OUT_DIR}"
  remote_scp_dir_from "${REMOTE_RUN_DIR}" "${LOCAL_OUT_DIR}"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  cat <<EOF
[longlive2-vast] dry-run
run_id=${RUN_ID}
create_instance=${CREATE_INSTANCE}
runtime_tag=${RUNTIME_TAG}
gpu_regex=${GPU_REGEX}
min_gpu_count=${MIN_GPU_COUNT}
max_gpu_count=${MAX_GPU_COUNT}
max_dph=${MAX_DPH}
profile=${LONGLIVE2_PROFILE}
geometry=${LONGLIVE2_HEIGHT}x${LONGLIVE2_WIDTH}
frames=${LONGLIVE2_FRAMES}
sp_size=${LONGLIVE2_SP_SIZE}
dp_size=${LONGLIVE2_DP_SIZE}
schedule_csv=${LONGLIVE2_SCHEDULE_CSV}
local_out_dir=${LOCAL_OUT_DIR}
EOF
  exit 0
fi

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

remote_gpu="$(remote_ssh "nvidia-smi --query-gpu=name --format=csv,noheader | paste -sd ',' -" | tr -d '\r')"
echo "[longlive2-vast] run_id=${RUN_ID}"
echo "[longlive2-vast] instance=${VAST_INSTANCE_ID} gpu=${remote_gpu}"
echo "[longlive2-vast] runtime_tag=${RUNTIME_TAG}"

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
mark_phase "setup_longlive2_start"
remote_setup_longlive2_clone_only
mark_phase "setup_longlive2_done"
mark_phase "restore_or_download_start"
remote_restore_or_download
mark_phase "restore_or_download_done"
mark_phase "longlive2_run_start"
remote_run_smoke
mark_phase "longlive2_run_done"
mark_phase "artifact_pull_start"
pull_artifacts
mark_phase "artifact_pull_done"

echo "[longlive2-vast] local_dir=${LOCAL_OUT_DIR}"
