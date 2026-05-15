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
  bash VideoDiffusion/setup_video_runtime.sh [options]

Options:
  --model <magi|krea|scope|longlive>
                                   Video model runtime to setup (default: $VIDEO_MODEL)
  --attn-backend <auto|sage|flash|sdpa>
                                   Attention backend policy (default: $ATTN_BACKEND)
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
    *)
      echo "[error] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

VIDEO_MODEL="$(normalize_video_model "${VIDEO_MODEL}")"
ATTN_BACKEND="$(normalize_attn_backend "${ATTN_BACKEND}")"

if [[ "${VIDEO_MODEL}" == "magi" ]]; then
  video_log "Dispatching MAGI setup (existing flow)."
  bash "${SCRIPT_DIR}/setup.sh"
  exit 0
fi

if [[ "${VIDEO_MODEL}" == "scope" ]]; then
  video_log "Dispatching Daydream Scope + LongLive setup."
  bash "${SCRIPT_DIR}/setup_scope.sh"
  exit 0
fi

video_log "Dispatching Krea setup with attention policy '${ATTN_BACKEND}'."
ATTN_BACKEND="${ATTN_BACKEND}" bash "${SCRIPT_DIR}/setup_krea.sh"
