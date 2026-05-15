#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

R2_ENV_FILE="${R2_ENV_FILE:-/Users/xenochain/agents/secrets/r2_full_access.env}"
if [[ -f "${R2_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${R2_ENV_FILE}"
fi

R2_BOOTSTRAP_VENV="${R2_BOOTSTRAP_VENV:-${REPO_ROOT}/.venv/r2-bootstrap}"
R2_PREFIX="${R2_PREFIX:-neurodiffusion}"

# shellcheck source=scripts/cloudflare/r2_common.sh
source "${REPO_ROOT}/scripts/cloudflare/r2_common.sh"
PYTHON_BIN="$(r2_ensure_python_with_boto3 1)"

VENV_DIR="${VENV_DIR:-${SCRIPT_DIR}/.venv}"
WEIGHTS_DIR="${WEIGHTS_DIR:-${SCRIPT_DIR}/MAGI-1/downloads}"
RUNTIME_TAG="${RUNTIME_TAG:-}"
TIERS="${TIERS:-4.5b,24b}"
INCLUDE_WEIGHTS="${INCLUDE_WEIGHTS:-0}"
INCLUDE_IMAGE="${INCLUDE_IMAGE:-0}"
IMAGE_ARCHIVE="${IMAGE_ARCHIVE:-}"
BUILD_GPU_CLASS="${BUILD_GPU_CLASS:-hopper}"
VALIDATED_PROFILES="${VALIDATED_PROFILES:-4.5b_smoke,24b_smoke}"
ALLOW_MISSING_ENV="${ALLOW_MISSING_ENV:-0}"
ALLOW_MISSING_WEIGHTS="${ALLOW_MISSING_WEIGHTS:-1}"
ALLOW_MISSING_IMAGE="${ALLOW_MISSING_IMAGE:-1}"
KEEP_TMP="${KEEP_TMP:-0}"

RUN_ID="prebuild_$(date -u +%Y%m%dT%H%M%SZ)"
TMP_DIR="${SCRIPT_DIR}/.tmp/${RUN_ID}"
mkdir -p "${TMP_DIR}"

cleanup() {
  if [[ "${KEEP_TMP}" != "1" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  bash VideoDiffusion/publish_r2_prebuild.sh [options]

Options:
  --runtime-tag <tag>           Runtime tuple tag override (auto-detected if omitted)
  --tiers <csv>                 Tier support list (default: 4.5b,24b)
  --venv-dir <path>             Venv path to archive (default: VideoDiffusion/.venv)
  --weights-dir <path>          Weights root dir (default: VideoDiffusion/MAGI-1/downloads)
  --include-weights             Archive and publish weights
  --include-image               Publish runtime image artifact
  --image-archive <path>        Runtime image artifact path (.tar/.tar.gz/.tar.zst)
  --build-gpu-class <class>     Build GPU class metadata (default: hopper)
  --validated-profiles <csv>    Validation profile names metadata
  --allow-missing-env           Do not fail when venv is missing
  --allow-missing-weights       Do not fail when weights are missing (default)
  --allow-missing-image         Do not fail when image archive is missing (default)
  --keep-tmp                    Keep local staging directory under VideoDiffusion/.tmp/
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-tag)
      RUNTIME_TAG="$2"
      shift 2
      ;;
    --tiers)
      TIERS="$2"
      shift 2
      ;;
    --tier)
      if [[ -n "${TIERS}" ]]; then
        TIERS="${TIERS},$2"
      else
        TIERS="$2"
      fi
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

if [[ -z "${AGENT_S3_BUCKET:-}" || -z "${AGENT_S3_ENDPOINT:-}" || -z "${AGENT_S3_ACCESS_KEY_ID:-}" || -z "${AGENT_S3_SECRET_ACCESS_KEY:-}" ]]; then
  echo "[error] Missing AGENT_S3_* vars. Source ${R2_ENV_FILE} first." >&2
  exit 1
fi

if [[ -z "${RUNTIME_TAG}" ]]; then
  DETECT_PY="${PYTHON_BIN}"
  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    DETECT_PY="${VENV_DIR}/bin/python"
  fi
  RUNTIME_TAG="$("${DETECT_PY}" - <<'PY'
import platform
import re
import sys

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
parts = [py, f"torch{torch_v}", f"cu{cuda_v}", f"sm{sm}"]
tag = "_".join(parts)
tag = re.sub(r"[^A-Za-z0-9_.-]+", "-", tag)
print(tag)
PY
)"
fi

echo "[prebuild] runtime_tag=${RUNTIME_TAG}"
echo "[prebuild] tiers=${TIERS}"
echo "[prebuild] staging=${TMP_DIR}"

WHEELHOUSE_DIR="${TMP_DIR}/wheelhouse"
mkdir -p "${WHEELHOUSE_DIR}"
ENV_ARCHIVE=""
WEIGHTS_ARCHIVE=""
IMAGE_ARCHIVE_RESOLVED=""
WEIGHT_SHARD_CHECKSUMS_JSON="${TMP_DIR}/weight_shards_${RUNTIME_TAG}.json"

if [[ -d "${VENV_DIR}" ]]; then
  VENV_PARENT="$(cd -- "$(dirname -- "${VENV_DIR}")" && pwd)"
  VENV_BASE="$(basename -- "${VENV_DIR}")"
  ENV_ARCHIVE="${TMP_DIR}/venv_${RUNTIME_TAG}.tar.gz"
  tar -czf "${ENV_ARCHIVE}" -C "${VENV_PARENT}" "${VENV_BASE}"

  VENV_PY="${VENV_DIR}/bin/python"
  if [[ -x "${VENV_PY}" ]]; then
    "${VENV_PY}" -m pip freeze > "${TMP_DIR}/pip_freeze_${RUNTIME_TAG}.txt" || true
    CACHE_DIR="$("${VENV_PY}" -m pip cache dir 2>/dev/null || true)"
    if [[ -n "${CACHE_DIR}" && -d "${CACHE_DIR}" ]]; then
      while IFS= read -r whl; do
        cp -f "${whl}" "${WHEELHOUSE_DIR}/"
      done < <(find "${CACHE_DIR}" -type f -name '*.whl' | head -n 1200)
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
    WEIGHTS_ARCHIVE="${TMP_DIR}/weights_${RUNTIME_TAG}.tar.gz"
    tar -czf "${WEIGHTS_ARCHIVE}" -C "${WEIGHTS_PARENT}" "${WEIGHTS_BASE}"

    "${PYTHON_BIN}" - "${WEIGHTS_DIR}" "${WEIGHT_SHARD_CHECKSUMS_JSON}" <<'PY'
import hashlib
import json
import os
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
    rows.append(
        {
            "path": rel,
            "size_bytes": p.stat().st_size,
            "sha256": h.hexdigest(),
        }
    )
payload = {
    "weights_root": str(root),
    "file_count": len(rows),
    "files": rows,
}
out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
  elif [[ "${ALLOW_MISSING_WEIGHTS}" != "1" ]]; then
    echo "[error] weights dir not found at ${WEIGHTS_DIR}." >&2
    exit 1
  fi
fi

if [[ "${INCLUDE_IMAGE}" == "1" ]]; then
  if [[ -n "${IMAGE_ARCHIVE}" ]]; then
    IMAGE_ARCHIVE_RESOLVED="${IMAGE_ARCHIVE}"
  else
    for candidate in \
      "${SCRIPT_DIR}/.tmp/magi_runtime_oci.tar.zst" \
      "${SCRIPT_DIR}/.tmp/magi_runtime_oci.tar.gz" \
      "${SCRIPT_DIR}/.tmp/magi_runtime_oci.tar"; do
      if [[ -f "${candidate}" ]]; then
        IMAGE_ARCHIVE_RESOLVED="${candidate}"
        break
      fi
    done
  fi
  if [[ -n "${IMAGE_ARCHIVE_RESOLVED}" ]]; then
    IMAGE_ARCHIVE_RESOLVED="$(cd -- "$(dirname -- "${IMAGE_ARCHIVE_RESOLVED}")" && pwd)/$(basename -- "${IMAGE_ARCHIVE_RESOLVED}")"
  elif [[ "${ALLOW_MISSING_IMAGE}" != "1" ]]; then
    echo "[error] --include-image requested but no image archive was found." >&2
    exit 1
  fi
fi

detect_python="${PYTHON_BIN}"
if [[ -x "${VENV_DIR}/bin/python" ]]; then
  detect_python="${VENV_DIR}/bin/python"
fi

METADATA_JSON="${TMP_DIR}/metadata_${RUNTIME_TAG}.json"
"${PYTHON_BIN}" - "${METADATA_JSON}" "${RUNTIME_TAG}" "${RUN_ID}" "${TIERS}" "${VALIDATED_PROFILES}" "${BUILD_GPU_CLASS}" "${VENV_DIR}" "${WEIGHTS_DIR}" "${INCLUDE_WEIGHTS}" "${ENV_ARCHIVE}" "${WEIGHTS_ARCHIVE}" "${IMAGE_ARCHIVE_RESOLVED}" "${WHEELHOUSE_DIR}" "${WEIGHT_SHARD_CHECKSUMS_JSON}" "${REPO_ROOT}" "${detect_python}" <<'PY'
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
    run_id,
    tiers_raw,
    profiles_raw,
    build_gpu_class,
    venv_dir,
    weights_dir,
    include_weights,
    env_archive,
    weights_archive,
    image_archive,
    wheelhouse_dir,
    weight_shard_checksums_json,
    repo_root,
    detect_python,
) = sys.argv[1:]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def maybe_git(args: list[str]) -> str:
    try:
        out = subprocess.check_output(["git", *args], cwd=repo_root, stderr=subprocess.DEVNULL)
        return out.decode("utf-8").strip()
    except Exception:
        return ""


def cuda_stack(py_bin: str) -> dict:
    code = r"""
import json
payload = {"python": "", "torch": "na", "cuda": "na", "gpu_name": "na", "sm": "na"}
try:
    import sys
    payload["python"] = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
except Exception:
    pass
try:
    import torch
    payload["torch"] = str(torch.__version__)
    payload["cuda"] = str(torch.version.cuda or "na")
    if torch.cuda.is_available():
        p = torch.cuda.get_device_properties(0)
        payload["gpu_name"] = str(p.name)
        payload["sm"] = f"{p.major}{p.minor}"
except Exception:
    pass
print(json.dumps(payload))
"""
    try:
        out = subprocess.check_output([py_bin, "-c", code], stderr=subprocess.DEVNULL).decode("utf-8")
        return json.loads(out.strip())
    except Exception:
        return {"python": "na", "torch": "na", "cuda": "na", "gpu_name": "na", "sm": "na"}


def lock_hash(repo_root_path: Path) -> str:
    candidates = [
        repo_root_path / "VideoDiffusion" / "requirements-magi.lock.txt",
        repo_root_path / "VideoDiffusion" / ".tmp" / f"pip_freeze_{runtime_tag}.txt",
    ]
    for c in candidates:
        if c.is_file():
            return sha256(c)
    return ""


artifact_checksums = {}
if env_archive:
    p = Path(env_archive)
    if p.is_file():
        artifact_checksums["env_archive"] = sha256(p)
if weights_archive:
    p = Path(weights_archive)
    if p.is_file():
        artifact_checksums["weights_archive"] = sha256(p)
if image_archive:
    p = Path(image_archive)
    if p.is_file():
        artifact_checksums["image_archive"] = sha256(p)

wheelhouse = Path(wheelhouse_dir)
wheel_entries = []
if wheelhouse.is_dir():
    for p in sorted(wheelhouse.glob("*.whl")):
        s = sha256(p)
        artifact_checksums[f"wheelhouse/{p.name}"] = s
        wheel_entries.append({"filename": p.name, "sha256": s, "size_bytes": p.stat().st_size})

weights_checksums = {}
weights_manifest = Path(weight_shard_checksums_json)
if weights_manifest.is_file():
    try:
        weights_checksums = json.loads(weights_manifest.read_text(encoding="utf-8"))
    except Exception:
        weights_checksums = {}

repo_root_path = Path(repo_root).resolve()
payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "runtime_tag": runtime_tag,
    "run_id": run_id,
    "schema_version": "1.0.0",
    "tier_support": [x.strip() for x in tiers_raw.split(",") if x.strip()],
    "validated_profiles": [x.strip() for x in profiles_raw.split(",") if x.strip()],
    "build_gpu_class": build_gpu_class,
    "git_commit": maybe_git(["rev-parse", "HEAD"]),
    "git_branch": maybe_git(["rev-parse", "--abbrev-ref", "HEAD"]),
    "cuda_stack": cuda_stack(detect_python),
    "python_lock_hash": lock_hash(repo_root_path),
    "include_weights": include_weights.strip() in {"1", "true", "True"},
    "venv_dir": venv_dir,
    "weights_dir": weights_dir,
    "wheelhouse": {
        "count": len(wheel_entries),
        "files": wheel_entries,
    },
    "artifact_checksums": artifact_checksums,
    "model_shard_checksums": weights_checksums,
}

Path(out_path).write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY

PUBLISH_ARGS=(
  "${REPO_ROOT}/scripts/cloudflare/prebuild_bundle.py"
  --prefix "${R2_PREFIX}"
  publish
  --runtime-tag "${RUNTIME_TAG}"
  --metadata-json "${METADATA_JSON}"
)
if [[ -d "${WHEELHOUSE_DIR}" ]] && [[ -n "$(find "${WHEELHOUSE_DIR}" -type f -name '*.whl' -print -quit)" ]]; then
  PUBLISH_ARGS+=(--wheelhouse-dir "${WHEELHOUSE_DIR}")
fi
if [[ -n "${ENV_ARCHIVE}" ]]; then
  PUBLISH_ARGS+=(--env-archive "${ENV_ARCHIVE}")
fi
if [[ -n "${WEIGHTS_ARCHIVE}" ]]; then
  PUBLISH_ARGS+=(--weights-archive "${WEIGHTS_ARCHIVE}")
fi
if [[ -n "${IMAGE_ARCHIVE_RESOLVED}" ]]; then
  PUBLISH_ARGS+=(--image-archive "${IMAGE_ARCHIVE_RESOLVED}")
fi

publish_result="$("${PYTHON_BIN}" "${PUBLISH_ARGS[@]}")"
echo "${publish_result}"

echo "[prebuild] published runtime_tag=${RUNTIME_TAG}"
if [[ "${KEEP_TMP}" == "1" ]]; then
  echo "[prebuild] metadata=${METADATA_JSON}"
else
  echo "[prebuild] staging cleaned: ${TMP_DIR}"
fi
