#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

LONGLIVE2_RUNTIME_ENV_FILE="${LONGLIVE2_RUNTIME_ENV_FILE:-${SCRIPT_DIR}/.longlive2_runtime.env}"
if [[ -f "${LONGLIVE2_RUNTIME_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${LONGLIVE2_RUNTIME_ENV_FILE}"
fi

LONGLIVE2_PROFILE="${LONGLIVE2_PROFILE:-bf16_sp}"
LONGLIVE2_CACHE_DIR="${LONGLIVE2_CACHE_DIR:-${SCRIPT_DIR}/.cache/longlive2}"
LONGLIVE2_SRC_DIR="${LONGLIVE2_SRC_DIR:-${SCRIPT_DIR}/.vendors/LongLive2}"
LONGLIVE2_VENV_DIR="${LONGLIVE2_VENV_DIR:-${LONGLIVE2_SRC_DIR}/.venv}"
LONGLIVE2_PYTHON_BIN="${LONGLIVE2_PYTHON_BIN:-}"
LONGLIVE2_BF16_HF_REPO="${LONGLIVE2_BF16_HF_REPO:-Efficient-Large-Model/LongLive-2.0-5B}"
LONGLIVE2_NVFP4_S4_HF_REPO="${LONGLIVE2_NVFP4_S4_HF_REPO:-Efficient-Large-Model/LongLive-2.0-5B-NVFP4-S4}"
LONGLIVE2_NVFP4_S2_HF_REPO="${LONGLIVE2_NVFP4_S2_HF_REPO:-Efficient-Large-Model/LongLive-2.0-5B-NVFP4-S2}"
LONGLIVE2_WAN_HF_REPO="${LONGLIVE2_WAN_HF_REPO:-Wan-AI/Wan2.2-TI2V-5B}"
LONGLIVE2_INCLUDE_WAN="${LONGLIVE2_INCLUDE_WAN:-1}"
LONGLIVE2_DRY_RUN="${LONGLIVE2_DRY_RUN:-0}"

usage() {
  cat <<EOF
Usage:
  bash VideoDiffusion/download_longlive2_models.sh [options]

Options:
  --profile <bf16_sp|nvfp4_s4|nvfp4_s2>
                                  Model profile (default: ${LONGLIVE2_PROFILE})
  --cache-dir <path>            Cache root (default: ${LONGLIVE2_CACHE_DIR})
  --include-wan                 Also fetch Wan2.2-TI2V-5B base assets
  --no-include-wan              Skip Wan2.2 base assets; only valid for cache-only/debug use
  --dry-run                     Print commands and manifest path only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      LONGLIVE2_PROFILE="$2"
      shift 2
      ;;
    --cache-dir)
      LONGLIVE2_CACHE_DIR="$2"
      shift 2
      ;;
    --include-wan)
      LONGLIVE2_INCLUDE_WAN="1"
      shift
      ;;
    --no-include-wan)
      LONGLIVE2_INCLUDE_WAN="0"
      shift
      ;;
    --dry-run)
      LONGLIVE2_DRY_RUN="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${LONGLIVE2_PROFILE}" in
  bf16|bf16_sp)
    LONGLIVE2_PROFILE="bf16_sp"
    CHECKPOINT_REPO="${LONGLIVE2_BF16_HF_REPO}"
    CHECKPOINT_DIR="${LONGLIVE2_CACHE_DIR}/checkpoints/longlive2_5b"
    ;;
  nvfp4|nvfp4_s4|nvfp4_4step)
    LONGLIVE2_PROFILE="nvfp4_s4"
    CHECKPOINT_REPO="${LONGLIVE2_NVFP4_S4_HF_REPO}"
    CHECKPOINT_DIR="${LONGLIVE2_CACHE_DIR}/checkpoints/longlive2_5b_nvfp4_4step"
    ;;
  nvfp4_s2|nvfp4_2step)
    LONGLIVE2_PROFILE="nvfp4_s2"
    CHECKPOINT_REPO="${LONGLIVE2_NVFP4_S2_HF_REPO}"
    CHECKPOINT_DIR="${LONGLIVE2_CACHE_DIR}/checkpoints/longlive2_5b_nvfp4_2step"
    ;;
  *)
    echo "[error] unsupported LongLive2 profile '${LONGLIVE2_PROFILE}'." >&2
    exit 1
    ;;
esac

if [[ -z "${LONGLIVE2_PYTHON_BIN}" ]]; then
  if [[ -x "${LONGLIVE2_VENV_DIR}/bin/python" ]]; then
    LONGLIVE2_PYTHON_BIN="${LONGLIVE2_VENV_DIR}/bin/python"
  elif command_exists python3; then
    LONGLIVE2_PYTHON_BIN="python3"
  else
    echo "[error] python3 is required when the Hugging Face CLI is unavailable." >&2
    exit 1
  fi
fi

HF_DOWNLOAD_MODE=""
if command_exists hf; then
  HF_DOWNLOAD_MODE="cli"
  HF_CMD=(hf download)
elif command_exists huggingface-cli; then
  HF_DOWNLOAD_MODE="cli"
  HF_CMD=(huggingface-cli download)
else
  HF_DOWNLOAD_MODE="python"
fi

WAN_DIR="${LONGLIVE2_CACHE_DIR}/wan_models/Wan2.2-TI2V-5B"
MANIFEST="${LONGLIVE2_CACHE_DIR}/longlive2_model_manifest.json"

check_hf_python() {
  if [[ "${LONGLIVE2_DRY_RUN}" == "1" ]]; then
    return
  fi
  "${LONGLIVE2_PYTHON_BIN}" - <<'PY'
try:
    import huggingface_hub  # noqa: F401
except Exception as exc:
    print(
        "[error] Hugging Face CLI not found and Python fallback cannot import "
        f"huggingface_hub: {exc}",
        file=__import__("sys").stderr,
    )
    raise SystemExit(1)
PY
}

run_python_snapshot_download() {
  local repo="$1"
  local dest="$2"
  "${LONGLIVE2_PYTHON_BIN}" - "${repo}" "${dest}" <<'PY'
import inspect
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

repo, dest = sys.argv[1:]
Path(dest).mkdir(parents=True, exist_ok=True)
kwargs = {"repo_id": repo, "local_dir": dest}
if "local_dir_use_symlinks" in inspect.signature(snapshot_download).parameters:
    kwargs["local_dir_use_symlinks"] = False
snapshot_download(**kwargs)
PY
}

run_hf_download() {
  local repo="$1"
  local dest="$2"
  if [[ "${LONGLIVE2_DRY_RUN}" == "1" ]]; then
    if [[ "${HF_DOWNLOAD_MODE}" == "cli" ]]; then
      printf '[longlive2-download] dry-run: %q ' "${HF_CMD[@]}"
      printf '%q --local-dir %q\n' "${repo}" "${dest}"
    else
      printf '[longlive2-download] dry-run: %q - %q %q  # huggingface_hub.snapshot_download\n' "${LONGLIVE2_PYTHON_BIN}" "${repo}" "${dest}"
    fi
    return
  fi
  mkdir -p "${dest}"
  if [[ "${HF_DOWNLOAD_MODE}" == "cli" ]]; then
    "${HF_CMD[@]}" "${repo}" --local-dir "${dest}"
  else
    check_hf_python
    run_python_snapshot_download "${repo}" "${dest}"
  fi
}

run_hf_download "${CHECKPOINT_REPO}" "${CHECKPOINT_DIR}"
if [[ "${LONGLIVE2_INCLUDE_WAN}" == "1" ]]; then
  run_hf_download "${LONGLIVE2_WAN_HF_REPO}" "${WAN_DIR}"
fi

link_runtime_wan_dir() {
  if [[ "${LONGLIVE2_INCLUDE_WAN}" != "1" || "${LONGLIVE2_DRY_RUN}" == "1" ]]; then
    return
  fi
  if [[ ! -d "${LONGLIVE2_SRC_DIR}" ]]; then
    return
  fi
  mkdir -p "${LONGLIVE2_SRC_DIR}/wan_models"
  rm -rf "${LONGLIVE2_SRC_DIR}/wan_models/Wan2.2-TI2V-5B"
  ln -sfn "${WAN_DIR}" "${LONGLIVE2_SRC_DIR}/wan_models/Wan2.2-TI2V-5B"
}

link_runtime_wan_dir

mkdir -p "${LONGLIVE2_CACHE_DIR}"
"${LONGLIVE2_PYTHON_BIN}" - "${MANIFEST}" "${LONGLIVE2_PROFILE}" "${CHECKPOINT_REPO}" "${CHECKPOINT_DIR}" "${LONGLIVE2_INCLUDE_WAN}" "${LONGLIVE2_WAN_HF_REPO}" "${WAN_DIR}" "${LONGLIVE2_DRY_RUN}" "${HF_DOWNLOAD_MODE}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out, profile, ckpt_repo, ckpt_dir, include_wan, wan_repo, wan_dir, dry_run, download_mode = sys.argv[1:]

def describe_dir(path: str) -> dict:
    p = Path(path)
    if not p.exists():
        return {"path": str(p), "exists": False, "file_count": 0, "size_bytes": 0}
    files = [x for x in p.rglob("*") if x.is_file()]
    return {
        "path": str(p),
        "exists": True,
        "file_count": len(files),
        "size_bytes": sum(x.stat().st_size for x in files),
    }

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "profile": profile,
    "checkpoint_repo": ckpt_repo,
    "checkpoint_dir": describe_dir(ckpt_dir),
    "include_wan": include_wan == "1",
    "wan_repo": wan_repo if include_wan == "1" else "",
    "wan_dir": describe_dir(wan_dir) if include_wan == "1" else {},
    "dry_run": dry_run == "1",
    "download_mode": download_mode,
}
Path(out).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(f"[longlive2-download] manifest={out}")
PY
