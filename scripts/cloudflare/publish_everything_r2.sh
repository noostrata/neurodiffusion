#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

R2_ENV_FILE="${R2_ENV_FILE:-/Users/xenochain/agents/secrets/r2_full_access.env}"
if [[ -f "${R2_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${R2_ENV_FILE}"
fi

R2_PREFIX="${R2_PREFIX:-neurodiffusion}"
R2_BOOTSTRAP_VENV="${R2_BOOTSTRAP_VENV:-${REPO_ROOT}/.venv/r2-bootstrap}"

BUNDLE_TAG="${BUNDLE_TAG:-}"
RUNTIME_TAG="${RUNTIME_TAG:-}"
VIDEO_MODEL="${VIDEO_MODEL:-magi}"     # magi|krea|scope
ATTN_BACKEND="${ATTN_BACKEND:-auto}"   # auto|sage|flash|sdpa
TIERS="${TIERS:-}"
PUBLISH_PREBUILD="${PUBLISH_PREBUILD:-always}"  # always|auto|never
INCLUDE_WEIGHTS="${INCLUDE_WEIGHTS:-0}"
INCLUDE_IMAGE="${INCLUDE_IMAGE:-0}"
IMAGE_ARCHIVE="${IMAGE_ARCHIVE:-}"
PURGE_LOCAL_AFTER_UPLOAD="${PURGE_LOCAL_AFTER_UPLOAD:-0}"
ALLOW_MISSING_ENV="${ALLOW_MISSING_ENV:-1}"
ALLOW_MISSING_WEIGHTS="${ALLOW_MISSING_WEIGHTS:-1}"
ALLOW_MISSING_IMAGE="${ALLOW_MISSING_IMAGE:-1}"
R2_ENV_ARCHIVE_COMPRESSION="${R2_ENV_ARCHIVE_COMPRESSION:-gzip}"
R2_WEIGHTS_ARCHIVE_COMPRESSION="${R2_WEIGHTS_ARCHIVE_COMPRESSION:-gzip}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/cloudflare/publish_everything_r2.sh [options]

Options:
  --bundle-tag <tag>             Override code bundle tag
  --runtime-tag <tag>            Runtime tuple tag override
  --video-model <magi|krea|scope|longlive>
                                  Runtime model selector (default: magi)
  --attn-backend <mode>          Attention backend hint for krea (auto|sage|flash|sdpa)
  --prefix <prefix>              R2 root prefix (default: neurodiffusion)
  --tiers <csv>                  Supported tiers metadata (model-default when omitted)
  --publish-prebuild <mode>      always|auto|never (default: always)
  --include-weights              Include weights archive in runtime tuple
  --include-image                Include runtime image archive in runtime tuple
  --image-archive <path>         Runtime image archive (.tar/.tar.gz/.tar.zst)
  --purge-local-after-upload     Remove local non-code artifacts after successful publish
  --allow-missing-env            Allow missing VideoDiffusion/.venv
  --allow-missing-weights        Allow missing weights directory
  --allow-missing-image          Allow missing image archive
  --env-compression <mode>       gzip|zstd|none for non-MAGI env archives
  --weights-compression <mode>   gzip|zstd|none for non-MAGI weights/cache archives
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-tag)
      BUNDLE_TAG="$2"
      shift 2
      ;;
    --runtime-tag)
      RUNTIME_TAG="$2"
      shift 2
      ;;
    --video-model)
      VIDEO_MODEL="$2"
      shift 2
      ;;
    --attn-backend)
      ATTN_BACKEND="$2"
      shift 2
      ;;
    --prefix)
      R2_PREFIX="$2"
      shift 2
      ;;
    --tiers)
      TIERS="$2"
      shift 2
      ;;
    --publish-prebuild)
      PUBLISH_PREBUILD="$2"
      shift 2
      ;;
    --include-weights)
      INCLUDE_WEIGHTS="1"
      shift
      ;;
    --include-image)
      INCLUDE_IMAGE="1"
      shift
      ;;
    --image-archive)
      IMAGE_ARCHIVE="$2"
      shift 2
      ;;
    --purge-local-after-upload)
      PURGE_LOCAL_AFTER_UPLOAD="1"
      shift
      ;;
    --allow-missing-env)
      ALLOW_MISSING_ENV="1"
      shift
      ;;
    --allow-missing-weights)
      ALLOW_MISSING_WEIGHTS="1"
      shift
      ;;
    --allow-missing-image)
      ALLOW_MISSING_IMAGE="1"
      shift
      ;;
    --env-compression)
      R2_ENV_ARCHIVE_COMPRESSION="$2"
      shift 2
      ;;
    --weights-compression)
      R2_WEIGHTS_ARCHIVE_COMPRESSION="$2"
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

case "${VIDEO_MODEL}" in
  longlive)
    VIDEO_MODEL="scope"
    ;;
  magi|krea|scope) ;;
  *)
    echo "[error] --video-model must be magi, krea, scope, or longlive (got ${VIDEO_MODEL})." >&2
    exit 1
    ;;
esac

case "${ATTN_BACKEND}" in
  auto|sage|flash|sdpa) ;;
  *)
    echo "[error] --attn-backend must be auto|sage|flash|sdpa (got ${ATTN_BACKEND})." >&2
    exit 1
    ;;
esac

if [[ -z "${TIERS}" ]]; then
  if [[ "${VIDEO_MODEL}" == "krea" ]]; then
    TIERS="krea-b200-flashattn,krea-hopper-sage,krea-ampere-sage-or-sdpa"
  elif [[ "${VIDEO_MODEL}" == "scope" ]]; then
    TIERS="scope-longlive-24gb,scope-longlive-hopper"
  else
    TIERS="4.5b,24b"
  fi
fi

if [[ -z "${AGENT_S3_BUCKET:-}" || -z "${AGENT_S3_ENDPOINT:-}" || -z "${AGENT_S3_ACCESS_KEY_ID:-}" || -z "${AGENT_S3_SECRET_ACCESS_KEY:-}" ]]; then
  echo "[error] Missing AGENT_S3_* vars. Source ${R2_ENV_FILE} first." >&2
  exit 1
fi

echo "[r2] bootstrap layout..."
bash "${SCRIPT_DIR}/bootstrap_r2.sh" --prefix "${R2_PREFIX}"

if [[ ! -x "${R2_BOOTSTRAP_VENV}/bin/python" ]]; then
  echo "[error] R2 helper python not found: ${R2_BOOTSTRAP_VENV}/bin/python" >&2
  exit 1
fi
PYTHON_BIN="${R2_BOOTSTRAP_VENV}/bin/python"

echo "[r2] publish repo code bundle..."
PUBLISH_CODE_ARGS=(
  "${SCRIPT_DIR}/publish_repo_bundle.py"
  --prefix "${R2_PREFIX}"
  publish
  --repo-root "${REPO_ROOT}"
)
if [[ -n "${BUNDLE_TAG}" ]]; then
  PUBLISH_CODE_ARGS+=(--bundle-tag "${BUNDLE_TAG}")
fi
"${PYTHON_BIN}" "${PUBLISH_CODE_ARGS[@]}"

case "${VIDEO_MODEL}" in
  krea)
    VD_VENV="${REPO_ROOT}/VideoDiffusion/.venv-krea"
    VD_WEIGHTS="${REPO_ROOT}/VideoDiffusion/.cache/krea"
    ;;
  scope)
    VD_VENV="${REPO_ROOT}/VideoDiffusion/.vendors/daydream-scope/.venv"
    VD_WEIGHTS="${REPO_ROOT}/VideoDiffusion/.cache/daydream-scope"
    ;;
  *)
    VD_VENV="${REPO_ROOT}/VideoDiffusion/.venv"
    VD_WEIGHTS="${REPO_ROOT}/VideoDiffusion/MAGI-1/downloads"
    ;;
esac

RUN_PREBUILD="1"
if [[ "${PUBLISH_PREBUILD}" == "never" ]]; then
  RUN_PREBUILD="0"
elif [[ "${PUBLISH_PREBUILD}" == "auto" ]]; then
  if [[ ! -d "${VD_VENV}" && ! -d "${VD_WEIGHTS}" ]]; then
    RUN_PREBUILD="0"
  fi
fi

if [[ "${RUN_PREBUILD}" == "1" ]]; then
  echo "[r2] publish runtime tuple artifacts..."
  PREBUILD_ARGS=(
    --tiers "${TIERS}"
  )
  if [[ -n "${RUNTIME_TAG}" ]]; then
    PREBUILD_ARGS+=(--runtime-tag "${RUNTIME_TAG}")
  fi
  if [[ "${ALLOW_MISSING_ENV}" == "1" ]]; then
    PREBUILD_ARGS+=(--allow-missing-env)
  fi
  if [[ "${ALLOW_MISSING_WEIGHTS}" == "1" ]]; then
    PREBUILD_ARGS+=(--allow-missing-weights)
  fi
  if [[ "${ALLOW_MISSING_IMAGE}" == "1" ]]; then
    PREBUILD_ARGS+=(--allow-missing-image)
  fi
  if [[ "${INCLUDE_WEIGHTS}" == "1" ]]; then
    PREBUILD_ARGS+=(--include-weights)
  fi
  if [[ "${INCLUDE_IMAGE}" == "1" ]]; then
    PREBUILD_ARGS+=(--include-image)
  fi
  if [[ -n "${IMAGE_ARCHIVE}" ]]; then
    PREBUILD_ARGS+=(--image-archive "${IMAGE_ARCHIVE}")
  fi

  R2_PREFIX="${R2_PREFIX}" VIDEO_MODEL="${VIDEO_MODEL}" ATTN_BACKEND="${ATTN_BACKEND}" \
    bash "${REPO_ROOT}/VideoDiffusion/publish_r2_prebuild_model.sh" \
      --model "${VIDEO_MODEL}" \
      --attn-backend "${ATTN_BACKEND}" \
      --env-compression "${R2_ENV_ARCHIVE_COMPRESSION}" \
      --weights-compression "${R2_WEIGHTS_ARCHIVE_COMPRESSION}" \
      "${PREBUILD_ARGS[@]}"
else
  echo "[r2] skip runtime tuple publish."
fi

if [[ "${PURGE_LOCAL_AFTER_UPLOAD}" == "1" ]]; then
  echo "[purge] removing local non-code artifacts..."
  rm -rf "${REPO_ROOT}/VideoDiffusion/.venv"
  rm -rf "${REPO_ROOT}/VideoDiffusion/.venv-krea"
  rm -rf "${REPO_ROOT}/VideoDiffusion/.tmp"
  rm -rf "${REPO_ROOT}/VideoDiffusion/.cache/krea"
  rm -rf "${REPO_ROOT}/VideoDiffusion/.cache/daydream-scope"
  rm -rf "${REPO_ROOT}/VideoDiffusion/.vendors/krea-realtime-video"
  rm -rf "${REPO_ROOT}/VideoDiffusion/.vendors/daydream-scope"
  rm -rf "${REPO_ROOT}/VideoDiffusion/MAGI-1/downloads"
  rm -rf "${REPO_ROOT}/VideoDiffusion/MAGI-1/ckpt"
  rm -rf "${REPO_ROOT}/VideoDiffusion/MAGI-1/t5"
  find "${REPO_ROOT}/VideoDiffusion" -maxdepth 1 -type f \( -name '*.mp4' -o -name '*.tar' -o -name '*.tar.gz' -o -name '*.tar.zst' \) -delete || true
  echo "[purge] done."
fi

echo "[r2] done. prefix=${R2_PREFIX} model=${VIDEO_MODEL} attn=${ATTN_BACKEND}"
