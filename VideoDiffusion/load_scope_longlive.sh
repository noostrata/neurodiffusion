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

SCOPE_PORT="${SCOPE_PORT:-8000}"
SCOPE_BASE_URL="${SCOPE_BASE_URL:-http://127.0.0.1:${SCOPE_PORT}}"
SCOPE_HEIGHT="${SCOPE_HEIGHT:-320}"
SCOPE_WIDTH="${SCOPE_WIDTH:-576}"
SCOPE_SEED="${SCOPE_SEED:-42}"
SCOPE_VAE_TYPE="${SCOPE_VAE_TYPE:-wan}"
SCOPE_VACE_ENABLED="${SCOPE_VACE_ENABLED:-false}"
SCOPE_WAIT_TIMEOUT_S="${SCOPE_WAIT_TIMEOUT_S:-300}"

video_log "Requesting LongLive load at ${SCOPE_BASE_URL}."
exec python3 "${SCRIPT_DIR}/scope_pipeline.py" \
  --base-url "${SCOPE_BASE_URL}" \
  --timeout-s "${SCOPE_WAIT_TIMEOUT_S}" \
  load-longlive \
  --height "${SCOPE_HEIGHT}" \
  --width "${SCOPE_WIDTH}" \
  --seed "${SCOPE_SEED}" \
  --vae-type "${SCOPE_VAE_TYPE}" \
  --vace-enabled "${SCOPE_VACE_ENABLED}" \
  --wait \
  --poll-s 1.0
