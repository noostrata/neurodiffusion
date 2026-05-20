#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

VIDEO_MODEL="${VIDEO_MODEL:-magi}"
ATTN_BACKEND="${ATTN_BACKEND:-auto}"

usage() {
  cat <<'EOF'
Usage:
  VIDEO_MODEL=<magi|krea|scope|longlive|longlive2> ATTN_BACKEND=<auto|sage|flash|sdpa> bash VideoDiffusion/run_video_stream.sh [args...]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      VIDEO_MODEL="$2"
      shift 2
      ;;
    --attn-backend)
      ATTN_BACKEND="$2"
      shift 2
      ;;
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

VIDEO_MODEL="$(normalize_video_model "${VIDEO_MODEL}")"
ATTN_BACKEND="$(normalize_attn_backend "${ATTN_BACKEND}")"

if [[ "${VIDEO_MODEL}" == "magi" ]]; then
  PYTHON_BIN="${SCRIPT_DIR}/.venv/bin/python"
  if [[ ! -x "${PYTHON_BIN}" ]]; then
    PYTHON_BIN="python3"
  fi
  video_log "Launching MAGI realtime stream with ${PYTHON_BIN}."
  exec "${PYTHON_BIN}" "${SCRIPT_DIR}/realtime_magi_stream.py" "$@"
fi

if [[ "${VIDEO_MODEL}" == "scope" ]]; then
  video_log "Launching Daydream Scope server for LongLive."
  exec bash "${SCRIPT_DIR}/run_scope_server.sh" "$@"
fi

if [[ "${VIDEO_MODEL}" == "longlive2" ]]; then
  video_log "Launching LongLive2 offline/SP runner."
  exec bash "${SCRIPT_DIR}/run_longlive2_sp_offline.sh" "$@"
fi

video_log "Launching Krea realtime stream with attention policy '${ATTN_BACKEND}'."
ATTN_BACKEND="${ATTN_BACKEND}" exec bash "${SCRIPT_DIR}/run_krea_server.sh" "$@"
