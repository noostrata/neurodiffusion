#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${REPO_ROOT}/VideoDiffusion/video_runtime_common.sh"

CONFIG_FILE="${PRIME_CONFIG_FILE:-${REPO_ROOT}/config/prime.env}"
PRESET_PRIME_POD_ID="${PRIME_POD_ID+x}"
PRESET_PRIME_POD_ID_VAL="${PRIME_POD_ID:-}"
PRESET_PRIME_SSH_KEY_PATH="${PRIME_SSH_KEY_PATH+x}"
PRESET_PRIME_SSH_KEY_PATH_VAL="${PRIME_SSH_KEY_PATH:-}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi
if [[ -n "${PRESET_PRIME_POD_ID}" ]]; then
  PRIME_POD_ID="${PRESET_PRIME_POD_ID_VAL}"
fi
if [[ -n "${PRESET_PRIME_SSH_KEY_PATH}" ]]; then
  PRIME_SSH_KEY_PATH="${PRESET_PRIME_SSH_KEY_PATH_VAL}"
fi

: "${PRIME_POD_ID:?Set PRIME_POD_ID before running remote build.}"
: "${PRIME_SSH_KEY_PATH:?Set PRIME_SSH_KEY_PATH to your private key path.}"

VIDEO_MODEL="${VIDEO_MODEL:-magi}"
ATTN_BACKEND="${ATTN_BACKEND:-auto}"
VIDEO_RUNTIME_TAG="${VIDEO_RUNTIME_TAG:-}"
VIDEO_REMOTE_RESTORE_TAG="${VIDEO_REMOTE_RESTORE_TAG:-}"
VIDEO_REMOTE_SETUP="${VIDEO_REMOTE_SETUP:-1}"
VIDEO_REMOTE_RESTORE_MODE="${VIDEO_REMOTE_RESTORE_MODE:-auto}"
VIDEO_REMOTE_PUBLISH_PREBUILD="${VIDEO_REMOTE_PUBLISH_PREBUILD:-1}"
VIDEO_REMOTE_INCLUDE_WEIGHTS="${VIDEO_REMOTE_INCLUDE_WEIGHTS:-1}"
VIDEO_REMOTE_INCLUDE_IMAGE="${VIDEO_REMOTE_INCLUDE_IMAGE:-0}"
VIDEO_REMOTE_TIERS="${VIDEO_REMOTE_TIERS:-}"
VIDEO_REMOTE_RESET_VENV="${VIDEO_REMOTE_RESET_VENV:-0}"
VIDEO_REMOTE_WORKDIR_RAW="${PRIME_REMOTE_WORKDIR:-~/neurodiffusion}"
VIDEO_REMOTE_BUILD_ID="${VIDEO_REMOTE_BUILD_ID:-build_$(date +%Y%m%d_%H%M%S)_${RANDOM}}"
VIDEO_REMOTE_DOWNLOAD_WEIGHTS="${VIDEO_REMOTE_DOWNLOAD_WEIGHTS:-auto}" # auto|1|0
KREA_MODEL_REPO_ID="${KREA_MODEL_REPO_ID:-}"
KREA_MODEL_REVISION="${KREA_MODEL_REVISION:-main}"
FLASH_ATTN_ALLOW_SOURCE_BUILD="${FLASH_ATTN_ALLOW_SOURCE_BUILD:-0}"
FLASH_ATTN_MAX_JOBS="${FLASH_ATTN_MAX_JOBS:-}"
FLASH_ATTN_NVCC_THREADS="${FLASH_ATTN_NVCC_THREADS:-}"
SAGEATTENTION_REQUIRED="${SAGEATTENTION_REQUIRED:-0}"

STRICT_HOST="${PRIME_STRICT_HOST_KEY_CHECKING:-accept-new}"
USER_KNOWN_HOSTS_FILE="${PRIME_USER_KNOWN_HOSTS_FILE:-/dev/null}"
GLOBAL_KNOWN_HOSTS_FILE="${PRIME_GLOBAL_KNOWN_HOSTS_FILE:-/dev/null}"
SSH_CONNECT_TIMEOUT_S="${PRIME_SSH_CONNECT_TIMEOUT_S:-20}"
SSH_SERVER_ALIVE_INTERVAL_S="${PRIME_SSH_SERVER_ALIVE_INTERVAL_S:-30}"
SSH_SERVER_ALIVE_COUNT_MAX="${PRIME_SSH_SERVER_ALIVE_COUNT_MAX:-8}"
SSH_READY_MAX_ATTEMPTS="${PRIME_SSH_READY_MAX_ATTEMPTS:-40}"
SSH_READY_INTERVAL_S="${PRIME_SSH_READY_INTERVAL_S:-3}"
SCP_RETRY_MAX_ATTEMPTS="${PRIME_SCP_RETRY_MAX_ATTEMPTS:-6}"

usage() {
  cat <<'EOF'
Usage:
  VIDEO_MODEL=<magi|krea> ATTN_BACKEND=<auto|sage|flash|sdpa> \
  bash scripts/prime/build_video_runtime_remote.sh [options]

Options:
  --model <magi|krea>             Video model runtime
  --attn-backend <mode>           auto|sage|flash|sdpa
  --runtime-tag <tag>             Optional runtime tag to restore before setup
  --restore-tag <tag>             Optional restore source tag (defaults to --runtime-tag)
  --restore-mode <auto|tuple|image>
  --reset-venv <0|1>             Remove remote venv target before setup/restore (default: 0)
  --no-setup                      Skip setup on pod
  --publish-prebuild <0|1>        Publish runtime tuple to R2 after setup (default: 1)
  --tiers <csv>                   Tier metadata for publish step
  --include-image                 Include image artifact in publish step
  --no-include-weights            Skip weights/cache archive in publish step
  --download-weights <auto|1|0>   Run model weight download stage
  --krea-repo-id <repo_id>        HF repo id for krea download stage
  --krea-revision <revision>      HF revision for krea download stage
  (env) FLASH_ATTN_ALLOW_SOURCE_BUILD=1 enables flash-attn source build fallback
  (env) FLASH_ATTN_MAX_JOBS / FLASH_ATTN_NVCC_THREADS tune flash-attn build parallelism
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      VIDEO_MODEL="$2"
      shift 2
      ;;
    --attn-backend)
      ATTN_BACKEND="$2"
      shift 2
      ;;
    --runtime-tag)
      VIDEO_RUNTIME_TAG="$2"
      shift 2
      ;;
    --restore-tag)
      VIDEO_REMOTE_RESTORE_TAG="$2"
      shift 2
      ;;
    --restore-mode)
      VIDEO_REMOTE_RESTORE_MODE="$2"
      shift 2
      ;;
    --no-setup)
      VIDEO_REMOTE_SETUP="0"
      shift
      ;;
    --reset-venv)
      VIDEO_REMOTE_RESET_VENV="$2"
      shift 2
      ;;
    --publish-prebuild)
      VIDEO_REMOTE_PUBLISH_PREBUILD="$2"
      shift 2
      ;;
    --tiers)
      VIDEO_REMOTE_TIERS="$2"
      shift 2
      ;;
    --include-image)
      VIDEO_REMOTE_INCLUDE_IMAGE="1"
      shift
      ;;
    --no-include-weights)
      VIDEO_REMOTE_INCLUDE_WEIGHTS="0"
      shift
      ;;
    --download-weights)
      VIDEO_REMOTE_DOWNLOAD_WEIGHTS="$2"
      shift 2
      ;;
    --krea-repo-id)
      KREA_MODEL_REPO_ID="$2"
      shift 2
      ;;
    --krea-revision)
      KREA_MODEL_REVISION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

VIDEO_MODEL="$(normalize_video_model "${VIDEO_MODEL}")"
ATTN_BACKEND="$(normalize_attn_backend "${ATTN_BACKEND}")"
if [[ -z "${VIDEO_REMOTE_RESTORE_TAG}" ]]; then
  VIDEO_REMOTE_RESTORE_TAG="${VIDEO_RUNTIME_TAG}"
fi
if [[ -z "${VIDEO_REMOTE_TIERS}" ]]; then
  VIDEO_REMOTE_TIERS="$(default_tiers_for_model "${VIDEO_MODEL}")"
fi

if [[ ! -f "${PRIME_SSH_KEY_PATH/#\~/$HOME}" ]]; then
  echo "[error] SSH key path not found: ${PRIME_SSH_KEY_PATH}" >&2
  exit 1
fi

shell_quote() {
  python3 - "$1" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
}

require_positive_int() {
  local name="$1"
  local value="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -le 0 ]]; then
    echo "[error] ${name} must be a positive integer (got '${value}')." >&2
    exit 1
  fi
}

require_positive_int "PRIME_SSH_READY_MAX_ATTEMPTS" "${SSH_READY_MAX_ATTEMPTS}"
require_positive_int "PRIME_SSH_READY_INTERVAL_S" "${SSH_READY_INTERVAL_S}"
require_positive_int "PRIME_SCP_RETRY_MAX_ATTEMPTS" "${SCP_RETRY_MAX_ATTEMPTS}"

eval "$("${REPO_ROOT}/scripts/prime/resolve_ssh.sh")"
REMOTE="${PRIME_SSH_USER}@${PRIME_SSH_HOST}"
SSH_PORT="${PRIME_SSH_PORT:-22}"
SSH_OPTS=(
  -i "${PRIME_SSH_KEY_PATH/#\~/$HOME}"
  -p "${SSH_PORT}"
  -o "StrictHostKeyChecking=${STRICT_HOST}"
  -o "UserKnownHostsFile=${USER_KNOWN_HOSTS_FILE}"
  -o "GlobalKnownHostsFile=${GLOBAL_KNOWN_HOSTS_FILE}"
  -o "BatchMode=yes"
  -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT_S}"
  -o "ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL_S}"
  -o "ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT_MAX}"
)
SCP_OPTS=(
  -i "${PRIME_SSH_KEY_PATH/#\~/$HOME}"
  -P "${SSH_PORT}"
  -o "StrictHostKeyChecking=${STRICT_HOST}"
  -o "UserKnownHostsFile=${USER_KNOWN_HOSTS_FILE}"
  -o "GlobalKnownHostsFile=${GLOBAL_KNOWN_HOSTS_FILE}"
  -o "BatchMode=yes"
  -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT_S}"
  -o "ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL_S}"
  -o "ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT_MAX}"
)

wait_for_ssh_ready() {
  local attempt=1
  local rc=0
  while [[ "${attempt}" -le "${SSH_READY_MAX_ATTEMPTS}" ]]; do
    if ssh "${SSH_OPTS[@]}" "${REMOTE}" "bash -lc 'true'" >/dev/null 2>&1; then
      return 0
    fi
    rc=$?
    if [[ "${attempt}" -eq 1 || $((attempt % 5)) -eq 0 ]]; then
      echo "[remote] Waiting for SSH readiness (attempt ${attempt}/${SSH_READY_MAX_ATTEMPTS}, rc=${rc})..."
    fi
    sleep "${SSH_READY_INTERVAL_S}"
    attempt=$((attempt + 1))
  done
  echo "[error] SSH not ready after ${SSH_READY_MAX_ATTEMPTS} attempts." >&2
  return 1
}

run_scp_with_retry() {
  local desc="$1"
  shift
  local attempt=1
  local rc=0
  while [[ "${attempt}" -le "${SCP_RETRY_MAX_ATTEMPTS}" ]]; do
    wait_for_ssh_ready
    if scp "${SCP_OPTS[@]}" "$@"; then
      return 0
    fi
    rc=$?
    if [[ "${attempt}" -lt "${SCP_RETRY_MAX_ATTEMPTS}" ]]; then
      echo "[remote] ${desc} failed with scp rc=${rc}; retrying (${attempt}/${SCP_RETRY_MAX_ATTEMPTS})..."
      sleep $((SSH_READY_INTERVAL_S * attempt))
    fi
    attempt=$((attempt + 1))
  done
  echo "[error] ${desc} failed after ${SCP_RETRY_MAX_ATTEMPTS} attempts (last rc=${rc})." >&2
  return "${rc}"
}

sync_archive="$(mktemp /tmp/neurodiffusion_video_sync.XXXXXX.tar.gz)"
trap 'rm -f "${sync_archive}"' EXIT
tar -czf "${sync_archive}" \
  --exclude=".git" \
  --exclude="config/prime.env" \
  --exclude="VideoDiffusion/MAGI-1" \
  --exclude="VideoDiffusion/.vendors" \
  --exclude="VideoDiffusion/.cache" \
  --exclude="VideoDiffusion/.venv" \
  --exclude="VideoDiffusion/.venv-krea" \
  --exclude="VideoDiffusion/.tmp" \
  --exclude="*.mp4" \
  --exclude="__pycache__" \
  -C "${REPO_ROOT}" \
  AGENTS.md README.md ImageDiffusion VideoDiffusion docs scripts config

remote_archive="/tmp/neurodiffusion_${VIDEO_REMOTE_BUILD_ID}.tar.gz"
run_scp_with_retry "repo archive upload" "${sync_archive}" "${REMOTE}:${remote_archive}"

remote_workdir_q="$(shell_quote "${VIDEO_REMOTE_WORKDIR_RAW}")"
remote_archive_q="$(shell_quote "${remote_archive}")"
REMOTE_WORKDIR="$(
  wait_for_ssh_ready
  ssh "${SSH_OPTS[@]}" "${REMOTE}" \
    "bash -lc 'set -euo pipefail; w=${remote_workdir_q}; w=\${w/#\~/\$HOME}; mkdir -p \"\${w}\"; tar -xzf ${remote_archive_q} -C \"\${w}\"; rm -f ${remote_archive_q}; printf \"%s\" \"\${w}\"'"
)"

if [[ -z "${REMOTE_WORKDIR}" ]]; then
  echo "[error] failed to resolve remote workdir." >&2
  exit 1
fi

if [[ "${VIDEO_MODEL}" == "magi" ]]; then
  REMOTE_VENV_TARGET="${REMOTE_WORKDIR}/VideoDiffusion/.venv"
  REMOTE_WEIGHTS_TARGET="${REMOTE_WORKDIR}/VideoDiffusion/MAGI-1"
else
  REMOTE_VENV_TARGET="${REMOTE_WORKDIR}/VideoDiffusion/.venv-krea"
  REMOTE_WEIGHTS_TARGET="${REMOTE_WORKDIR}/VideoDiffusion/.cache/krea"
fi

AGENT_BUCKET="${AGENT_S3_BUCKET:-}"
AGENT_ENDPOINT="${AGENT_S3_ENDPOINT:-}"
AGENT_REGION="${AGENT_S3_REGION:-}"
AGENT_KEY="${AGENT_S3_ACCESS_KEY_ID:-}"
AGENT_SECRET="${AGENT_S3_SECRET_ACCESS_KEY:-}"

wait_for_ssh_ready
ssh "${SSH_OPTS[@]}" "${REMOTE}" \
  "REMOTE_WORKDIR=$(shell_quote "${REMOTE_WORKDIR}") \
VIDEO_MODEL=$(shell_quote "${VIDEO_MODEL}") \
ATTN_BACKEND=$(shell_quote "${ATTN_BACKEND}") \
VIDEO_RUNTIME_TAG=$(shell_quote "${VIDEO_RUNTIME_TAG}") \
VIDEO_REMOTE_RESTORE_TAG=$(shell_quote "${VIDEO_REMOTE_RESTORE_TAG}") \
VIDEO_REMOTE_SETUP=$(shell_quote "${VIDEO_REMOTE_SETUP}") \
VIDEO_REMOTE_RESTORE_MODE=$(shell_quote "${VIDEO_REMOTE_RESTORE_MODE}") \
VIDEO_REMOTE_PUBLISH_PREBUILD=$(shell_quote "${VIDEO_REMOTE_PUBLISH_PREBUILD}") \
VIDEO_REMOTE_INCLUDE_WEIGHTS=$(shell_quote "${VIDEO_REMOTE_INCLUDE_WEIGHTS}") \
VIDEO_REMOTE_INCLUDE_IMAGE=$(shell_quote "${VIDEO_REMOTE_INCLUDE_IMAGE}") \
VIDEO_REMOTE_TIERS=$(shell_quote "${VIDEO_REMOTE_TIERS}") \
VIDEO_REMOTE_RESET_VENV=$(shell_quote "${VIDEO_REMOTE_RESET_VENV}") \
REMOTE_VENV_TARGET=$(shell_quote "${REMOTE_VENV_TARGET}") \
REMOTE_WEIGHTS_TARGET=$(shell_quote "${REMOTE_WEIGHTS_TARGET}") \
KREA_MODEL_REPO_ID=$(shell_quote "${KREA_MODEL_REPO_ID}") \
KREA_MODEL_REVISION=$(shell_quote "${KREA_MODEL_REVISION}") \
VIDEO_REMOTE_DOWNLOAD_WEIGHTS=$(shell_quote "${VIDEO_REMOTE_DOWNLOAD_WEIGHTS}") \
FLASH_ATTN_ALLOW_SOURCE_BUILD=$(shell_quote "${FLASH_ATTN_ALLOW_SOURCE_BUILD}") \
FLASH_ATTN_MAX_JOBS=$(shell_quote "${FLASH_ATTN_MAX_JOBS}") \
FLASH_ATTN_NVCC_THREADS=$(shell_quote "${FLASH_ATTN_NVCC_THREADS}") \
SAGEATTENTION_REQUIRED=$(shell_quote "${SAGEATTENTION_REQUIRED}") \
AGENT_S3_BUCKET=$(shell_quote "${AGENT_BUCKET}") \
AGENT_S3_ENDPOINT=$(shell_quote "${AGENT_ENDPOINT}") \
AGENT_S3_REGION=$(shell_quote "${AGENT_REGION}") \
AGENT_S3_ACCESS_KEY_ID=$(shell_quote "${AGENT_KEY}") \
AGENT_S3_SECRET_ACCESS_KEY=$(shell_quote "${AGENT_SECRET}") \
HUGGING_FACE_HUB_TOKEN=$(shell_quote "${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}") \
bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

cd "${REMOTE_WORKDIR}"

HAS_R2_CREDS="0"
if [[ -n "${AGENT_S3_BUCKET}" && -n "${AGENT_S3_ENDPOINT}" && -n "${AGENT_S3_ACCESS_KEY_ID}" && -n "${AGENT_S3_SECRET_ACCESS_KEY}" ]]; then
  HAS_R2_CREDS="1"
fi

if [[ -n "${VIDEO_REMOTE_RESTORE_TAG}" && "${HAS_R2_CREDS}" == "1" ]]; then
  if [[ "${VIDEO_REMOTE_RESET_VENV}" == "1" ]]; then
    echo "[remote] resetting venv target ${REMOTE_VENV_TARGET}"
    rm -rf "${REMOTE_VENV_TARGET}"
  fi
  echo "[remote] restoring runtime tag ${VIDEO_REMOTE_RESTORE_TAG} (mode=${VIDEO_REMOTE_RESTORE_MODE})"
  set +e
  bash VideoDiffusion/restore_r2_prebuild_model.sh \
    --model "${VIDEO_MODEL}" \
    --mode "${VIDEO_REMOTE_RESTORE_MODE}" \
    --runtime-tag "${VIDEO_REMOTE_RESTORE_TAG}" \
    --dest-dir "${REMOTE_WORKDIR}/VideoDiffusion/.tmp/r2_restore_${VIDEO_MODEL}" \
    --apply-venv-target "${REMOTE_VENV_TARGET}" \
    --apply-weights-target "${REMOTE_WEIGHTS_TARGET}"
  RESTORE_RC=$?
  set -e
  if [[ "${RESTORE_RC}" -ne 0 && "${VIDEO_REMOTE_RESTORE_MODE}" != "auto" ]]; then
    echo "[remote][error] restore failed in strict mode (${VIDEO_REMOTE_RESTORE_MODE})" >&2
    exit "${RESTORE_RC}"
  fi
fi

if [[ "${VIDEO_REMOTE_SETUP}" == "1" ]]; then
  echo "[remote] setting up runtime for model=${VIDEO_MODEL} attn=${ATTN_BACKEND}"
  FLASH_ATTN_ALLOW_SOURCE_BUILD="${FLASH_ATTN_ALLOW_SOURCE_BUILD}" \
  FLASH_ATTN_MAX_JOBS="${FLASH_ATTN_MAX_JOBS}" \
  FLASH_ATTN_NVCC_THREADS="${FLASH_ATTN_NVCC_THREADS}" \
  SAGEATTENTION_REQUIRED="${SAGEATTENTION_REQUIRED}" \
  VIDEO_MODEL="${VIDEO_MODEL}" \
  ATTN_BACKEND="${ATTN_BACKEND}" \
    bash VideoDiffusion/setup_video_runtime.sh
fi

DO_DOWNLOAD="0"
if [[ "${VIDEO_MODEL}" == "magi" ]]; then
  if [[ "${VIDEO_REMOTE_DOWNLOAD_WEIGHTS}" == "1" || "${VIDEO_REMOTE_DOWNLOAD_WEIGHTS}" == "auto" ]]; then
    DO_DOWNLOAD="1"
    bash VideoDiffusion/download_weights.sh
  fi
else
  if [[ "${VIDEO_REMOTE_DOWNLOAD_WEIGHTS}" == "1" ]]; then
    DO_DOWNLOAD="1"
  elif [[ "${VIDEO_REMOTE_DOWNLOAD_WEIGHTS}" == "auto" && -n "${KREA_MODEL_REPO_ID}" ]]; then
    DO_DOWNLOAD="1"
  fi

  if [[ "${DO_DOWNLOAD}" == "1" ]]; then
    if [[ -z "${KREA_MODEL_REPO_ID}" ]]; then
      echo "[remote][error] KREA_MODEL_REPO_ID required when download stage is enabled." >&2
      exit 1
    fi
    KREA_MODEL_REPO_ID="${KREA_MODEL_REPO_ID}" \
    KREA_MODEL_REVISION="${KREA_MODEL_REVISION}" \
      bash VideoDiffusion/download_krea_weights.sh
  fi
fi

if [[ "${VIDEO_REMOTE_PUBLISH_PREBUILD}" == "1" ]]; then
  if [[ "${HAS_R2_CREDS}" != "1" ]]; then
    echo "[remote][error] publish requested but AGENT_S3_* credentials are missing." >&2
    exit 1
  fi
  echo "[remote] publishing runtime tuple to R2 (model-aware prebuild only)"
  PUBLISH_ARGS=(
    --model "${VIDEO_MODEL}"
    --attn-backend "${ATTN_BACKEND}"
    --tiers "${VIDEO_REMOTE_TIERS}"
    --allow-missing-env
    --allow-missing-weights
    --allow-missing-image
  )
  if [[ -n "${VIDEO_RUNTIME_TAG}" ]]; then
    PUBLISH_ARGS+=(--runtime-tag "${VIDEO_RUNTIME_TAG}")
  fi
  if [[ "${VIDEO_REMOTE_INCLUDE_WEIGHTS}" == "1" ]]; then
    PUBLISH_ARGS+=(--include-weights)
  fi
  if [[ "${VIDEO_REMOTE_INCLUDE_IMAGE}" == "1" ]]; then
    PUBLISH_ARGS+=(--include-image)
  fi
  bash VideoDiffusion/publish_r2_prebuild_model.sh "${PUBLISH_ARGS[@]}"
fi

echo "[remote] build workflow complete for model=${VIDEO_MODEL}"
echo "[remote] next step: VIDEO_MODEL=${VIDEO_MODEL} ATTN_BACKEND=${ATTN_BACKEND} bash VideoDiffusion/run_video_stream.sh"
REMOTE_SCRIPT

echo "[build] remote workflow complete on pod=${PRIME_POD_ID} model=${VIDEO_MODEL}."
