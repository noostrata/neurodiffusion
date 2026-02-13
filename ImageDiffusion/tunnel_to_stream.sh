#!/usr/bin/env bash
# Usage: bash ImageDiffusion/tunnel_to_stream.sh
#
# Creates an SSH local port-forward so you can open the stream locally.

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
: "${IMAGE_REMOTE_PORT:=8000}"
: "${IMAGE_LOCAL_PORT:=8888}"

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

echo "[local] starting tunnel: http://localhost:${IMAGE_LOCAL_PORT}/ -> ${REMOTE}:localhost:${IMAGE_REMOTE_PORT}"
echo "[local] press Ctrl+C to stop"

ssh "${SSH_OPTS[@]}" -N -L "${IMAGE_LOCAL_PORT}:127.0.0.1:${IMAGE_REMOTE_PORT}" "${REMOTE}"
