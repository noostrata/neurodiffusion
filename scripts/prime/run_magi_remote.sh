#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

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

: "${PRIME_POD_ID:?Set PRIME_POD_ID before running remote execution.}"
: "${PRIME_SSH_KEY_PATH:?Set PRIME_SSH_KEY_PATH to your private key path.}"
: "${MAGI_TIER:?Set MAGI_TIER to 4.5b or 24b.}"
: "${HOURLY_RATE_USD:?Set HOURLY_RATE_USD from selected offer price_value.}"

BUDGET_USD="${BUDGET_USD:-15}"
SCHEDULE_CSV="${SCHEDULE_CSV:-VideoDiffusion/prompt_schedules/cyberpunk_30s_hybrid.csv}"
SELECTED_GPU_COUNT="${SELECTED_GPU_COUNT:-1}"
REMOTE_CUDA_VISIBLE_DEVICES="${REMOTE_CUDA_VISIBLE_DEVICES:-}"
RUN_TAG="${MAGI_RUN_ID:-prime_$(date +%Y%m%d_%H%M%S)_${RANDOM}}"
STRICT_HOST="${PRIME_STRICT_HOST_KEY_CHECKING:-accept-new}"
USER_KNOWN_HOSTS_FILE="${PRIME_USER_KNOWN_HOSTS_FILE:-/dev/null}"
GLOBAL_KNOWN_HOSTS_FILE="${PRIME_GLOBAL_KNOWN_HOSTS_FILE:-/dev/null}"
SSH_CONNECT_TIMEOUT_S="${PRIME_SSH_CONNECT_TIMEOUT_S:-20}"
SSH_SERVER_ALIVE_INTERVAL_S="${PRIME_SSH_SERVER_ALIVE_INTERVAL_S:-30}"
SSH_SERVER_ALIVE_COUNT_MAX="${PRIME_SSH_SERVER_ALIVE_COUNT_MAX:-8}"
SSH_READY_MAX_ATTEMPTS="${PRIME_SSH_READY_MAX_ATTEMPTS:-40}"
SSH_READY_INTERVAL_S="${PRIME_SSH_READY_INTERVAL_S:-3}"
SCP_RETRY_MAX_ATTEMPTS="${PRIME_SCP_RETRY_MAX_ATTEMPTS:-6}"
REMOTE_BOOTSTRAP="${MAGI_REMOTE_BOOTSTRAP:-auto}" # auto|1|0
REMOTE_SKIP_DOWNLOAD="${MAGI_REMOTE_SKIP_DOWNLOAD:-auto}" # auto|1|0
MAGI_RESTORE_MODE="${MAGI_RESTORE_MODE:-auto}"
MAGI_RUNTIME_TAG="${MAGI_RUNTIME_TAG:-}"
MAGI_UPLOAD_TO_R2="${MAGI_UPLOAD_TO_R2:-1}"
R2_PREFIX_RUNTIME="${R2_PREFIX:-neurodiffusion}"
REMOTE_PUBLISH_PREBUILD="${MAGI_REMOTE_PUBLISH_PREBUILD:-0}"
REMOTE_PUBLISH_TIERS="${MAGI_REMOTE_PUBLISH_TIERS:-${MAGI_TIER}}"

if [[ ! -f "${PRIME_SSH_KEY_PATH/#\~/$HOME}" ]]; then
  echo "[error] SSH key path not found: ${PRIME_SSH_KEY_PATH}" >&2
  exit 1
fi

if [[ "${MAGI_TIER}" != "4.5b" && "${MAGI_TIER}" != "24b" ]]; then
  echo "[error] MAGI_TIER must be 4.5b or 24b (got '${MAGI_TIER}')." >&2
  exit 1
fi

if [[ -z "${REMOTE_CUDA_VISIBLE_DEVICES}" ]]; then
  if ! [[ "${SELECTED_GPU_COUNT}" =~ ^[0-9]+$ ]]; then
    echo "[error] SELECTED_GPU_COUNT must be an integer when REMOTE_CUDA_VISIBLE_DEVICES is unset." >&2
    exit 1
  fi
  if [[ "${SELECTED_GPU_COUNT}" -le 0 ]]; then
    echo "[error] SELECTED_GPU_COUNT must be >= 1." >&2
    exit 1
  fi
  REMOTE_CUDA_VISIBLE_DEVICES="$(
    python3 - "${SELECTED_GPU_COUNT}" <<'PY'
import sys
n = int(sys.argv[1])
print(",".join(str(i) for i in range(n)))
PY
  )"
fi

REMOTE_WORKDIR_RAW="${PRIME_REMOTE_WORKDIR:-~/neurodiffusion}"

resolve_rel_path() {
  local p="$1"
  if [[ "${p}" = /* ]]; then
    python3 - "${REPO_ROOT}" "${p}" <<'PY'
import os
import sys
repo, path = sys.argv[1:]
repo = os.path.realpath(repo)
path = os.path.realpath(path)
if os.path.commonpath([repo, path]) != repo:
    raise SystemExit(2)
print(os.path.relpath(path, repo))
PY
    return
  fi
  if [[ -f "${REPO_ROOT}/${p}" ]]; then
    printf "%s\n" "${p}"
    return
  fi
  echo "[error] Path not found in repo: ${p}" >&2
  return 1
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
}

SCHEDULE_REL="$(resolve_rel_path "${SCHEDULE_CSV}")"

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

wait_for_ssh_ready() {
  local attempt=1
  local rc=0
  while [[ "${attempt}" -le "${SSH_READY_MAX_ATTEMPTS}" ]]; do
    if ssh "${SSH_OPTS[@]}" "${REMOTE}" "bash -lc 'true'" >/dev/null 2>&1; then
      if [[ "${attempt}" -gt 1 ]]; then
        echo "[remote] SSH became ready after ${attempt} attempts."
      fi
      return 0
    else
      rc=$?
    fi
    if [[ "${attempt}" -eq 1 || $((attempt % 5)) -eq 0 ]]; then
      echo "[remote] Waiting for SSH readiness (attempt ${attempt}/${SSH_READY_MAX_ATTEMPTS}, rc=${rc})..."
    fi
    sleep "${SSH_READY_INTERVAL_S}"
    attempt=$((attempt + 1))
  done
  echo "[error] SSH was not ready after ${SSH_READY_MAX_ATTEMPTS} attempts." >&2
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
    else
      rc=$?
    fi
    if [[ "${attempt}" -lt "${SCP_RETRY_MAX_ATTEMPTS}" ]]; then
      echo "[remote] ${desc} failed with scp rc=${rc}; retrying (${attempt}/${SCP_RETRY_MAX_ATTEMPTS})..."
      sleep $((SSH_READY_INTERVAL_S * attempt))
    fi
    attempt=$((attempt + 1))
  done
  echo "[error] ${desc} failed after ${SCP_RETRY_MAX_ATTEMPTS} attempts (last rc=${rc})." >&2
  return "${rc}"
}

sync_archive_base="$(mktemp /tmp/neurodiffusion_sync.XXXXXX)"
sync_archive="${sync_archive_base}.tar.gz"
mv "${sync_archive_base}" "${sync_archive}"
trap 'rm -f "${sync_archive}"' EXIT

COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "${sync_archive}" \
  --exclude=".git" \
  --exclude="config/prime.env" \
  --exclude="VideoDiffusion/MAGI-1" \
  --exclude="*.mp4" \
  --exclude="__pycache__" \
  --exclude=".venv" \
  --exclude="VideoDiffusion/.tmp" \
  -C "${REPO_ROOT}" \
  AGENTS.md README.md ImageDiffusion VideoDiffusion docs scripts config

remote_archive="/tmp/neurodiffusion_${RUN_TAG}.tar.gz"
run_scp_with_retry "repo archive upload" "${sync_archive}" "${REMOTE}:${remote_archive}"

remote_workdir_q="$(
  python3 - "${REMOTE_WORKDIR_RAW}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
remote_archive_q="$(
  python3 - "${remote_archive}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"

REMOTE_WORKDIR="$(
  wait_for_ssh_ready
  ssh "${SSH_OPTS[@]}" "${REMOTE}" \
    "bash -lc 'set -euo pipefail; w=${remote_workdir_q}; w=\${w/#\~/\$HOME}; mkdir -p \"\${w}\"; tar -xzf ${remote_archive_q} -C \"\${w}\"; rm -f ${remote_archive_q}; printf \"%s\" \"\${w}\"'"
)"

if [[ -z "${REMOTE_WORKDIR}" ]]; then
  echo "[error] Failed to resolve remote workdir." >&2
  exit 1
fi

remote_workdir_abs_q="$(
  python3 - "${REMOTE_WORKDIR}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"

tier_q="$(python3 - "${MAGI_TIER}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
budget_q="$(python3 - "${BUDGET_USD}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
rate_q="$(python3 - "${HOURLY_RATE_USD}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
devices_q="$(python3 - "${REMOTE_CUDA_VISIBLE_DEVICES}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
schedule_q="$(python3 - "${SCHEDULE_REL}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
run_tag_q="$(python3 - "${RUN_TAG}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
scripted_num_frames="${MAGI_NUM_FRAMES:-720}"
if ! [[ "${scripted_num_frames}" =~ ^[0-9]+$ ]] || [[ "${scripted_num_frames}" -le 0 ]]; then
  echo "[error] MAGI_NUM_FRAMES must be a positive integer when provided (got '${scripted_num_frames}')." >&2
  exit 1
fi
if [[ "${scripted_num_frames}" -eq 720 ]]; then
  remote_output_basename="magi_scripted_30s_${RUN_TAG}.mp4"
else
  remote_output_basename="magi_scripted_${scripted_num_frames}f_${RUN_TAG}.mp4"
fi
remote_output_basename_q="$(shell_quote "${remote_output_basename}")"
restore_mode_q="$(shell_quote "${MAGI_RESTORE_MODE}")"
runtime_tag_q="$(shell_quote "${MAGI_RUNTIME_TAG}")"
r2_prefix_q="$(shell_quote "${R2_PREFIX_RUNTIME}")"
publish_tiers_q="$(shell_quote "${REMOTE_PUBLISH_TIERS}")"

agent_bucket_q="$(shell_quote "${AGENT_S3_BUCKET:-}")"
agent_endpoint_q="$(shell_quote "${AGENT_S3_ENDPOINT:-}")"
agent_region_q="$(shell_quote "${AGENT_S3_REGION:-}")"
agent_key_q="$(shell_quote "${AGENT_S3_ACCESS_KEY_ID:-}")"
agent_secret_q="$(shell_quote "${AGENT_S3_SECRET_ACCESS_KEY:-}")"
fp8_override_q="$(shell_quote "${MAGI_FP8:-${VIDEO_MAGE_FP8:-}}")"
hf_token_q="$(shell_quote "${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}")"

extra_run_env_assignments=()
append_extra_run_env() {
  local key="$1"
  local val="${!key:-}"
  if [[ -n "${val}" ]]; then
    extra_run_env_assignments+=("${key}=$(shell_quote "${val}")")
  fi
}
for key in \
  MAGI_VIDEO_SIZE_H \
  MAGI_VIDEO_SIZE_W \
  MAGI_NUM_STEPS \
  MAGI_NUM_FRAMES \
  MAGI_WINDOW_SIZE \
  MAGI_CONFIG_FILE \
  MAGI_CP_SIZE \
  MAGI_PP_SIZE \
  CALIB_CHUNKS \
  CALIB_TIMEOUT_S \
  CALIB_RUNG_LIST \
  SCHEDULE_TIMEOUT_S \
  SERVER_READY_TIMEOUT_S \
  TARGET_TPOC_S \
  QUEUE_LEN \
  DROP_OLD_ON_PROMPT \
  JPEG_QUALITY; do
  append_extra_run_env "${key}"
done
EXTRA_RUN_ENV=""
if [[ "${#extra_run_env_assignments[@]}" -gt 0 ]]; then
  EXTRA_RUN_ENV=" ${extra_run_env_assignments[*]}"
fi

if [[ "${MAGI_TIER}" == "24b" ]]; then
  REMOTE_WEIGHT_VARIANT="${MAGI_REMOTE_WEIGHT_VARIANT:-24B_distill_quant}"
else
  # Use non-quant by default for stable scripted 4.5B runs on fresh pods.
  REMOTE_WEIGHT_VARIANT="${MAGI_REMOTE_WEIGHT_VARIANT:-4.5B_distill}"
fi
weight_variant_q="$(python3 - "${REMOTE_WEIGHT_VARIANT}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"

RESTORE_SUCCEEDED="0"
if [[ -n "${MAGI_RUNTIME_TAG}" ]]; then
  if [[ -n "${AGENT_S3_BUCKET:-}" && -n "${AGENT_S3_ENDPOINT:-}" && -n "${AGENT_S3_ACCESS_KEY_ID:-}" && -n "${AGENT_S3_SECRET_ACCESS_KEY:-}" ]]; then
    echo "[remote] Restoring runtime tag ${MAGI_RUNTIME_TAG} (mode=${MAGI_RESTORE_MODE}) on pod ${PRIME_POD_ID}..."
    set +e
    wait_for_ssh_ready
    ssh "${SSH_OPTS[@]}" "${REMOTE}" \
      "REMOTE_WORKDIR=${remote_workdir_abs_q} RUN_TAG=${run_tag_q} MAGI_TIER=${tier_q} MAGI_RUNTIME_TAG=${runtime_tag_q} MAGI_RESTORE_MODE=${restore_mode_q} R2_PREFIX=${r2_prefix_q} AGENT_S3_BUCKET=${agent_bucket_q} AGENT_S3_ENDPOINT=${agent_endpoint_q} AGENT_S3_REGION=${agent_region_q} AGENT_S3_ACCESS_KEY_ID=${agent_key_q} AGENT_S3_SECRET_ACCESS_KEY=${agent_secret_q} bash -lc 'set -euo pipefail; cd \"\${REMOTE_WORKDIR}\"; bash VideoDiffusion/restore_r2_prebuild.sh --mode \"\${MAGI_RESTORE_MODE}\" --runtime-tag \"\${MAGI_RUNTIME_TAG}\" --tier \"\${MAGI_TIER}\" --dest-dir \"\${REMOTE_WORKDIR}/VideoDiffusion/.tmp/r2_restore_\${RUN_TAG}\" --apply-venv-target \"\${REMOTE_WORKDIR}/VideoDiffusion/.venv\" --apply-weights-target \"\${REMOTE_WORKDIR}/VideoDiffusion/MAGI-1\"'"
    restore_rc=$?
    set -e
    if [[ "${restore_rc}" -eq 0 ]]; then
      RESTORE_SUCCEEDED="1"
      echo "[remote] Runtime restore succeeded."
    elif [[ "${MAGI_RESTORE_MODE}" == "auto" ]]; then
      echo "[remote] Runtime restore failed in auto mode; falling back to bootstrap path."
    else
      echo "[error] Runtime restore failed in mode=${MAGI_RESTORE_MODE}." >&2
      exit "${restore_rc}"
    fi
  elif [[ "${MAGI_RESTORE_MODE}" == "auto" ]]; then
    echo "[remote] Runtime tag provided but AGENT_S3_* credentials are not set; using bootstrap fallback."
  else
    echo "[error] Runtime restore requires AGENT_S3_* credentials for mode=${MAGI_RESTORE_MODE}." >&2
    exit 1
  fi
fi

DO_BOOTSTRAP="1"
if [[ "${REMOTE_BOOTSTRAP}" == "0" ]]; then
  DO_BOOTSTRAP="0"
elif [[ "${REMOTE_BOOTSTRAP}" == "auto" && "${RESTORE_SUCCEEDED}" == "1" ]]; then
  DO_BOOTSTRAP="0"
fi

DO_SKIP_DOWNLOAD="${REMOTE_SKIP_DOWNLOAD}"
if [[ "${DO_SKIP_DOWNLOAD}" == "auto" ]]; then
  if [[ "${RESTORE_SUCCEEDED}" == "1" ]]; then
    DO_SKIP_DOWNLOAD="1"
  else
    DO_SKIP_DOWNLOAD="0"
  fi
fi

APT_WAIT_MAX_S="${MAGI_REMOTE_APT_WAIT_MAX_S:-300}"
apt_wait_q="$(python3 - "${APT_WAIT_MAX_S}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"

if [[ "${DO_BOOTSTRAP}" == "1" ]]; then
  echo "[remote] Bootstrapping dependencies on pod ${PRIME_POD_ID}..."
  if [[ "${DO_SKIP_DOWNLOAD}" != "1" && -z "${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}" ]]; then
    echo "[remote] WARN: HUGGING_FACE_HUB_TOKEN/HF_TOKEN not set locally; download_weights.sh may fail on gated models." >&2
  fi
  if [[ "${DO_SKIP_DOWNLOAD}" == "1" ]]; then
    wait_for_ssh_ready
    ssh "${SSH_OPTS[@]}" "${REMOTE}" \
      "REMOTE_WORKDIR=${remote_workdir_abs_q} HUGGING_FACE_HUB_TOKEN=${hf_token_q} HF_TOKEN=${hf_token_q} APT_WAIT_MAX_S=${apt_wait_q} bash -lc 'set -euo pipefail; waited=0; while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; do if [ \"\${waited}\" -ge \"\${APT_WAIT_MAX_S}\" ]; then break; fi; sleep 2; waited=\$((waited+2)); done; cd \"\${REMOTE_WORKDIR}/VideoDiffusion\"; bash setup.sh'"
  else
    wait_for_ssh_ready
    ssh "${SSH_OPTS[@]}" "${REMOTE}" \
      "REMOTE_WORKDIR=${remote_workdir_abs_q} HUGGING_FACE_HUB_TOKEN=${hf_token_q} HF_TOKEN=${hf_token_q} VIDEO_MAGE_WEIGHT_VARIANT=${weight_variant_q} APT_WAIT_MAX_S=${apt_wait_q} bash -lc 'set -euo pipefail; waited=0; while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; do if [ \"\${waited}\" -ge \"\${APT_WAIT_MAX_S}\" ]; then break; fi; sleep 2; waited=\$((waited+2)); done; cd \"\${REMOTE_WORKDIR}/VideoDiffusion\"; bash setup.sh; bash download_weights.sh'"
  fi
fi

if [[ "${DO_BOOTSTRAP}" != "1" ]]; then
  echo "[remote] Verifying ffmpeg/ffprobe on restored runtime..."
  wait_for_ssh_ready
  ssh "${SSH_OPTS[@]}" "${REMOTE}" \
    "APT_WAIT_MAX_S=${apt_wait_q} bash -lc 'set -euo pipefail; missing=0; command -v ffmpeg >/dev/null 2>&1 || missing=1; command -v ffprobe >/dev/null 2>&1 || missing=1; if [[ \"\${missing}\" -eq 1 ]]; then waited=0; while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; do if [ \"\${waited}\" -ge \"\${APT_WAIT_MAX_S}\" ]; then break; fi; sleep 2; waited=\$((waited+2)); done; export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y ffmpeg; fi; command -v ffmpeg >/dev/null 2>&1; command -v ffprobe >/dev/null 2>&1'"
fi

echo "[remote] Running MAGI scripted test on pod ${PRIME_POD_ID} (tier=${MAGI_TIER}, devices=${REMOTE_CUDA_VISIBLE_DEVICES})..."
if [[ "${scripted_num_frames}" -ne 720 ]]; then
  echo "[remote] Non-30s profile requested: MAGI_NUM_FRAMES=${scripted_num_frames}."
fi
set +e
wait_for_ssh_ready
ssh "${SSH_OPTS[@]}" "${REMOTE}" \
  "REMOTE_WORKDIR=${remote_workdir_abs_q} MAGI_TIER=${tier_q} BUDGET_USD=${budget_q} HOURLY_RATE_USD=${rate_q} CUDA_VISIBLE_DEVICES=${devices_q} SCHEDULE_CSV=${schedule_q} SCRIPTED_RUN_TAG=${run_tag_q} MAGI_FP8=${fp8_override_q} MAGI_REMOTE_OUTPUT_BASENAME=${remote_output_basename_q}${EXTRA_RUN_ENV} bash -lc 'set -euo pipefail; cd \"\${REMOTE_WORKDIR}\"; VIDEO_SCRIPTED_OUTPUT=\"\${REMOTE_WORKDIR}/VideoDiffusion/\${MAGI_REMOTE_OUTPUT_BASENAME}\" bash VideoDiffusion/run_scripted_30s_prime.sh --mode in-pod --tier \"\${MAGI_TIER}\" --budget-usd \"\${BUDGET_USD}\" --hourly-rate-usd \"\${HOURLY_RATE_USD}\" --devices \"\${CUDA_VISIBLE_DEVICES}\" --schedule-csv \"\${SCHEDULE_CSV}\" --run-tag \"\${SCRIPTED_RUN_TAG}\"'"
REMOTE_RUN_RC=$?
set -e

if [[ "${REMOTE_PUBLISH_PREBUILD}" == "1" ]]; then
  if [[ -z "${MAGI_RUNTIME_TAG}" ]]; then
    echo "[error] MAGI_REMOTE_PUBLISH_PREBUILD=1 requires MAGI_RUNTIME_TAG." >&2
    if [[ "${REMOTE_RUN_RC}" -eq 0 ]]; then
      REMOTE_RUN_RC=2
    fi
  elif [[ -n "${AGENT_S3_BUCKET:-}" && -n "${AGENT_S3_ENDPOINT:-}" && -n "${AGENT_S3_ACCESS_KEY_ID:-}" && -n "${AGENT_S3_SECRET_ACCESS_KEY:-}" ]]; then
    echo "[remote] Publishing prebuild tuple runtime_tag=${MAGI_RUNTIME_TAG} tiers=${REMOTE_PUBLISH_TIERS}..."
    set +e
    wait_for_ssh_ready
    ssh "${SSH_OPTS[@]}" "${REMOTE}" \
      "REMOTE_WORKDIR=${remote_workdir_abs_q} MAGI_RUNTIME_TAG=${runtime_tag_q} PUBLISH_TIERS=${publish_tiers_q} R2_PREFIX=${r2_prefix_q} AGENT_S3_BUCKET=${agent_bucket_q} AGENT_S3_ENDPOINT=${agent_endpoint_q} AGENT_S3_REGION=${agent_region_q} AGENT_S3_ACCESS_KEY_ID=${agent_key_q} AGENT_S3_SECRET_ACCESS_KEY=${agent_secret_q} R2_ENV_FILE=/nonexistent bash -lc 'set -euo pipefail; cd \"\${REMOTE_WORKDIR}\"; bash VideoDiffusion/publish_r2_prebuild.sh --runtime-tag \"\${MAGI_RUNTIME_TAG}\" --tiers \"\${PUBLISH_TIERS}\" --include-weights --allow-missing-image'"
    PUBLISH_RC=$?
    set -e
    if [[ "${PUBLISH_RC}" -ne 0 ]]; then
      echo "[error] Remote prebuild publish failed with exit=${PUBLISH_RC}." >&2
      if [[ "${REMOTE_RUN_RC}" -eq 0 ]]; then
        REMOTE_RUN_RC="${PUBLISH_RC}"
      fi
    else
      echo "[remote] Prebuild publish completed."
    fi
  else
    echo "[error] MAGI_REMOTE_PUBLISH_PREBUILD=1 but AGENT_S3_* credentials are missing." >&2
    if [[ "${REMOTE_RUN_RC}" -eq 0 ]]; then
      REMOTE_RUN_RC=2
    fi
  fi
fi

local_tmp_dir="${REPO_ROOT}/VideoDiffusion/.tmp/remote_${RUN_TAG}"
mkdir -p "${local_tmp_dir}"

remote_tmp_bundle="/tmp/magi_tmp_${RUN_TAG}.tar.gz"
remote_tmp_bundle_q="$(shell_quote "${remote_tmp_bundle}")"

set +e
wait_for_ssh_ready
ssh "${SSH_OPTS[@]}" "${REMOTE}" \
  "REMOTE_WORKDIR=${remote_workdir_abs_q} RUN_TAG=${run_tag_q} REMOTE_TMP_BUNDLE=${remote_tmp_bundle_q} bash -lc 'set -euo pipefail; tmp_dir=\"\${REMOTE_WORKDIR}/VideoDiffusion/.tmp\"; if [[ -d \"\${tmp_dir}\" ]]; then cd \"\${tmp_dir}\"; if find . -maxdepth 1 -type f -name \"*\${RUN_TAG}*\" -print -quit | grep -q .; then find . -maxdepth 1 -type f -name \"*\${RUN_TAG}*\" -print0 | tar --null -czf \"\${REMOTE_TMP_BUNDLE}\" --files-from -; fi; fi'"
if run_scp_with_retry "tmp artifact sync" "${REMOTE}:${remote_tmp_bundle}" "${local_tmp_dir}/tmp_artifacts_${RUN_TAG}.tar.gz" >/dev/null 2>&1; then
  tar -xzf "${local_tmp_dir}/tmp_artifacts_${RUN_TAG}.tar.gz" -C "${local_tmp_dir}" >/dev/null 2>&1 || true
  rm -f "${local_tmp_dir}/tmp_artifacts_${RUN_TAG}.tar.gz"
fi
wait_for_ssh_ready
ssh "${SSH_OPTS[@]}" "${REMOTE}" \
  "REMOTE_TMP_BUNDLE=${remote_tmp_bundle_q} bash -lc 'set -euo pipefail; rm -f \"\${REMOTE_TMP_BUNDLE}\"'" >/dev/null 2>&1 || true
run_scp_with_retry "video artifact sync" "${REMOTE}:${REMOTE_WORKDIR}/VideoDiffusion/${remote_output_basename}" "${REPO_ROOT}/VideoDiffusion/" >/dev/null 2>&1
set -e

summary_path="$(
  find "${local_tmp_dir}" -type f -name "*${RUN_TAG}*_summary.json" | head -n1 || true
)"

echo "[remote] Artifact sync attempted."
echo "[remote] Local tmp dir: ${local_tmp_dir}"
if [[ -n "${summary_path}" ]]; then
  echo "[remote] Local summary: ${summary_path}"
fi
echo "[remote] Expected local video: ${REPO_ROOT}/VideoDiffusion/${remote_output_basename}"

if [[ "${MAGI_UPLOAD_TO_R2}" == "1" ]]; then
  if [[ -n "${AGENT_S3_BUCKET:-}" && -n "${AGENT_S3_ENDPOINT:-}" && -n "${AGENT_S3_ACCESS_KEY_ID:-}" && -n "${AGENT_S3_SECRET_ACCESS_KEY:-}" ]]; then
    if [[ ! -x "${REPO_ROOT}/.venv/r2-bootstrap/bin/python" ]]; then
      bash "${REPO_ROOT}/scripts/cloudflare/bootstrap_r2.sh" --dry-run >/dev/null
    fi
    r2_python="${REPO_ROOT}/.venv/r2-bootstrap/bin/python"
    upload_manifest="${local_tmp_dir}/r2_upload_manifest_${RUN_TAG}.json"
    local_video="${REPO_ROOT}/VideoDiffusion/${remote_output_basename}"
    artifact_files=()
    while IFS= read -r artifact_path; do
      if [[ -n "${artifact_path}" ]]; then
        artifact_files+=("${artifact_path}")
      fi
    done < <(
      {
        find "${local_tmp_dir}" -type f \( -name "*${RUN_TAG}*_summary.json" -o -name "*${RUN_TAG}*_script_injection_report.json" -o -name "*${RUN_TAG}*_script_injection_report.csv" -o -name "*${RUN_TAG}*_metrics.json" -o -name "*${RUN_TAG}*_ffprobe.json" -o -name "*${RUN_TAG}*_calibration.json" -o -name "*${RUN_TAG}*_calibration_results.csv" \) 2>/dev/null
        if [[ -f "${local_video}" ]]; then
          echo "${local_video}"
        fi
      } | awk '!seen[$0]++'
    )
    if [[ "${#artifact_files[@]}" -gt 0 ]]; then
      "${r2_python}" - "${R2_PREFIX_RUNTIME}" "${RUN_TAG}" "${upload_manifest}" "${artifact_files[@]}" <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import boto3

prefix = sys.argv[1].strip().strip("/")
run_tag = sys.argv[2].strip()
manifest_path = Path(sys.argv[3]).resolve()
files = [Path(p).resolve() for p in sys.argv[4:] if Path(p).is_file()]
bucket = os.environ["AGENT_S3_BUCKET"]
endpoint = os.environ["AGENT_S3_ENDPOINT"]
region = os.environ.get("AGENT_S3_REGION", "auto")
access_key = os.environ["AGENT_S3_ACCESS_KEY_ID"]
secret_key = os.environ["AGENT_S3_SECRET_ACCESS_KEY"]

s3 = boto3.client(
    "s3",
    endpoint_url=endpoint,
    region_name=region,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
)

uploaded = []
for fp in files:
    h = hashlib.sha256()
    with fp.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    key = "/".join([prefix, "runs", run_tag, fp.name])
    s3.upload_file(str(fp), bucket, key)
    uploaded.append(
        {
            "local_path": str(fp),
            "object_key": key,
            "size_bytes": fp.stat().st_size,
            "sha256": h.hexdigest(),
        }
    )

manifest = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "run_id": run_tag,
    "uploaded_count": len(uploaded),
    "artifacts": uploaded,
}
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
manifest_key = "/".join([prefix, "runs", run_tag, "manifest.json"])
s3.put_object(
    Bucket=bucket,
    Key=manifest_key,
    Body=(json.dumps(manifest, indent=2) + "\n").encode("utf-8"),
    ContentType="application/json",
)
print(json.dumps({"status": "ok", "manifest_key": manifest_key, "count": len(uploaded)}, indent=2))
PY
      echo "[remote] Uploaded run artifacts to R2 prefix ${R2_PREFIX_RUNTIME}/runs/${RUN_TAG}/"
      echo "[remote] R2 upload manifest: ${upload_manifest}"
    else
      echo "[remote] No artifacts found for R2 upload."
    fi
  else
    echo "[remote] AGENT_S3_* credentials not set; skipping R2 upload."
  fi
fi

if [[ "${REMOTE_RUN_RC}" -ne 0 ]]; then
  echo "[error] Remote scripted run failed with exit=${REMOTE_RUN_RC}." >&2
  exit "${REMOTE_RUN_RC}"
fi
