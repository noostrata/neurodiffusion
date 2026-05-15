#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUNTIME_TAG="${MAGI_VAST_RUNTIME_TAG:-hopper_sm80_py310_torch240_cu124_20260217_prebuild1}"
TIER="${MAGI_VAST_TIER:-4.5b}"
REMOTE_ROOT="${MAGI_VAST_REMOTE_ROOT:-/workspace/neurodiffusion}"
REMOTE_VIDEO_DIR="${REMOTE_ROOT}/VideoDiffusion"
REMOTE_R2_ENV="${REMOTE_ROOT}/.secrets/r2_full_access.env"
R2_ENV_FILE="${R2_ENV_FILE:-/Users/xenochain/agents/secrets/r2_full_access.env}"
LOCAL_OUT_DIR="${MAGI_VAST_LOCAL_OUT_DIR:-${HOME}/Downloads/neurodiffusion_magi_smoke_$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT_FILE="${MAGI_VAST_OUTPUT:-magi_vast_smoke_24f.mp4}"
PROMPT="${MAGI_VAST_PROMPT:-Slow dolly shot through a busy cyberpunk alley at night, neon signs flickering, light rain, passing cars and pedestrians moving}"
TIMEOUT_S="${MAGI_VAST_TIMEOUT_S:-3600}"
POLL_S="${MAGI_VAST_POLL_S:-30}"
DESTROY_ON_EXIT="${MAGI_VAST_DESTROY_ON_EXIT:-0}"
SSH_READY_TIMEOUT_S="${MAGI_VAST_SSH_READY_TIMEOUT_S:-180}"

SSH_KEY_PATH="${VAST_SSH_KEY_PATH:-${HOME}/.ssh/vast_neurodiffusion_rsa}"

usage() {
  cat <<EOF
Usage:
  VAST_INSTANCE_ID=<id> bash VideoDiffusion/run_magi_vast_smoke.sh

Environment:
  MAGI_VAST_RUNTIME_TAG        R2 runtime tag (default: ${RUNTIME_TAG})
  MAGI_VAST_LOCAL_OUT_DIR      Local pullback dir (default: ~/Downloads/neurodiffusion_magi_smoke_<utc>)
  MAGI_VAST_OUTPUT             Remote/local MP4 name (default: ${OUTPUT_FILE})
  MAGI_VAST_DESTROY_ON_EXIT    Destroy VAST_INSTANCE_ID when finished (default: 0)
  VIDEO_MAGE_T5_DEVICE         T5 embedding device for smoke (default: cuda)
  OFFLOAD_T5_CACHE             Avoid keeping T5 cached after embeddings (default: true)
EOF
}

runtime_gpu_regex() {
  case "$1" in
    *sm80*) printf 'A100' ;;
    *sm86*) printf 'A6000|RTX.?6000' ;;
    *sm89*) printf 'L40S|RTX.?4090' ;;
    *sm90*) printf 'H100|H200|GH200' ;;
    *sm100*) printf 'B200' ;;
    *) printf '' ;;
  esac
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

remote_scp_from() {
  scp -i "${SSH_KEY_PATH}" \
    -P "${VAST_SSH_PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    "${VAST_SSH_USER}@${VAST_SSH_HOST}:$1" "$2"
}

ensure_remote_system_deps() {
  remote_ssh "set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
need_apt=0
py_inc=\"/usr/include/python\$(python3 - <<'PY'
import sys
print(f'{sys.version_info.major}.{sys.version_info.minor}')
PY
)/Python.h\"
if [[ ! -f \"\${py_inc}\" ]]; then need_apt=1; fi
if ! command -v ffmpeg >/dev/null 2>&1; then need_apt=1; fi
if ! command -v gcc >/dev/null 2>&1; then need_apt=1; fi
if [[ \"\${need_apt}\" == \"0\" ]]; then
  echo '[magi-vast] system deps already present'
  exit 0
fi
for _ in \$(seq 1 90); do
  if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x dpkg >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends build-essential python3-dev python3-venv python3-pip ffmpeg >/dev/null
echo '[magi-vast] system deps installed'
"
}

wait_for_ssh_auth() {
  local deadline=$((SECONDS + SSH_READY_TIMEOUT_S))
  local last_rc=0
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if remote_ssh "true" >/dev/null 2>&1; then
      return 0
    fi
    last_rc=$?
    echo "[magi-vast] waiting for SSH auth (last_rc=${last_rc})" >&2
    sleep 5
  done
  echo "[error] SSH auth did not become ready within ${SSH_READY_TIMEOUT_S}s." >&2
  return "${last_rc}"
}

cleanup_remote_secret() {
  if [[ -n "${VAST_SSH_HOST:-}" ]]; then
    remote_ssh "rm -f '${REMOTE_R2_ENV}'; rmdir '${REMOTE_ROOT}/.secrets' 2>/dev/null || true" >/dev/null 2>&1 || true
  fi
}

destroy_instance_if_requested() {
  if [[ "${DESTROY_ON_EXIT}" == "1" && -n "${VAST_INSTANCE_ID:-}" ]]; then
    VAST_INSTANCE_ID="${VAST_INSTANCE_ID}" bash "${REPO_ROOT}/scripts/vast/terminate_instance.sh" || true
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${VAST_INSTANCE_ID:-}" ]]; then
  echo "[error] VAST_INSTANCE_ID is required." >&2
  usage >&2
  exit 1
fi
if [[ ! -f "${R2_ENV_FILE}" ]]; then
  echo "[error] R2 env file not found: ${R2_ENV_FILE}" >&2
  exit 1
fi
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  echo "[error] Vast SSH key not found: ${SSH_KEY_PATH}" >&2
  exit 1
fi

trap 'cleanup_remote_secret; destroy_instance_if_requested' EXIT

cd "${REPO_ROOT}"
eval "$(VAST_INSTANCE_ID="${VAST_INSTANCE_ID}" bash scripts/vast/resolve_ssh.sh)"
VAST_SSH_KEY_PATH="${SSH_KEY_PATH}"

wait_for_ssh_auth

gpu_name="$(remote_ssh "nvidia-smi --query-gpu=name --format=csv,noheader | head -n1")"
compat_rx="$(runtime_gpu_regex "${RUNTIME_TAG}")"
if [[ -n "${compat_rx}" ]] && ! [[ "${gpu_name}" =~ ${compat_rx} ]]; then
  echo "[error] Runtime tag '${RUNTIME_TAG}' expects GPU regex '${compat_rx}', but instance GPU is '${gpu_name}'." >&2
  echo "[error] Select a compatible offer or publish/restore a runtime tuple for this GPU architecture." >&2
  exit 1
fi

echo "[magi-vast] runtime_tag=${RUNTIME_TAG}"
echo "[magi-vast] remote_gpu=${gpu_name}"
echo "[magi-vast] syncing repo to ${REMOTE_ROOT}"
remote_ssh "mkdir -p '${REMOTE_ROOT}' '${REMOTE_ROOT}/.secrets'"
rsync -az \
  --exclude '.git' \
  --exclude 'VideoDiffusion/MAGI-1' \
  --exclude 'VideoDiffusion/.venv' \
  --exclude 'VideoDiffusion/.tmp' \
  --exclude 'VideoDiffusion/*.mp4' \
  --exclude 'ImageDiffusion/.venv' \
  --exclude '__pycache__' \
  -e "ssh -i ${SSH_KEY_PATH} -p ${VAST_SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
  "${REPO_ROOT}/" "${VAST_SSH_USER}@${VAST_SSH_HOST}:${REMOTE_ROOT}/"

ensure_remote_system_deps

scp -i "${SSH_KEY_PATH}" \
  -P "${VAST_SSH_PORT}" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  "${R2_ENV_FILE}" "${VAST_SSH_USER}@${VAST_SSH_HOST}:${REMOTE_R2_ENV}"
remote_ssh "chmod 600 '${REMOTE_R2_ENV}'"

echo "[magi-vast] restoring R2 tuple"
remote_ssh "set -euo pipefail; cd '${REMOTE_ROOT}'; R2_ENV_FILE='${REMOTE_R2_ENV}' R2_PREFIX=neurodiffusion bash VideoDiffusion/restore_r2_prebuild.sh --mode tuple --runtime-tag '${RUNTIME_TAG}' --tier '${TIER}' --apply-venv-target '${REMOTE_VIDEO_DIR}/.venv' --apply-weights-target '${REMOTE_VIDEO_DIR}/MAGI-1' 2>&1 | tee '${REMOTE_VIDEO_DIR}/.tmp_magi_vast_restore.log'"

run_id="magi_vast_smoke_$(date -u +%Y%m%dT%H%M%SZ)"
remote_log="${REMOTE_VIDEO_DIR}/.tmp_${run_id}.log"
remote_rc="${REMOTE_VIDEO_DIR}/.tmp_${run_id}.rc"
remote_pid="${REMOTE_VIDEO_DIR}/.tmp_${run_id}.pid"

echo "[magi-vast] starting detached smoke run"
inner_cmd="$(
  printf 'set +e; cd %q; VIDEO_MAGE_T5_DEVICE="${VIDEO_MAGE_T5_DEVICE:-cuda}" OFFLOAD_T5_CACHE="${OFFLOAD_T5_CACHE:-true}" VIDEO_MAGE_PROMPT=%q VIDEO_MAGE_OUTPUT=%q VIDEO_MAGE_FP8=0 VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_config.json VIDEO_MAGE_VISIBLE_DEVICES=0 VIDEO_MAGE_NPROC=1 VIDEO_MAGE_NUM_FRAMES=24 VIDEO_MAGE_NUM_STEPS=8 VIDEO_MAGE_WINDOW_SIZE=1 VIDEO_MAGE_VIDEO_SIZE_H=384 VIDEO_MAGE_VIDEO_SIZE_W=384 bash ./test_single_chunk.sh; rc=$?; echo $rc > %q; exit $rc' \
    "${REMOTE_VIDEO_DIR}" "${PROMPT}" "${OUTPUT_FILE}" "${remote_rc}"
)"
remote_ssh "set -euo pipefail; cd '${REMOTE_VIDEO_DIR}'; rm -f '${OUTPUT_FILE}' '${remote_log}' '${remote_rc}' '${remote_pid}'; nohup bash -lc $(printf '%q' "${inner_cmd}") > '${remote_log}' 2>&1 < /dev/null & echo \$! > '${remote_pid}'"

deadline=$((SECONDS + TIMEOUT_S))
while true; do
  status="$(remote_ssh "set +e; if [[ -f '${remote_rc}' ]]; then cat '${remote_rc}'; elif kill -0 \"\$(cat '${remote_pid}' 2>/dev/null)\" 2>/dev/null; then echo running; else echo missing; fi")"
  remote_ssh "tail -40 '${remote_log}' 2>/dev/null || true"
  if [[ "${status}" =~ ^[0-9]+$ ]]; then
    if [[ "${status}" != "0" ]]; then
      echo "[error] MAGI smoke failed with rc=${status}" >&2
      break
    fi
    echo "[magi-vast] smoke completed"
    break
  fi
  if [[ "${SECONDS}" -ge "${deadline}" ]]; then
    echo "[error] MAGI smoke timed out after ${TIMEOUT_S}s" >&2
    remote_ssh "pkill -TERM -f 'inference/pipeline/entry.py' || true"
    status="124"
    break
  fi
  sleep "${POLL_S}"
done

mkdir -p "${LOCAL_OUT_DIR}"
remote_scp_from "${remote_log}" "${LOCAL_OUT_DIR}/${run_id}.log" || true
remote_scp_from "${REMOTE_VIDEO_DIR}/.tmp_magi_vast_restore.log" "${LOCAL_OUT_DIR}/${run_id}_restore.log" || true
if remote_ssh "test -f '${REMOTE_VIDEO_DIR}/${OUTPUT_FILE}'"; then
  remote_scp_from "${REMOTE_VIDEO_DIR}/${OUTPUT_FILE}" "${LOCAL_OUT_DIR}/${OUTPUT_FILE}"
  ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames,duration \
    -of default=noprint_wrappers=1 "${LOCAL_OUT_DIR}/${OUTPUT_FILE}" || true
  echo "[magi-vast] local_output=${LOCAL_OUT_DIR}/${OUTPUT_FILE}"
fi

if [[ "${status}" != "0" ]]; then
  exit "${status}"
fi
