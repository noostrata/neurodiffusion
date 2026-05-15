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

KREA_VENV_DIR="${KREA_VENV_DIR:-${SCRIPT_DIR}/.venv-krea}"
KREA_MODEL_REPO_ID="${KREA_MODEL_REPO_ID:-}"
KREA_MODEL_REVISION="${KREA_MODEL_REVISION:-main}"
KREA_MODEL_CACHE_DIR="${KREA_MODEL_CACHE_DIR:-${SCRIPT_DIR}/.cache/krea}"
KREA_MODEL_LOCAL_DIR="${KREA_MODEL_LOCAL_DIR:-${KREA_MODEL_CACHE_DIR}/models}"
KREA_ALLOW_PATTERNS="${KREA_ALLOW_PATTERNS:-}"

usage() {
  cat <<'EOF'
Usage:
  KREA_MODEL_REPO_ID=<hf_repo_id> bash VideoDiffusion/download_krea_weights.sh [options]

Options:
  --repo-id <repo_id>         Hugging Face repo id for model weights (required if env unset)
  --revision <revision>       HF revision/tag/commit (default: main)
  --cache-dir <path>          Root cache directory for Krea assets
  --local-dir <path>          Explicit local target directory for snapshot
  --allow-patterns <csv>      Optional allow-pattern list (comma-separated)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-id)
      KREA_MODEL_REPO_ID="$2"
      shift 2
      ;;
    --revision)
      KREA_MODEL_REVISION="$2"
      shift 2
      ;;
    --cache-dir)
      KREA_MODEL_CACHE_DIR="$2"
      shift 2
      ;;
    --local-dir)
      KREA_MODEL_LOCAL_DIR="$2"
      shift 2
      ;;
    --allow-patterns)
      KREA_ALLOW_PATTERNS="$2"
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

if [[ -z "${KREA_MODEL_REPO_ID}" ]]; then
  echo "[error] KREA_MODEL_REPO_ID is required." >&2
  echo "[hint] Example: KREA_MODEL_REPO_ID=<your_hf_org>/<model_repo> bash VideoDiffusion/download_krea_weights.sh" >&2
  exit 1
fi

if [[ ! -x "${KREA_VENV_DIR}/bin/python" ]]; then
  echo "[error] Krea venv not found at ${KREA_VENV_DIR}. Run VideoDiffusion/setup_krea.sh first." >&2
  exit 1
fi

mkdir -p "${KREA_MODEL_CACHE_DIR}" "${KREA_MODEL_LOCAL_DIR}"

video_log "Downloading Krea weights from ${KREA_MODEL_REPO_ID}@${KREA_MODEL_REVISION}."
"${KREA_VENV_DIR}/bin/python" - "${KREA_MODEL_REPO_ID}" "${KREA_MODEL_REVISION}" "${KREA_MODEL_CACHE_DIR}" "${KREA_MODEL_LOCAL_DIR}" "${KREA_ALLOW_PATTERNS}" <<'PY'
import os
import sys
from huggingface_hub import snapshot_download

repo_id, revision, cache_dir, local_dir, allow_patterns_raw = sys.argv[1:]
allow_patterns = [x.strip() for x in allow_patterns_raw.split(",") if x.strip()]

kwargs = {
    "repo_id": repo_id,
    "revision": revision,
    "cache_dir": cache_dir,
    "local_dir": local_dir,
    "local_dir_use_symlinks": False,
}
if allow_patterns:
    kwargs["allow_patterns"] = allow_patterns

if os.environ.get("HUGGING_FACE_HUB_TOKEN"):
    kwargs["token"] = os.environ["HUGGING_FACE_HUB_TOKEN"]
elif os.environ.get("HF_TOKEN"):
    kwargs["token"] = os.environ["HF_TOKEN"]

path = snapshot_download(**kwargs)
print(path)
PY

video_log "Krea weights synced under ${KREA_MODEL_LOCAL_DIR}."
