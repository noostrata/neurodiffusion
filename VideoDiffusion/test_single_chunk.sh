#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

CONFIG_FILE_REL="${VIDEO_MAGE_CONFIG:-example/4.5B/4.5B_distill_quant_config.json}"
PROMPT_TEXT="${VIDEO_MAGE_PROMPT:-Neon city, cyberpunk alleyway, cinematic, 360p}"
VIDEO_MAGE_FP8="${VIDEO_MAGE_FP8:-auto}"
NPROC_PER_NODE="${VIDEO_MAGE_NPROC:-1}"
CUDA_VISIBLE_DEVICES="${VIDEO_MAGE_VISIBLE_DEVICES:-0}"
OUTPUT_FILE_REL="${VIDEO_MAGE_OUTPUT:-magi_try.mp4}"

VIDEO_MAGE_VENV_DIR="${VIDEO_MAGE_VENV_DIR:-${REPO_ROOT}/.venv}"

PYTHON_BIN="${VIDEO_MAGE_PYTHON_BIN:-}"
TORCHRUN_BIN="${VIDEO_MAGE_TORCHRUN_BIN:-}"

if [ -z "${PYTHON_BIN}" ]; then
  if [ -x "${VIDEO_MAGE_VENV_DIR}/bin/python" ]; then
    PYTHON_BIN="${VIDEO_MAGE_VENV_DIR}/bin/python"
  else
    PYTHON_BIN="python3"
  fi
fi

if [ -z "${TORCHRUN_BIN}" ]; then
  if [ -x "${VIDEO_MAGE_VENV_DIR}/bin/torchrun" ]; then
    TORCHRUN_BIN="${VIDEO_MAGE_VENV_DIR}/bin/torchrun"
  else
    TORCHRUN_BIN="torchrun"
  fi
fi

SCRIPT_DIR_MOUNTED="${REPO_ROOT}"
MAGE_DIR="${SCRIPT_DIR_MOUNTED}/MAGI-1"
MAGI_ENTRY_SCRIPT="${SCRIPT_DIR_MOUNTED}/MAGI-1/inference/pipeline/entry.py"

if [ ! -d "${SCRIPT_DIR_MOUNTED}/MAGI-1" ]; then
  echo "[ERROR] MAGI-1 directory not found. Run ./setup.sh first." >&2
  exit 1
fi

if [ -f "${CONFIG_FILE_REL}" ]; then
  CONFIG_FILE_PATH="${CONFIG_FILE_REL}"
elif [ -f "${SCRIPT_DIR_MOUNTED}/${CONFIG_FILE_REL}" ]; then
  CONFIG_FILE_PATH="${SCRIPT_DIR_MOUNTED}/${CONFIG_FILE_REL}"
elif [ -f "${MAGE_DIR}/${CONFIG_FILE_REL}" ]; then
  CONFIG_FILE_PATH="${MAGE_DIR}/${CONFIG_FILE_REL}"
else
  echo "[ERROR] Config not found: ${CONFIG_FILE_REL}" >&2
  echo "        Searched: ./, ${SCRIPT_DIR_MOUNTED}/, ${MAGE_DIR}/" >&2
  echo "        Set VIDEO_MAGE_CONFIG to an absolute path or a path relative to VideoDiffusion or VideoDiffusion/MAGI-1." >&2
  exit 1
fi

if [ "${OUTPUT_FILE_REL}" = "-" ]; then
  echo "[ERROR] OUTPUT path cannot be stdin/stdout ('-'). Set VIDEO_MAGE_OUTPUT to a file path." >&2
  exit 1
fi

if [[ "${TORCHRUN_BIN}" == *"/"* ]]; then
  if [ ! -x "${TORCHRUN_BIN}" ]; then
    echo "[ERROR] torchrun not found at '${TORCHRUN_BIN}'. Run ./setup.sh first or set VIDEO_MAGE_TORCHRUN_BIN." >&2
    exit 1
  fi
else
  if ! command -v "${TORCHRUN_BIN}" >/dev/null 2>&1; then
    echo "[ERROR] torchrun not found. Install PyTorch first (or run ./setup.sh)." >&2
    exit 1
  fi
fi

if [[ "${PYTHON_BIN}" == *"/"* ]]; then
  if [ ! -x "${PYTHON_BIN}" ]; then
    echo "[ERROR] python not found at '${PYTHON_BIN}'. Run ./setup.sh first or set VIDEO_MAGE_PYTHON_BIN." >&2
    exit 1
  fi
else
  if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[ERROR] python not found. Install python3 first." >&2
    exit 1
  fi
fi

if [ ! -f "${MAGI_ENTRY_SCRIPT}" ]; then
  echo "[ERROR] Entry script not found: ${MAGI_ENTRY_SCRIPT}" >&2
  exit 1
fi

if [ -n "${CUDA_VISIBLE_DEVICES}" ]; then
  IFS=',' read -r -a _visible_devices <<< "${CUDA_VISIBLE_DEVICES}"
  GPU_COUNT="${#_visible_devices[@]}"
else
  GPU_COUNT=1
fi

if [ "${NPROC_PER_NODE}" = "auto" ] || [ "${NPROC_PER_NODE}" = "AUTO" ]; then
  NPROC_PER_NODE="${GPU_COUNT}"
fi

if ! [[ "${NPROC_PER_NODE}" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] VIDEO_MAGE_NPROC must be an integer or 'auto'. Got: ${NPROC_PER_NODE}" >&2
  exit 1
fi

if [ "${NPROC_PER_NODE}" -le 0 ]; then
  echo "[ERROR] VIDEO_MAGE_NPROC must be >= 1. Got: ${NPROC_PER_NODE}" >&2
  exit 1
fi

if [ "${NPROC_PER_NODE}" -gt "${GPU_COUNT}" ]; then
  echo "[ERROR] VIDEO_MAGE_NPROC=${NPROC_PER_NODE} exceeds available CUDA_VISIBLE_DEVICES count=${GPU_COUNT}." >&2
  echo "Set CUDA_VISIBLE_DEVICES to expose enough devices or lower VIDEO_MAGE_NPROC." >&2
  exit 1
fi

if [ "${NPROC_PER_NODE}" -gt 1 ]; then
  echo "[info] Using ${NPROC_PER_NODE}-GPU run. Set VIDEO_MAGE_NPROC=1 for cheaper single-GPU smoke tests."
fi

cat <<EOF2
[info] Running one-off MAGI test
       config: ${CONFIG_FILE_PATH}
       output: ${OUTPUT_FILE_REL}
       nproc : ${NPROC_PER_NODE}
       devices: ${CUDA_VISIBLE_DEVICES}
       prompt: ${PROMPT_TEXT}
EOF2

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES}"

RESOLVED_CONFIG_PATH="${SCRIPT_DIR_MOUNTED}/.tmp/video_single_chunk_$(date +%s)_${RANDOM}.json"
mkdir -p "${SCRIPT_DIR_MOUNTED}/.tmp"

${PYTHON_BIN} - "$CONFIG_FILE_PATH" "$RESOLVED_CONFIG_PATH" "$MAGE_DIR" <<'PY'
import json
import os
import sys

src_path, dst_path, mage_dir = sys.argv[1], sys.argv[2], sys.argv[3]
fp8_override = os.environ.get("VIDEO_MAGE_FP8", "auto").strip().lower()

with open(src_path, "r", encoding="utf-8") as f:
    config = json.load(f)

runtime_config = config.get("runtime_config", {})
for key in ("load", "t5_pretrained", "vae_pretrained"):
    raw = runtime_config.get(key)
    if isinstance(raw, str) and raw.startswith("./"):
        runtime_config[key] = os.path.join(mage_dir, raw)

def _get_int_env(*names: str):
    for name in names:
        raw = os.environ.get(name)
        if raw is None or str(raw).strip() == "":
            continue
        try:
            return int(str(raw).strip())
        except Exception:
            continue
    return None

# Optional throughput/cost overrides without editing vendor configs.
for env_names, cfg_key in (
    (("VIDEO_MAGE_NUM_STEPS", "MAGI_NUM_STEPS"), "num_steps"),
    (("VIDEO_MAGE_NUM_FRAMES", "MAGI_NUM_FRAMES"), "num_frames"),
    (("VIDEO_MAGE_VIDEO_SIZE_H", "MAGI_VIDEO_SIZE_H"), "video_size_h"),
    (("VIDEO_MAGE_VIDEO_SIZE_W", "MAGI_VIDEO_SIZE_W"), "video_size_w"),
    (("VIDEO_MAGE_WINDOW_SIZE", "MAGI_WINDOW_SIZE"), "window_size"),
):
    v = _get_int_env(*env_names)
    if v is not None:
        runtime_config[cfg_key] = v

engine_config = config.get("engine_config", {})
if fp8_override in {"0", "false", "off", "no"}:
    engine_config["fp8_quant"] = False
elif fp8_override in {"1", "true", "on", "yes"}:
    engine_config["fp8_quant"] = True
elif fp8_override in {"auto", ""}:
    try:
        import torch

        if torch.cuda.is_available() and torch.cuda.device_count() > 0:
            caps = [torch.cuda.get_device_capability(i) for i in range(torch.cuda.device_count())]
            has_sm90 = any((major >= 9) for major, _minor in caps)
            engine_config["fp8_quant"] = bool(has_sm90)
        else:
            # Default to the shipped config when detection is ambiguous.
            engine_config["fp8_quant"] = config.get("engine_config", {}).get("fp8_quant", True)
    except Exception:
        # Preserve existing behavior if device probing fails in non-interactive contexts.
        engine_config["fp8_quant"] = config.get("engine_config", {}).get("fp8_quant", True)
else:
    raise SystemExit(f"Unsupported VIDEO_MAGE_FP8='{fp8_override}'. Use 0/1/true/false/auto.")

print(f"[info] fp8_quant={engine_config.get('fp8_quant')} (VIDEO_MAGE_FP8={fp8_override})")
config["engine_config"] = engine_config

config["runtime_config"] = runtime_config

with open(dst_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=4)
PY

if [ "${OUTPUT_FILE_REL:0:1}" = "/" ]; then
  OUTPUT_FILE_PATH="${OUTPUT_FILE_REL}"
else
  # Default to writing into the tracked VideoDiffusion/ folder (outside vendor repo).
  # This makes it easy to scp back and avoids touching the MAGI-1 checkout.
  OUTPUT_FILE_PATH="${SCRIPT_DIR_MOUNTED}/${OUTPUT_FILE_REL}"
fi
mkdir -p "$(dirname "${OUTPUT_FILE_PATH}")"

cd "${MAGE_DIR}"
export PYTHONPATH=".:${PYTHONPATH:-}"

${TORCHRUN_BIN} --standalone --nproc_per_node="${NPROC_PER_NODE}" \
  inference/pipeline/entry.py \
  --config_file "${RESOLVED_CONFIG_PATH}" \
  --mode t2v \
  --prompt "${PROMPT_TEXT}" \
  --output_path "${OUTPUT_FILE_PATH}"

cat <<EOF2
[ok] Test complete.
    file: ${OUTPUT_FILE_PATH}
EOF2
