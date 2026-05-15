#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

R2_ENV_FILE="${R2_ENV_FILE:-/Users/xenochain/agents/secrets/r2_full_access.env}"
if [[ -f "${R2_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${R2_ENV_FILE}"
fi

R2_BOOTSTRAP_VENV="${R2_BOOTSTRAP_VENV:-${REPO_ROOT}/.venv/r2-bootstrap}"
R2_PREFIX="${R2_PREFIX:-neurodiffusion}"
# shellcheck source=scripts/cloudflare/r2_common.sh
source "${REPO_ROOT}/scripts/cloudflare/r2_common.sh"

VIDEO_MODEL="${VIDEO_MODEL:-magi}"
MODE="${MODE:-auto}" # auto|tuple|image
RUNTIME_TAG="${RUNTIME_TAG:-}"
DEST_DIR="${DEST_DIR:-${SCRIPT_DIR}/.tmp/r2_prebuild_restore}"
APPLY_VENV_TARGET="${APPLY_VENV_TARGET:-}"
EXTRACT_WEIGHTS="${EXTRACT_WEIGHTS:-0}"
APPLY_WEIGHTS_TARGET="${APPLY_WEIGHTS_TARGET:-}"
LOAD_IMAGE="${LOAD_IMAGE:-1}"
TIER="${TIER:-}"

usage() {
  cat <<'EOF'
Usage:
  bash VideoDiffusion/restore_r2_prebuild_model.sh --model <magi|krea> --runtime-tag <tag> [options]

Options:
  --mode <auto|tuple|image>     Restore strategy (default: auto)
  --runtime-tag <tag>           Runtime tuple tag to fetch
  --dest-dir <path>             Destination for downloaded artifacts
  --apply-venv-target <path>    Extract env archive into target venv path
  --extract-weights             Extract weights archive
  --apply-weights-target <path> Extract weights archive into explicit path
  --no-load-image               Skip docker/podman image load
  --tier <name>                 Optional metadata label
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      VIDEO_MODEL="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --runtime-tag)
      RUNTIME_TAG="$2"
      shift 2
      ;;
    --dest-dir)
      DEST_DIR="$2"
      shift 2
      ;;
    --apply-venv-target)
      APPLY_VENV_TARGET="$2"
      shift 2
      ;;
    --extract-weights)
      EXTRACT_WEIGHTS="1"
      shift
      ;;
    --apply-weights-target)
      APPLY_WEIGHTS_TARGET="$2"
      EXTRACT_WEIGHTS="1"
      shift 2
      ;;
    --no-load-image)
      LOAD_IMAGE="0"
      shift
      ;;
    --tier)
      TIER="$2"
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
if [[ "${VIDEO_MODEL}" == "magi" ]]; then
  pass_args=(--mode "${MODE}" --runtime-tag "${RUNTIME_TAG}" --dest-dir "${DEST_DIR}")
  if [[ -n "${TIER}" ]]; then
    pass_args+=(--tier "${TIER}")
  fi
  if [[ -n "${APPLY_VENV_TARGET}" ]]; then
    pass_args+=(--apply-venv-target "${APPLY_VENV_TARGET}")
  fi
  if [[ "${EXTRACT_WEIGHTS}" == "1" ]]; then
    pass_args+=(--extract-weights)
  fi
  if [[ -n "${APPLY_WEIGHTS_TARGET}" ]]; then
    pass_args+=(--apply-weights-target "${APPLY_WEIGHTS_TARGET}")
  fi
  if [[ "${LOAD_IMAGE}" != "1" ]]; then
    pass_args+=(--no-load-image)
  fi
  bash "${SCRIPT_DIR}/restore_r2_prebuild.sh" "${pass_args[@]}"
  exit 0
fi

if [[ -z "${RUNTIME_TAG}" ]]; then
  echo "[error] --runtime-tag is required." >&2
  exit 1
fi
case "${MODE}" in
  auto|tuple|image) ;;
  *)
    echo "[error] --mode must be auto, tuple, or image." >&2
    exit 1
    ;;
esac

if [[ -z "${APPLY_VENV_TARGET}" ]]; then
  APPLY_VENV_TARGET="${SCRIPT_DIR}/.venv-krea"
fi

PYTHON_BIN="$(r2_ensure_python_with_boto3 1)"

mkdir -p "${DEST_DIR}"

fetch_artifacts() {
  local artifact_types="$1"
  local out_dir="$2"
  mkdir -p "${out_dir}"
  "${PYTHON_BIN}" "${REPO_ROOT}/scripts/cloudflare/prebuild_bundle.py" \
    --prefix "${R2_PREFIX}" \
    fetch \
    --runtime-tag "${RUNTIME_TAG}" \
    --dest-dir "${out_dir}" \
    --artifact-types "${artifact_types}" >/dev/null
}

image_load_with() {
  local image_file="$1"
  local loader="$2"
  local rc=0
  case "${image_file}" in
    *.tar.zst)
      if ! command -v zstd >/dev/null 2>&1; then
        return 127
      fi
      zstd -dc "${image_file}" | "${loader}" load || rc=$?
      ;;
    *.tar.gz|*.tgz)
      gzip -dc "${image_file}" | "${loader}" load || rc=$?
      ;;
    *.tar)
      "${loader}" load -i "${image_file}" || rc=$?
      ;;
    *)
      return 2
      ;;
  esac
  return "${rc}"
}

restore_tuple_from() {
  local out_dir="$1"
  local env_archive
  local weights_archive
  env_archive="$(find "${out_dir}/env_archive" -type f -name '*.tar.gz' 2>/dev/null | head -n1 || true)"
  weights_archive="$(find "${out_dir}/weights_archive" -type f -name '*.tar.gz' 2>/dev/null | head -n1 || true)"

  if [[ -n "${APPLY_VENV_TARGET}" ]]; then
    if [[ -z "${env_archive}" ]]; then
      echo "[error] no env archive found in ${out_dir}/env_archive." >&2
      return 1
    fi
    rm -rf "${APPLY_VENV_TARGET}"
    mkdir -p "${APPLY_VENV_TARGET}"
    tar -xzf "${env_archive}" -C "${APPLY_VENV_TARGET}" --strip-components=1
    echo "[restore] venv restored to ${APPLY_VENV_TARGET}"
  fi

  if [[ "${EXTRACT_WEIGHTS}" == "1" ]]; then
    if [[ -z "${weights_archive}" ]]; then
      echo "[restore] no weights archive found; skipping extraction."
    else
      if [[ -n "${APPLY_WEIGHTS_TARGET}" ]]; then
        OUT_WEIGHTS="${APPLY_WEIGHTS_TARGET}"
      else
        OUT_WEIGHTS="${out_dir}/weights_extracted"
      fi
      mkdir -p "${OUT_WEIGHTS}"
      tar -xzf "${weights_archive}" -C "${OUT_WEIGHTS}" --strip-components=1
      echo "[restore] weights extracted to ${OUT_WEIGHTS}"
    fi
  fi
}

restored_mode=""
image_error=""

if [[ "${MODE}" == "auto" || "${MODE}" == "image" ]]; then
  IMAGE_FETCH_DIR="${DEST_DIR}/image_restore"
  if fetch_artifacts "image_archive,metadata" "${IMAGE_FETCH_DIR}" >/dev/null 2>&1; then
    image_file="$(find "${IMAGE_FETCH_DIR}/image_archive" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar.zst' \) | head -n1 || true)"
    if [[ -n "${image_file}" ]]; then
      if [[ "${LOAD_IMAGE}" == "1" ]]; then
        if command -v docker >/dev/null 2>&1; then
          if image_load_with "${image_file}" docker; then
            restored_mode="image"
            echo "[restore] runtime image loaded via docker from ${image_file}"
          else
            image_error="docker load failed for ${image_file}"
          fi
        elif command -v podman >/dev/null 2>&1; then
          if image_load_with "${image_file}" podman; then
            restored_mode="image"
            echo "[restore] runtime image loaded via podman from ${image_file}"
          else
            image_error="podman load failed for ${image_file}"
          fi
        else
          image_error="no docker/podman found for image restore"
        fi
      else
        restored_mode="image"
        echo "[restore] image artifact downloaded to ${image_file} (load skipped by --no-load-image)"
      fi
    else
      image_error="image artifact not present for runtime_tag=${RUNTIME_TAG}"
    fi
  else
    image_error="image artifact fetch failed"
  fi
fi

if [[ -z "${restored_mode}" && ( "${MODE}" == "auto" || "${MODE}" == "tuple" ) ]]; then
  TUPLE_FETCH_DIR="${DEST_DIR}/tuple_restore"
  fetch_artifacts "env_archive,wheelhouse,weights_archive,metadata" "${TUPLE_FETCH_DIR}"
  restore_tuple_from "${TUPLE_FETCH_DIR}"
  restored_mode="tuple"
fi

if [[ -z "${restored_mode}" ]]; then
  echo "[error] restore failed in mode=${MODE}. ${image_error}" >&2
  exit 1
fi

echo "[restore] done mode=${restored_mode} model=${VIDEO_MODEL} runtime_tag=${RUNTIME_TAG} tier=${TIER} dest=${DEST_DIR}"
