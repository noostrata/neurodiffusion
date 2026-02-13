#!/usr/bin/env bash
# Usage: bash ImageDiffusion/jupyter_tunnel.sh
#
# Creates an SSH local port-forward to the remote Jupyter server.

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
: "${JUPYTER_REMOTE_PORT:=8080}"
: "${JUPYTER_LOCAL_PORT:=9999}"

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

if [[ -n "${JUPYTER_TOKEN:-}" ]]; then
  echo "[local] open: http://localhost:${JUPYTER_LOCAL_PORT}/lab?token=${JUPYTER_TOKEN}"
else
  echo "[local] open: http://localhost:${JUPYTER_LOCAL_PORT}/"
  echo "[local] (set JUPYTER_TOKEN in config/prime.env if you want the full /lab?token=... URL printed)"
fi
echo "[local] press Ctrl+C to stop"

ssh "${SSH_OPTS[@]}" -N -L "${JUPYTER_LOCAL_PORT}:127.0.0.1:${JUPYTER_REMOTE_PORT}" "${REMOTE}"
