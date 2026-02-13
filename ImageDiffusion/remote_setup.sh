#!/usr/bin/env bash
# Usage: bash ImageDiffusion/remote_setup.sh
#
# Copies setup files to the pod and runs the one-time dependency install remotely.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${PRIME_CONFIG_FILE:-${REPO_ROOT}/config/prime.env}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

if ! SSH_ENV="$("${REPO_ROOT}/scripts/prime/resolve_ssh.sh")"; then
  echo "ERROR: failed to resolve pod SSH info (is the pod ACTIVE?)" 1>&2
  exit 1
fi
eval "${SSH_ENV}"

: "${PRIME_SSH_KEY_PATH:=${HOME}/.ssh/id_rsa}"
: "${PRIME_STRICT_HOST_KEY_CHECKING:=accept-new}"
: "${PRIME_REMOTE_WORKDIR:=~/neurodiffusion}"

if [[ ! -f "${PRIME_SSH_KEY_PATH}" ]]; then
  echo "ERROR: SSH key not found at PRIME_SSH_KEY_PATH=${PRIME_SSH_KEY_PATH}" 1>&2
  exit 1
fi

REMOTE="${PRIME_SSH_USER}@${PRIME_SSH_HOST}"

SSH_OPTS=(
  -p "${PRIME_SSH_PORT}"
  -i "${PRIME_SSH_KEY_PATH}"
  -o "StrictHostKeyChecking=${PRIME_STRICT_HOST_KEY_CHECKING}"
  -o "PasswordAuthentication=no"
)

SCP_OPTS=(
  -P "${PRIME_SSH_PORT}"
  -i "${PRIME_SSH_KEY_PATH}"
  -o "StrictHostKeyChecking=${PRIME_STRICT_HOST_KEY_CHECKING}"
  -o "PasswordAuthentication=no"
)

echo "[remote] ensuring workdir exists: ${PRIME_REMOTE_WORKDIR}"
ssh "${SSH_OPTS[@]}" "${REMOTE}" "mkdir -p ${PRIME_REMOTE_WORKDIR}"

echo "[local] copying setup files -> ${REMOTE}:${PRIME_REMOTE_WORKDIR}/"
scp "${SCP_OPTS[@]}" \
  "${SCRIPT_DIR}/setup.sh" \
  "${SCRIPT_DIR}/requirements.txt" \
  "${REMOTE}:${PRIME_REMOTE_WORKDIR}/"

echo "[remote] running setup (logs will print in this terminal)"
ssh "${SSH_OPTS[@]}" "${REMOTE}" "cd ${PRIME_REMOTE_WORKDIR} && bash setup.sh"
