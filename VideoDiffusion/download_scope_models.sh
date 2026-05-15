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
DAYDREAM_SCOPE_MODELS_DIR="${DAYDREAM_SCOPE_MODELS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/models}"
DAYDREAM_SCOPE_LOGS_DIR="${DAYDREAM_SCOPE_LOGS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/logs}"
DAYDREAM_SCOPE_PLUGINS_DIR="${DAYDREAM_SCOPE_PLUGINS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/plugins}"

if [[ ! -d "${SCOPE_SRC_DIR}" ]]; then
  echo "[error] Scope checkout not found at ${SCOPE_SRC_DIR}." >&2
  echo "[hint] Run bash VideoDiffusion/setup_scope.sh first." >&2
  exit 1
fi

if ! command_exists uv; then
  echo "[error] uv is required to run Scope model downloads." >&2
  exit 1
fi

export DAYDREAM_SCOPE_MODELS_DIR DAYDREAM_SCOPE_LOGS_DIR DAYDREAM_SCOPE_PLUGINS_DIR
mkdir -p "${DAYDREAM_SCOPE_MODELS_DIR}" "${DAYDREAM_SCOPE_LOGS_DIR}" "${DAYDREAM_SCOPE_PLUGINS_DIR}"

video_log "Downloading Scope models for pipeline '${SCOPE_PIPELINE}'."
cd "${SCOPE_SRC_DIR}"
exec uv run download_models --pipeline "${SCOPE_PIPELINE}"
