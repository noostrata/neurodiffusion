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
ATTN_BACKEND="${ATTN_BACKEND:-auto}"
RUNTIME_TAG="${RUNTIME_TAG:-}"
TIERS="${TIERS:-}"
INCLUDE_WEIGHTS="${INCLUDE_WEIGHTS:-0}"
INCLUDE_IMAGE="${INCLUDE_IMAGE:-0}"
IMAGE_ARCHIVE="${IMAGE_ARCHIVE:-}"
BUILD_GPU_CLASS="${BUILD_GPU_CLASS:-auto}"
VALIDATED_PROFILES="${VALIDATED_PROFILES:-}"
ALLOW_MISSING_ENV="${ALLOW_MISSING_ENV:-0}"
ALLOW_MISSING_WEIGHTS="${ALLOW_MISSING_WEIGHTS:-1}"
ALLOW_MISSING_IMAGE="${ALLOW_MISSING_IMAGE:-1}"
KEEP_TMP="${KEEP_TMP:-0}"
VENV_DIR="${VENV_DIR:-}"
WEIGHTS_DIR="${WEIGHTS_DIR:-}"
R2_ENV_ARCHIVE_COMPRESSION="${R2_ENV_ARCHIVE_COMPRESSION:-gzip}"
R2_WEIGHTS_ARCHIVE_COMPRESSION="${R2_WEIGHTS_ARCHIVE_COMPRESSION:-gzip}"

usage() {
  cat <<'EOF'
Usage:
  bash VideoDiffusion/publish_r2_prebuild_model.sh [options]

Options:
  --model <magi|krea|scope|longlive2>
                                  Runtime model selector
  --attn-backend <mode>          auto|sage|flash|sdpa (krea metadata + dispatch)
  --runtime-tag <tag>            Runtime tuple tag override
  --tiers <csv>                  Tier support metadata
  --venv-dir <path>              Venv path to archive
  --weights-dir <path>           Weights/cache path to archive
  --include-weights              Include weights/cache archive
  --include-image                Include image artifact
  --image-archive <path>         Explicit image archive path
  --build-gpu-class <class>      Metadata label (default: auto)
  --validated-profiles <csv>     Metadata profile labels
  --allow-missing-env            Do not fail when venv is missing
  --allow-missing-weights        Do not fail when weights/cache is missing
  --allow-missing-image          Do not fail when image archive is missing
  --env-compression <mode>       gzip|zstd|none (default: gzip)
  --weights-compression <mode>   gzip|zstd|none (default: gzip)
  --keep-tmp                     Keep local staging directory
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
    --runtime-tag)
      RUNTIME_TAG="$2"
      shift 2
      ;;
    --tiers)
      TIERS="$2"
      shift 2
      ;;
    --venv-dir)
      VENV_DIR="$2"
      shift 2
      ;;
    --weights-dir)
      WEIGHTS_DIR="$2"
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
    --build-gpu-class)
      BUILD_GPU_CLASS="$2"
      shift 2
      ;;
    --validated-profiles)
      VALIDATED_PROFILES="$2"
      shift 2
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
    --keep-tmp)
      KEEP_TMP="1"
      shift
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
if [[ -z "${TIERS}" ]]; then
  TIERS="$(default_tiers_for_model "${VIDEO_MODEL}")"
fi

if [[ "${VIDEO_MODEL}" == "magi" ]]; then
  video_log "Delegating to existing MAGI publish script."
  pass_args=(
    --tiers "${TIERS}"
    --build-gpu-class "${BUILD_GPU_CLASS}"
  )
  if [[ -n "${RUNTIME_TAG}" ]]; then
    pass_args+=(--runtime-tag "${RUNTIME_TAG}")
  fi
  if [[ -n "${VALIDATED_PROFILES}" ]]; then
    pass_args+=(--validated-profiles "${VALIDATED_PROFILES}")
  fi
  if [[ -n "${VENV_DIR}" ]]; then
    pass_args+=(--venv-dir "${VENV_DIR}")
  fi
  if [[ -n "${WEIGHTS_DIR}" ]]; then
    pass_args+=(--weights-dir "${WEIGHTS_DIR}")
  fi
  if [[ "${INCLUDE_WEIGHTS}" == "1" ]]; then
    pass_args+=(--include-weights)
  fi
  if [[ "${INCLUDE_IMAGE}" == "1" ]]; then
    pass_args+=(--include-image)
  fi
  if [[ -n "${IMAGE_ARCHIVE}" ]]; then
    pass_args+=(--image-archive "${IMAGE_ARCHIVE}")
  fi
  if [[ "${ALLOW_MISSING_ENV}" == "1" ]]; then
    pass_args+=(--allow-missing-env)
  fi
  if [[ "${ALLOW_MISSING_WEIGHTS}" == "1" ]]; then
    pass_args+=(--allow-missing-weights)
  fi
  if [[ "${ALLOW_MISSING_IMAGE}" == "1" ]]; then
    pass_args+=(--allow-missing-image)
  fi
  if [[ "${KEEP_TMP}" == "1" ]]; then
    pass_args+=(--keep-tmp)
  fi
  R2_PREFIX="${R2_PREFIX}" bash "${SCRIPT_DIR}/publish_r2_prebuild.sh" "${pass_args[@]}"
  exit 0
fi

if [[ -z "${AGENT_S3_BUCKET:-}" || -z "${AGENT_S3_ENDPOINT:-}" || -z "${AGENT_S3_ACCESS_KEY_ID:-}" || -z "${AGENT_S3_SECRET_ACCESS_KEY:-}" ]]; then
  echo "[error] Missing AGENT_S3_* vars. Source ${R2_ENV_FILE} first." >&2
  exit 1
fi

PYTHON_BIN="$(r2_ensure_python_with_boto3 1)"

if [[ -z "${VENV_DIR}" ]]; then
  if [[ "${VIDEO_MODEL}" == "scope" ]]; then
    VENV_DIR="${SCRIPT_DIR}/.vendors/daydream-scope/.venv"
  elif [[ "${VIDEO_MODEL}" == "longlive2" ]]; then
    VENV_DIR="${SCRIPT_DIR}/.vendors/LongLive2/.venv"
  else
    VENV_DIR="${SCRIPT_DIR}/.venv-krea"
  fi
fi
if [[ -z "${WEIGHTS_DIR}" ]]; then
  if [[ "${VIDEO_MODEL}" == "scope" ]]; then
    WEIGHTS_DIR="${SCRIPT_DIR}/.cache/daydream-scope"
  elif [[ "${VIDEO_MODEL}" == "longlive2" ]]; then
    WEIGHTS_DIR="${SCRIPT_DIR}/.cache/longlive2"
  else
    WEIGHTS_DIR="${SCRIPT_DIR}/.cache/krea"
  fi
fi
if [[ -z "${VALIDATED_PROFILES}" ]]; then
  if [[ "${VIDEO_MODEL}" == "scope" ]]; then
    VALIDATED_PROFILES="scope_longlive_realtime_smoke"
  elif [[ "${VIDEO_MODEL}" == "longlive2" ]]; then
    VALIDATED_PROFILES="longlive2_sp_offline_smoke"
  else
    VALIDATED_PROFILES="krea_realtime_smoke"
  fi
fi

RUN_ID="prebuild_${VIDEO_MODEL}_$(date -u +%Y%m%dT%H%M%SZ)"
TMP_DIR="${SCRIPT_DIR}/.tmp/${RUN_ID}"
mkdir -p "${TMP_DIR}"

cleanup() {
  if [[ "${KEEP_TMP}" != "1" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

normalize_archive_compression() {
  local raw
  raw="$(to_lower "${1:-gzip}")"
  case "${raw}" in
    gzip|gz)
      printf 'gzip\n'
      ;;
    zstd|zst)
      printf 'zstd\n'
      ;;
    none|tar)
      printf 'none\n'
      ;;
    *)
      echo "[error] unsupported archive compression '${1}'. Use gzip, zstd, or none." >&2
      return 1
      ;;
  esac
}

archive_extension_for() {
  case "$1" in
    gzip) printf '.tar.gz' ;;
    zstd) printf '.tar.zst' ;;
    none) printf '.tar' ;;
    *)
      echo "[error] unsupported archive compression '$1'." >&2
      return 1
      ;;
  esac
}

create_archive() {
  local compression="$1"
  local archive_path="$2"
  local parent_dir="$3"
  local base_name="$4"

  case "${compression}" in
    gzip)
      tar -czf "${archive_path}" -C "${parent_dir}" "${base_name}"
      ;;
    zstd)
      if ! command_exists zstd; then
        echo "[error] zstd compression requested but zstd is not installed." >&2
        return 1
      fi
      tar -cf - -C "${parent_dir}" "${base_name}" | zstd -T0 -3 -o "${archive_path}"
      ;;
    none)
      tar -cf "${archive_path}" -C "${parent_dir}" "${base_name}"
      ;;
    *)
      echo "[error] unsupported archive compression '${compression}'." >&2
      return 1
      ;;
  esac
}

R2_ENV_ARCHIVE_COMPRESSION="$(normalize_archive_compression "${R2_ENV_ARCHIVE_COMPRESSION}")"
R2_WEIGHTS_ARCHIVE_COMPRESSION="$(normalize_archive_compression "${R2_WEIGHTS_ARCHIVE_COMPRESSION}")"

if [[ -z "${RUNTIME_TAG}" ]]; then
  DETECT_PY="${PYTHON_BIN}"
  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    DETECT_PY="${VENV_DIR}/bin/python"
  fi
  RUNTIME_TAG="$("${DETECT_PY}" - "${VIDEO_MODEL}" "${ATTN_BACKEND}" <<'PY'
import re
import sys

video_model, attn_backend = sys.argv[1:]
py = f"py{sys.version_info.major}{sys.version_info.minor}"
torch_v = "na"
cuda_v = "na"
sm = "na"
try:
    import torch

    torch_v = str(torch.__version__).split("+", 1)[0]
    cuda_v = (torch.version.cuda or "na").replace(".", "")
    if torch.cuda.is_available():
        p = torch.cuda.get_device_properties(0)
        sm = f"{p.major}{p.minor}"
except Exception:
    pass
tag = f"{video_model}_{attn_backend}_{py}_torch{torch_v}_cu{cuda_v}_sm{sm}"
print(re.sub(r"[^A-Za-z0-9_.-]+", "-", tag))
PY
)"
fi

video_log "runtime_tag=${RUNTIME_TAG}"
video_log "model=${VIDEO_MODEL} attn=${ATTN_BACKEND} tiers=${TIERS}"
video_log "archive_compression env=${R2_ENV_ARCHIVE_COMPRESSION} weights=${R2_WEIGHTS_ARCHIVE_COMPRESSION}"
video_log "staging=${TMP_DIR}"

WHEELHOUSE_DIR="${TMP_DIR}/wheelhouse"
mkdir -p "${WHEELHOUSE_DIR}"
ENV_ARCHIVE=""
WEIGHTS_ARCHIVE=""
IMAGE_ARCHIVE_RESOLVED=""
WEIGHT_SHARD_CHECKSUMS_JSON="${TMP_DIR}/weight_shards_${RUNTIME_TAG}.json"

if [[ -d "${VENV_DIR}" ]]; then
  VENV_PARENT="$(cd -- "$(dirname -- "${VENV_DIR}")" && pwd)"
  VENV_BASE="$(basename -- "${VENV_DIR}")"
  ENV_ARCHIVE="${TMP_DIR}/venv_${RUNTIME_TAG}$(archive_extension_for "${R2_ENV_ARCHIVE_COMPRESSION}")"
  create_archive "${R2_ENV_ARCHIVE_COMPRESSION}" "${ENV_ARCHIVE}" "${VENV_PARENT}" "${VENV_BASE}"

  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    PIP_FREEZE="${TMP_DIR}/pip_freeze_${RUNTIME_TAG}.txt"
    if "${VENV_DIR}/bin/python" -m pip --version >/dev/null 2>&1; then
      "${VENV_DIR}/bin/python" -m pip freeze > "${PIP_FREEZE}" || true
      CACHE_DIR="$("${VENV_DIR}/bin/python" -m pip cache dir 2>/dev/null || true)"
      if [[ -n "${CACHE_DIR}" && -d "${CACHE_DIR}" ]]; then
        while IFS= read -r whl; do
          cp -f "${whl}" "${WHEELHOUSE_DIR}/"
        done < <(find "${CACHE_DIR}" -type f -name '*.whl' | head -n 1200)
      fi
    elif command_exists uv; then
      uv pip freeze --python "${VENV_DIR}/bin/python" > "${PIP_FREEZE}" || true
    else
      : > "${PIP_FREEZE}"
    fi
  fi
elif [[ "${ALLOW_MISSING_ENV}" != "1" ]]; then
  echo "[error] venv not found at ${VENV_DIR}. Run setup first or pass --allow-missing-env." >&2
  exit 1
fi

if [[ "${INCLUDE_WEIGHTS}" == "1" ]]; then
  if [[ -d "${WEIGHTS_DIR}" ]]; then
    WEIGHTS_PARENT="$(cd -- "$(dirname -- "${WEIGHTS_DIR}")" && pwd)"
    WEIGHTS_BASE="$(basename -- "${WEIGHTS_DIR}")"
    WEIGHTS_ARCHIVE="${TMP_DIR}/weights_${RUNTIME_TAG}$(archive_extension_for "${R2_WEIGHTS_ARCHIVE_COMPRESSION}")"
    create_archive "${R2_WEIGHTS_ARCHIVE_COMPRESSION}" "${WEIGHTS_ARCHIVE}" "${WEIGHTS_PARENT}" "${WEIGHTS_BASE}"

    "${PYTHON_BIN}" - "${WEIGHTS_DIR}" "${WEIGHT_SHARD_CHECKSUMS_JSON}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
out_path = Path(sys.argv[2]).resolve()
rows = []
for p in sorted(root.rglob("*")):
    if not p.is_file():
        continue
    rel = p.relative_to(root).as_posix()
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    rows.append({"path": rel, "size_bytes": p.stat().st_size, "sha256": h.hexdigest()})
payload = {"weights_root": str(root), "file_count": len(rows), "files": rows}
out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
  elif [[ "${ALLOW_MISSING_WEIGHTS}" != "1" ]]; then
    echo "[error] weights/cache dir not found at ${WEIGHTS_DIR}." >&2
    exit 1
  fi
fi

if [[ "${INCLUDE_IMAGE}" == "1" ]]; then
  if [[ -n "${IMAGE_ARCHIVE}" ]]; then
    IMAGE_ARCHIVE_RESOLVED="${IMAGE_ARCHIVE}"
  elif [[ "${ALLOW_MISSING_IMAGE}" != "1" ]]; then
    echo "[error] --include-image requested but --image-archive is empty." >&2
    exit 1
  fi
fi

METADATA_JSON="${TMP_DIR}/metadata_${RUNTIME_TAG}.json"
"${PYTHON_BIN}" - "${METADATA_JSON}" "${RUNTIME_TAG}" "${VIDEO_MODEL}" "${ATTN_BACKEND}" "${TIERS}" "${VALIDATED_PROFILES}" "${BUILD_GPU_CLASS}" "${ENV_ARCHIVE}" "${WEIGHTS_ARCHIVE}" "${IMAGE_ARCHIVE_RESOLVED}" "${WEIGHT_SHARD_CHECKSUMS_JSON}" "${REPO_ROOT}" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    out_path,
    runtime_tag,
    video_model,
    attn_backend,
    tiers_csv,
    profiles_csv,
    build_gpu_class,
    env_archive,
    weights_archive,
    image_archive,
    shard_json,
    repo_root,
) = sys.argv[1:]

def file_sha256(path: str) -> str:
    p = Path(path)
    if not path or not p.is_file():
        return ""
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def git_commit(root: str) -> str:
    try:
        return (
            subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL)
            .strip()
        )
    except Exception:
        return "unknown"

cuda_stack = {"python": "na", "torch": "na", "cuda": "na", "gpu_name": "na", "sm": "na"}
try:
    import torch
    import platform

    cuda_stack["python"] = platform.python_version()
    cuda_stack["torch"] = str(torch.__version__)
    cuda_stack["cuda"] = str(torch.version.cuda or "na")
    if torch.cuda.is_available():
        p = torch.cuda.get_device_properties(0)
        cuda_stack["gpu_name"] = p.name
        cuda_stack["sm"] = f"{p.major}{p.minor}"
except Exception:
    pass

artifact_checksums = {}
for key, path in {
    "env_archive": env_archive,
    "weights_archive": weights_archive,
    "image_archive": image_archive,
}.items():
    digest = file_sha256(path)
    if digest:
        artifact_checksums[key] = digest

model_shard_checksums = {}
if shard_json and Path(shard_json).is_file():
    try:
        model_shard_checksums = json.loads(Path(shard_json).read_text(encoding="utf-8"))
    except Exception:
        model_shard_checksums = {}

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "runtime_tag": runtime_tag,
    "video_model": video_model,
    "attn_backend": attn_backend,
    "git_commit": git_commit(repo_root),
    "cuda_stack": cuda_stack,
    "artifact_checksums": artifact_checksums,
    "tier_support": [x.strip() for x in tiers_csv.split(",") if x.strip()],
    "build_gpu_class": build_gpu_class,
    "validated_profiles": [x.strip() for x in profiles_csv.split(",") if x.strip()],
    "model_shard_checksums": model_shard_checksums,
    "schema_hint": "VideoDiffusion/runtime-manifest-v2.schema.json",
}

Path(out_path).write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY

PUBLISH_ARGS=(
  "${REPO_ROOT}/scripts/cloudflare/prebuild_bundle.py"
  --prefix "${R2_PREFIX}"
  publish
  --runtime-tag "${RUNTIME_TAG}"
  --wheelhouse-dir "${WHEELHOUSE_DIR}"
  --metadata-json "${METADATA_JSON}"
)
if [[ -n "${ENV_ARCHIVE}" ]]; then
  PUBLISH_ARGS+=(--env-archive "${ENV_ARCHIVE}")
fi
if [[ -n "${WEIGHTS_ARCHIVE}" ]]; then
  PUBLISH_ARGS+=(--weights-archive "${WEIGHTS_ARCHIVE}")
fi
if [[ -n "${IMAGE_ARCHIVE_RESOLVED}" ]]; then
  PUBLISH_ARGS+=(--image-archive "${IMAGE_ARCHIVE_RESOLVED}")
fi

"${PYTHON_BIN}" "${PUBLISH_ARGS[@]}" >/dev/null
video_log "Publish complete: model=${VIDEO_MODEL} runtime_tag=${RUNTIME_TAG} prefix=${R2_PREFIX}"
