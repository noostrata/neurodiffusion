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
REMOTE_BOOTSTRAP="${MAGI_REMOTE_BOOTSTRAP:-1}"
REMOTE_SKIP_DOWNLOAD="${MAGI_REMOTE_SKIP_DOWNLOAD:-0}"

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
REMOTE="${PRIME_SSH_USER:-root}@${PRIME_SSH_HOST:-}"
SSH_OPTS=(
  -i "${PRIME_SSH_KEY_PATH/#\~/$HOME}"
  -p "${PRIME_SSH_PORT:-22}"
  -o "StrictHostKeyChecking=${STRICT_HOST}"
  -o "UserKnownHostsFile=${USER_KNOWN_HOSTS_FILE}"
  -o "GlobalKnownHostsFile=${GLOBAL_KNOWN_HOSTS_FILE}"
)
SCP_OPTS=(
  -i "${PRIME_SSH_KEY_PATH/#\~/$HOME}"
  -P "${PRIME_SSH_PORT:-22}"
  -o "StrictHostKeyChecking=${STRICT_HOST}"
  -o "UserKnownHostsFile=${USER_KNOWN_HOSTS_FILE}"
  -o "GlobalKnownHostsFile=${GLOBAL_KNOWN_HOSTS_FILE}"
)

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

SCHEDULE_REL="$(resolve_rel_path "${SCHEDULE_CSV}")"

eval "$("${REPO_ROOT}/scripts/prime/resolve_ssh.sh")"
REMOTE="${PRIME_SSH_USER}@${PRIME_SSH_HOST}"

sync_archive="$(mktemp /tmp/neurodiffusion_sync.XXXXXX.tar.gz)"
trap 'rm -f "${sync_archive}"' EXIT

tar -czf "${sync_archive}" \
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
scp "${SCP_OPTS[@]}" "${sync_archive}" "${REMOTE}:${remote_archive}"

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

if [[ "${MAGI_TIER}" == "24b" ]]; then
  REMOTE_WEIGHT_VARIANT="${MAGI_REMOTE_WEIGHT_VARIANT:-24B_distill_quant}"
else
  REMOTE_WEIGHT_VARIANT="${MAGI_REMOTE_WEIGHT_VARIANT:-4.5B_distill_quant}"
fi
weight_variant_q="$(python3 - "${REMOTE_WEIGHT_VARIANT}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"

if [[ "${REMOTE_BOOTSTRAP}" == "1" ]]; then
  echo "[remote] Bootstrapping dependencies on pod ${PRIME_POD_ID}..."
  APT_WAIT_MAX_S="${MAGI_REMOTE_APT_WAIT_MAX_S:-300}"
  apt_wait_q="$(python3 - "${APT_WAIT_MAX_S}" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
  if [[ "${REMOTE_SKIP_DOWNLOAD}" == "1" ]]; then
    ssh "${SSH_OPTS[@]}" "${REMOTE}" \
      "REMOTE_WORKDIR=${remote_workdir_abs_q} APT_WAIT_MAX_S=${apt_wait_q} bash -lc 'set -euo pipefail; waited=0; while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; do if [ \"\${waited}\" -ge \"\${APT_WAIT_MAX_S}\" ]; then break; fi; sleep 2; waited=\$((waited+2)); done; cd \"\${REMOTE_WORKDIR}/VideoDiffusion\"; bash setup.sh'"
  else
    ssh "${SSH_OPTS[@]}" "${REMOTE}" \
      "REMOTE_WORKDIR=${remote_workdir_abs_q} VIDEO_MAGE_WEIGHT_VARIANT=${weight_variant_q} APT_WAIT_MAX_S=${apt_wait_q} bash -lc 'set -euo pipefail; waited=0; while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; do if [ \"\${waited}\" -ge \"\${APT_WAIT_MAX_S}\" ]; then break; fi; sleep 2; waited=\$((waited+2)); done; cd \"\${REMOTE_WORKDIR}/VideoDiffusion\"; bash setup.sh; bash download_weights.sh'"
  fi
fi

echo "[remote] Running MAGI scripted test on pod ${PRIME_POD_ID} (tier=${MAGI_TIER}, devices=${REMOTE_CUDA_VISIBLE_DEVICES})..."
ssh "${SSH_OPTS[@]}" "${REMOTE}" \
  "REMOTE_WORKDIR=${remote_workdir_abs_q} MAGI_TIER=${tier_q} BUDGET_USD=${budget_q} HOURLY_RATE_USD=${rate_q} CUDA_VISIBLE_DEVICES=${devices_q} SCHEDULE_CSV=${schedule_q} SCRIPTED_RUN_TAG=${run_tag_q} bash -lc 'set -euo pipefail; cd \"\${REMOTE_WORKDIR}\"; VIDEO_SCRIPTED_OUTPUT=\"\${REMOTE_WORKDIR}/VideoDiffusion/magi_scripted_30s_${RUN_TAG}.mp4\" bash VideoDiffusion/run_scripted_30s_prime.sh --mode in-pod --tier \"\${MAGI_TIER}\" --budget-usd \"\${BUDGET_USD}\" --hourly-rate-usd \"\${HOURLY_RATE_USD}\" --devices \"\${CUDA_VISIBLE_DEVICES}\" --schedule-csv \"\${SCHEDULE_CSV}\" --run-tag \"\${SCRIPTED_RUN_TAG}\"'"

local_tmp_dir="${REPO_ROOT}/VideoDiffusion/.tmp/remote_${RUN_TAG}"
mkdir -p "${local_tmp_dir}"

set +e
scp "${SCP_OPTS[@]}" -r "${REMOTE}:${REMOTE_WORKDIR}/VideoDiffusion/.tmp/" "${local_tmp_dir}/" >/dev/null 2>&1
scp "${SCP_OPTS[@]}" "${REMOTE}:${REMOTE_WORKDIR}/VideoDiffusion/magi_scripted_30s_${RUN_TAG}.mp4" "${REPO_ROOT}/VideoDiffusion/" >/dev/null 2>&1
set -e

summary_path="$(
  find "${local_tmp_dir}" -type f -name "*${RUN_TAG}*_summary.json" | head -n1 || true
)"

echo "[remote] Artifact sync attempted."
echo "[remote] Local tmp dir: ${local_tmp_dir}"
if [[ -n "${summary_path}" ]]; then
  echo "[remote] Local summary: ${summary_path}"
fi
echo "[remote] Expected local video: ${REPO_ROOT}/VideoDiffusion/magi_scripted_30s_${RUN_TAG}.mp4"
