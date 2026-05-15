#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

SCOPE_RUNTIME_ENV_FILE="${SCOPE_RUNTIME_ENV_FILE:-${SCRIPT_DIR}/.scope_runtime.env}"
if [[ -f "${SCOPE_RUNTIME_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${SCOPE_RUNTIME_ENV_FILE}"
fi

SCOPE_SRC_DIR="${SCOPE_SRC_DIR:-${SCRIPT_DIR}/.vendors/daydream-scope}"
SCOPE_PIPELINE="${SCOPE_PIPELINE:-longlive}"
SCOPE_PORT="${SCOPE_PORT:-8000}"
DAYDREAM_SCOPE_MODELS_DIR="${DAYDREAM_SCOPE_MODELS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/models}"
DAYDREAM_SCOPE_LOGS_DIR="${DAYDREAM_SCOPE_LOGS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/logs}"
DAYDREAM_SCOPE_PLUGINS_DIR="${DAYDREAM_SCOPE_PLUGINS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/plugins}"

usage() {
  cat <<'EOF'
Usage:
  VIDEO_MODEL=scope bash VideoDiffusion/run_scope_server.sh [daydream-scope args...]

This launches Daydream Scope. It does not create cloud instances.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ ! -d "${SCOPE_SRC_DIR}" ]]; then
  echo "[error] Scope checkout not found at ${SCOPE_SRC_DIR}." >&2
  echo "[hint] Run bash VideoDiffusion/setup_scope.sh first." >&2
  exit 1
fi

if ! command_exists uv; then
  echo "[error] uv is required to run Scope." >&2
  exit 1
fi

export SCOPE_PORT PIPELINE="${SCOPE_PIPELINE}"
export DAYDREAM_SCOPE_MODELS_DIR DAYDREAM_SCOPE_LOGS_DIR DAYDREAM_SCOPE_PLUGINS_DIR
mkdir -p "${DAYDREAM_SCOPE_MODELS_DIR}" "${DAYDREAM_SCOPE_LOGS_DIR}" "${DAYDREAM_SCOPE_PLUGINS_DIR}"

video_log "Starting Daydream Scope from ${SCOPE_SRC_DIR}."
video_log "Pipeline hint: ${SCOPE_PIPELINE}; HTTP/OSC port: ${SCOPE_PORT}."
cd "${SCOPE_SRC_DIR}"
exec uv run daydream-scope "$@"
