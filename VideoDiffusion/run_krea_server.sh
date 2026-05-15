#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

KREA_RUNTIME_ENV_FILE="${KREA_RUNTIME_ENV_FILE:-${SCRIPT_DIR}/.krea_runtime.env}"
if [[ -f "${KREA_RUNTIME_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${KREA_RUNTIME_ENV_FILE}"
fi

ATTN_BACKEND="$(normalize_attn_backend "${ATTN_BACKEND:-auto}")"
ATTN_BACKEND="$(resolve_attn_backend "${ATTN_BACKEND}")"
KREA_SRC_DIR="${KREA_SRC_DIR:-${SCRIPT_DIR}/.vendors/krea-realtime-video}"
KREA_VENV_DIR="${KREA_VENV_DIR:-${SCRIPT_DIR}/.venv-krea}"
KREA_SERVER_ARGS="${KREA_SERVER_ARGS:-}"

usage() {
  cat <<'EOF'
Usage:
  VIDEO_MODEL=krea ATTN_BACKEND=<auto|sage|flash|sdpa> bash VideoDiffusion/run_krea_server.sh [release_server_args...]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --attn-backend)
      ATTN_BACKEND="$(normalize_attn_backend "$2")"
      ATTN_BACKEND="$(resolve_attn_backend "${ATTN_BACKEND}")"
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

if [[ ! -f "${KREA_SRC_DIR}/release_server.py" ]]; then
  echo "[error] Krea server entrypoint missing: ${KREA_SRC_DIR}/release_server.py" >&2
  echo "[hint] Run bash VideoDiffusion/setup_krea.sh first." >&2
  exit 1
fi

if [[ ! -x "${KREA_VENV_DIR}/bin/python" ]]; then
  echo "[error] Krea venv not found at ${KREA_VENV_DIR}." >&2
  echo "[hint] Run bash VideoDiffusion/setup_krea.sh first." >&2
  exit 1
fi

export HF_HOME="${HF_HOME:-${SCRIPT_DIR}/.cache/huggingface}"
mkdir -p "${HF_HOME}"

case "${ATTN_BACKEND}" in
  sage)
    unset DISABLE_SAGEATTENTION || true
    ;;
  flash|sdpa)
    export DISABLE_SAGEATTENTION=1
    ;;
esac

export KREA_ATTN_BACKEND="${ATTN_BACKEND}"
export PYTHONPATH="${SCRIPT_DIR}/krea_python:${KREA_SRC_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

if [[ -n "${KREA_SERVER_ARGS}" ]]; then
  # shellcheck disable=SC2206
  extra_args=( ${KREA_SERVER_ARGS} )
  set -- "${extra_args[@]}" "$@"
fi

video_log "Starting Krea server: backend=${ATTN_BACKEND}, gpu='$(detect_primary_gpu_name)'."
cd "${KREA_SRC_DIR}"
exec "${KREA_VENV_DIR}/bin/python" "release_server.py" "$@"
