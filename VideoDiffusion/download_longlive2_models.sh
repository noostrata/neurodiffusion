#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

LONGLIVE2_PROFILE="${LONGLIVE2_PROFILE:-bf16_sp}"
LONGLIVE2_CACHE_DIR="${LONGLIVE2_CACHE_DIR:-${SCRIPT_DIR}/.cache/longlive2}"
LONGLIVE2_BF16_HF_REPO="${LONGLIVE2_BF16_HF_REPO:-Efficient-Large-Model/LongLive-2.0-5B}"
LONGLIVE2_NVFP4_S4_HF_REPO="${LONGLIVE2_NVFP4_S4_HF_REPO:-Efficient-Large-Model/LongLive-2.0-5B-NVFP4-S4}"
LONGLIVE2_NVFP4_S2_HF_REPO="${LONGLIVE2_NVFP4_S2_HF_REPO:-Efficient-Large-Model/LongLive-2.0-5B-NVFP4-S2}"
LONGLIVE2_WAN_HF_REPO="${LONGLIVE2_WAN_HF_REPO:-Wan-AI/Wan2.2-TI2V-5B}"
LONGLIVE2_INCLUDE_WAN="${LONGLIVE2_INCLUDE_WAN:-0}"
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

if command_exists hf; then
  HF_CMD=(hf download)
elif command_exists huggingface-cli; then
  HF_CMD=(huggingface-cli download)
else
  echo "[error] Hugging Face CLI not found. Install 'hf' or 'huggingface-cli'." >&2
  exit 1
fi

WAN_DIR="${LONGLIVE2_CACHE_DIR}/wan_models/Wan2.2-TI2V-5B"
MANIFEST="${LONGLIVE2_CACHE_DIR}/longlive2_model_manifest.json"

run_hf_download() {
  local repo="$1"
  local dest="$2"
  if [[ "${LONGLIVE2_DRY_RUN}" == "1" ]]; then
    printf '[longlive2-download] dry-run: %q ' "${HF_CMD[@]}"
    printf '%q --local-dir %q\n' "${repo}" "${dest}"
    return
  fi
  mkdir -p "${dest}"
  "${HF_CMD[@]}" "${repo}" --local-dir "${dest}"
}

run_hf_download "${CHECKPOINT_REPO}" "${CHECKPOINT_DIR}"
if [[ "${LONGLIVE2_INCLUDE_WAN}" == "1" ]]; then
  run_hf_download "${LONGLIVE2_WAN_HF_REPO}" "${WAN_DIR}"
fi

mkdir -p "${LONGLIVE2_CACHE_DIR}"
python3 - "${MANIFEST}" "${LONGLIVE2_PROFILE}" "${CHECKPOINT_REPO}" "${CHECKPOINT_DIR}" "${LONGLIVE2_INCLUDE_WAN}" "${LONGLIVE2_WAN_HF_REPO}" "${WAN_DIR}" "${LONGLIVE2_DRY_RUN}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out, profile, ckpt_repo, ckpt_dir, include_wan, wan_repo, wan_dir, dry_run = sys.argv[1:]

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
}
Path(out).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(f"[longlive2-download] manifest={out}")
PY
