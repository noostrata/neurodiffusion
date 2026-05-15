#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

SCOPE_REPO_URL="${SCOPE_REPO_URL:-https://github.com/daydreamlive/scope.git}"
SCOPE_REPO_REF="${SCOPE_REPO_REF:-main}"
SCOPE_SRC_DIR="${SCOPE_SRC_DIR:-${SCRIPT_DIR}/.vendors/daydream-scope}"
SCOPE_RUNTIME_ENV_FILE="${SCOPE_RUNTIME_ENV_FILE:-${SCRIPT_DIR}/.scope_runtime.env}"
SCOPE_PIPELINE="${SCOPE_PIPELINE:-longlive}"
SCOPE_PORT="${SCOPE_PORT:-8000}"
SCOPE_SKIP_BUILD="${SCOPE_SKIP_BUILD:-0}"
DAYDREAM_SCOPE_MODELS_DIR="${DAYDREAM_SCOPE_MODELS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/models}"
DAYDREAM_SCOPE_LOGS_DIR="${DAYDREAM_SCOPE_LOGS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/logs}"
DAYDREAM_SCOPE_PLUGINS_DIR="${DAYDREAM_SCOPE_PLUGINS_DIR:-${SCRIPT_DIR}/.cache/daydream-scope/plugins}"

usage() {
  cat <<'EOF'
Usage:
  bash VideoDiffusion/setup_scope.sh

Environment:
  SCOPE_REPO_URL              Scope git URL
  SCOPE_REPO_REF              Scope git ref (default: main)
  SCOPE_SRC_DIR               Local ignored checkout path
  SCOPE_PIPELINE              Pipeline to prepare (default: longlive)
  SCOPE_PORT                  Scope HTTP/OSC port (default: 8000)
  SCOPE_SKIP_BUILD=1          Clone/write env but skip uv build
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

ensure_scope_checkout() {
  if [[ -d "${SCOPE_SRC_DIR}/.git" ]]; then
    video_log "Updating existing Scope checkout in ${SCOPE_SRC_DIR}."
    git -C "${SCOPE_SRC_DIR}" fetch --all --tags --prune
  else
    video_log "Cloning Scope into ${SCOPE_SRC_DIR}."
    mkdir -p "$(dirname -- "${SCOPE_SRC_DIR}")"
    git clone "${SCOPE_REPO_URL}" "${SCOPE_SRC_DIR}"
  fi

  if git -C "${SCOPE_SRC_DIR}" rev-parse --verify --quiet "${SCOPE_REPO_REF}^{commit}" >/dev/null; then
    git -C "${SCOPE_SRC_DIR}" checkout --force "${SCOPE_REPO_REF}"
  elif git -C "${SCOPE_SRC_DIR}" rev-parse --verify --quiet "origin/${SCOPE_REPO_REF}^{commit}" >/dev/null; then
    git -C "${SCOPE_SRC_DIR}" checkout --force "origin/${SCOPE_REPO_REF}"
  else
    echo "[error] Could not resolve SCOPE_REPO_REF='${SCOPE_REPO_REF}' in ${SCOPE_SRC_DIR}." >&2
    exit 1
  fi
}

write_runtime_env_file() {
  mkdir -p "$(dirname -- "${SCOPE_RUNTIME_ENV_FILE}")"
  mkdir -p "${DAYDREAM_SCOPE_MODELS_DIR}" "${DAYDREAM_SCOPE_LOGS_DIR}" "${DAYDREAM_SCOPE_PLUGINS_DIR}"
  cat > "${SCOPE_RUNTIME_ENV_FILE}" <<EOF
SCOPE_SRC_DIR=${SCOPE_SRC_DIR}
SCOPE_PIPELINE=${SCOPE_PIPELINE}
SCOPE_PORT=${SCOPE_PORT}
DAYDREAM_SCOPE_MODELS_DIR=${DAYDREAM_SCOPE_MODELS_DIR}
DAYDREAM_SCOPE_LOGS_DIR=${DAYDREAM_SCOPE_LOGS_DIR}
DAYDREAM_SCOPE_PLUGINS_DIR=${DAYDREAM_SCOPE_PLUGINS_DIR}
EOF
}

ensure_scope_checkout
write_runtime_env_file

if [[ "${SCOPE_SKIP_BUILD}" == "1" ]]; then
  video_log "SCOPE_SKIP_BUILD=1; skipping uv run build."
else
  if ! command_exists uv; then
    echo "[error] uv is required for Scope local install. Install uv, or rerun with SCOPE_SKIP_BUILD=1 for clone/env only." >&2
    exit 1
  fi
  if ! command_exists npm; then
    echo "[error] npm is required for Scope frontend build. Install Node.js/npm, or rerun with SCOPE_SKIP_BUILD=1." >&2
    exit 1
  fi
  video_log "Running Scope build. This installs Python/Torch/frontend dependencies but does not launch inference."
  (cd "${SCOPE_SRC_DIR}" && uv run build)
fi

video_log "Scope setup prepared for pipeline '${SCOPE_PIPELINE}'."
video_log "Runtime env file written to ${SCOPE_RUNTIME_ENV_FILE}."
video_log "Model/cache dirs are under ${SCRIPT_DIR}/.cache/daydream-scope unless overridden."
