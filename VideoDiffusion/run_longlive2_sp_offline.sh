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

LONGLIVE2_SRC_DIR="${LONGLIVE2_SRC_DIR:-${SCRIPT_DIR}/.vendors/LongLive2}"
LONGLIVE2_VENV_DIR="${LONGLIVE2_VENV_DIR:-${LONGLIVE2_SRC_DIR}/.venv}"
LONGLIVE2_CACHE_DIR="${LONGLIVE2_CACHE_DIR:-${SCRIPT_DIR}/.cache/longlive2}"
LONGLIVE2_PROFILE="${LONGLIVE2_PROFILE:-bf16_sp}"
LONGLIVE2_RUN_ID="${LONGLIVE2_RUN_ID:-longlive2_sp_$(date -u +%Y%m%dT%H%M%SZ)}"
LONGLIVE2_RUN_DIR="${LONGLIVE2_RUN_DIR:-${SCRIPT_DIR}/.tmp/${LONGLIVE2_RUN_ID}}"
LONGLIVE2_CONFIG_PATH="${LONGLIVE2_CONFIG_PATH:-${LONGLIVE2_RUN_DIR}/longlive2_inference.yaml}"
LONGLIVE2_PROMPT_PATH="${LONGLIVE2_PROMPT_PATH:-${LONGLIVE2_RUN_DIR}/prompt.txt}"
LONGLIVE2_OUTPUT_DIR="${LONGLIVE2_OUTPUT_DIR:-${LONGLIVE2_RUN_DIR}/videos}"
LONGLIVE2_PROMPT="${LONGLIVE2_PROMPT:-A reactive neon tunnel breathes with smooth cinematic motion.}"
LONGLIVE2_SCHEDULE_CSV="${LONGLIVE2_SCHEDULE_CSV:-}"
LONGLIVE2_SHOT_PROMPTS="${LONGLIVE2_SHOT_PROMPTS:-}"
LONGLIVE2_SHOT_DURATIONS="${LONGLIVE2_SHOT_DURATIONS:-}"
LONGLIVE2_HEIGHT="${LONGLIVE2_HEIGHT:-704}"
LONGLIVE2_WIDTH="${LONGLIVE2_WIDTH:-1280}"
LONGLIVE2_FRAMES="${LONGLIVE2_FRAMES:-128}"
LONGLIVE2_SP_SIZE="${LONGLIVE2_SP_SIZE:-2}"
LONGLIVE2_DP_SIZE="${LONGLIVE2_DP_SIZE:-1}"
LONGLIVE2_SAMPLING_STEPS="${LONGLIVE2_SAMPLING_STEPS:-}"
LONGLIVE2_GENERATOR_CKPT="${LONGLIVE2_GENERATOR_CKPT:-}"
LONGLIVE2_LORA_CKPT="${LONGLIVE2_LORA_CKPT:-}"
LONGLIVE2_VAE_DEVICE="${LONGLIVE2_VAE_DEVICE:-}"
LONGLIVE2_TORCH_COMPILE="${LONGLIVE2_TORCH_COMPILE:-false}"
LONGLIVE2_CUDA_VISIBLE_DEVICES="${LONGLIVE2_CUDA_VISIBLE_DEVICES:-}"
LONGLIVE2_DRY_RUN="${LONGLIVE2_DRY_RUN:-0}"
LONGLIVE2_SKIP_CONFIG_GENERATION="${LONGLIVE2_SKIP_CONFIG_GENERATION:-0}"
LONGLIVE2_STRICT_PROFILE_GPU_MATCH="${LONGLIVE2_STRICT_PROFILE_GPU_MATCH:-0}"

usage() {
  cat <<EOF
Usage:
  bash VideoDiffusion/run_longlive2_sp_offline.sh [options]

Options:
  --profile <bf16_sp|nvfp4_s2>  Runtime profile (default: ${LONGLIVE2_PROFILE})
  --src-dir <path>              LongLive2 checkout (default: ${LONGLIVE2_SRC_DIR})
  --run-dir <path>              Run artifact dir (default: ${LONGLIVE2_RUN_DIR})
  --config <path>               Use or generate config path
  --no-generate-config          Use --config as-is
  --prompt <text>               Prompt for generated prompt file
  --schedule-csv <path>         EEG schedule CSV converted to LongLive2 prompt blocks
  --shot-prompt <text>          Multi-shot prompt; may be repeated
  --shot-duration <blocks>      Block count for each --shot-prompt
  --height <pixels>             Output height, divisible by 16 (default: ${LONGLIVE2_HEIGHT})
  --width <pixels>              Output width, divisible by 16 (default: ${LONGLIVE2_WIDTH})
  --frames <count>              Output frames, divisible by 8 (default: ${LONGLIVE2_FRAMES})
  --sp-size <count>             Sequence parallel size (default: ${LONGLIVE2_SP_SIZE})
  --dp-size <count>             Data parallel groups (default: ${LONGLIVE2_DP_SIZE})
  --generator-ckpt <path>       Generator checkpoint path inside LongLive2 runtime
  --lora-ckpt <path>            Optional LoRA checkpoint path
  --cuda-visible-devices <csv>  CUDA_VISIBLE_DEVICES override
  --strict-profile-gpu-match    Fail when NVFP4 profile is used on non-Blackwell GPU names
  --dry-run                     Print plan without launching torchrun
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      LONGLIVE2_PROFILE="$2"
      shift 2
      ;;
    --src-dir)
      LONGLIVE2_SRC_DIR="$2"
      shift 2
      ;;
    --run-dir)
      LONGLIVE2_RUN_DIR="$2"
      LONGLIVE2_CONFIG_PATH="$2/longlive2_inference.yaml"
      LONGLIVE2_PROMPT_PATH="$2/prompt.txt"
      LONGLIVE2_OUTPUT_DIR="$2/videos"
      shift 2
      ;;
    --config)
      LONGLIVE2_CONFIG_PATH="$2"
      shift 2
      ;;
    --no-generate-config)
      LONGLIVE2_SKIP_CONFIG_GENERATION="1"
      shift
      ;;
    --prompt)
      LONGLIVE2_PROMPT="$2"
      shift 2
      ;;
    --schedule-csv)
      LONGLIVE2_SCHEDULE_CSV="$2"
      shift 2
      ;;
    --shot-prompt)
      if [[ -n "${LONGLIVE2_SHOT_PROMPTS}" ]]; then
        LONGLIVE2_SHOT_PROMPTS="${LONGLIVE2_SHOT_PROMPTS}"$'\n'"$2"
      else
        LONGLIVE2_SHOT_PROMPTS="$2"
      fi
      shift 2
      ;;
    --shot-duration)
      if [[ -n "${LONGLIVE2_SHOT_DURATIONS}" ]]; then
        LONGLIVE2_SHOT_DURATIONS="${LONGLIVE2_SHOT_DURATIONS},$2"
      else
        LONGLIVE2_SHOT_DURATIONS="$2"
      fi
      shift 2
      ;;
    --height)
      LONGLIVE2_HEIGHT="$2"
      shift 2
      ;;
    --width)
      LONGLIVE2_WIDTH="$2"
      shift 2
      ;;
    --frames)
      LONGLIVE2_FRAMES="$2"
      shift 2
      ;;
    --sp-size)
      LONGLIVE2_SP_SIZE="$2"
      shift 2
      ;;
    --dp-size)
      LONGLIVE2_DP_SIZE="$2"
      shift 2
      ;;
    --sampling-steps)
      LONGLIVE2_SAMPLING_STEPS="$2"
      shift 2
      ;;
    --generator-ckpt)
      LONGLIVE2_GENERATOR_CKPT="$2"
      shift 2
      ;;
    --lora-ckpt)
      LONGLIVE2_LORA_CKPT="$2"
      shift 2
      ;;
    --cuda-visible-devices)
      LONGLIVE2_CUDA_VISIBLE_DEVICES="$2"
      shift 2
      ;;
    --strict-profile-gpu-match)
      LONGLIVE2_STRICT_PROFILE_GPU_MATCH="1"
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

abs_path() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

LONGLIVE2_RUN_DIR="$(abs_path "${LONGLIVE2_RUN_DIR}")"
LONGLIVE2_SRC_DIR="$(abs_path "${LONGLIVE2_SRC_DIR}")"
LONGLIVE2_VENV_DIR="$(abs_path "${LONGLIVE2_VENV_DIR}")"
LONGLIVE2_CACHE_DIR="$(abs_path "${LONGLIVE2_CACHE_DIR}")"
LONGLIVE2_CONFIG_PATH="$(abs_path "${LONGLIVE2_CONFIG_PATH}")"
LONGLIVE2_PROMPT_PATH="$(abs_path "${LONGLIVE2_PROMPT_PATH}")"
LONGLIVE2_OUTPUT_DIR="$(abs_path "${LONGLIVE2_OUTPUT_DIR}")"
if [[ -n "${LONGLIVE2_SCHEDULE_CSV}" ]]; then
  LONGLIVE2_SCHEDULE_CSV="$(abs_path "${LONGLIVE2_SCHEDULE_CSV}")"
fi

mkdir -p "${LONGLIVE2_RUN_DIR}" "${LONGLIVE2_OUTPUT_DIR}"
RUN_LOG="${LONGLIVE2_RUN_DIR}/torchrun.log"
GPU_TELEMETRY="${LONGLIVE2_RUN_DIR}/gpu_telemetry.csv"
PLAN_JSON="${LONGLIVE2_RUN_DIR}/launch_plan.json"

if [[ -n "${LONGLIVE2_SCHEDULE_CSV}" || -n "${LONGLIVE2_SHOT_PROMPTS}" ]]; then
  case "${LONGLIVE2_PROMPT_PATH}" in
    *.txt)
      LONGLIVE2_PROMPT_PATH="${LONGLIVE2_RUN_DIR}/prompt_schedule"
      ;;
  esac
fi

find_first_checkpoint() {
  local root="$1"
  shift
  [[ -d "${root}" ]] || return 0
  find "${root}" -type f \( "$@" \) 2>/dev/null | sort | head -n1
}

if [[ -z "${LONGLIVE2_GENERATOR_CKPT}" ]]; then
  case "${LONGLIVE2_PROFILE}" in
    nvfp4_s2|nvfp4_2step)
      LONGLIVE2_GENERATOR_CKPT="$(
        find_first_checkpoint "${LONGLIVE2_CACHE_DIR}/checkpoints/longlive2_5b_nvfp4_2step" \
          -name 'generator*.pt' -o -name 'model_4o6.pt' -o -name 'model_te.pt' -o -name '*.pt'
      )"
      ;;
    nvfp4|nvfp4_s4|nvfp4_4step)
      LONGLIVE2_GENERATOR_CKPT="$(
        find_first_checkpoint "${LONGLIVE2_CACHE_DIR}/checkpoints/longlive2_5b_nvfp4_4step" \
          -name 'generator*.pt' -o -name 'model_4o6.pt' -o -name 'model_te.pt' -o -name '*.pt'
      )"
      ;;
    *)
      LONGLIVE2_GENERATOR_CKPT="$(
        find_first_checkpoint "${LONGLIVE2_CACHE_DIR}/checkpoints/longlive2_5b" \
          -name '*generator*.pt' -o -name '*base*.pt' -o -name 'model_bf16.pt' -o -name '*.pt'
      )"
      ;;
  esac
fi
if [[ -z "${LONGLIVE2_LORA_CKPT}" ]]; then
  LONGLIVE2_LORA_CKPT="$(
    find_first_checkpoint "${LONGLIVE2_CACHE_DIR}" -name '*lora*.pt' -o -name '*LoRA*.pt'
  )"
fi

if [[ "${LONGLIVE2_SKIP_CONFIG_GENERATION}" != "1" ]]; then
  config_args=(
    generate
    --profile "${LONGLIVE2_PROFILE}"
    --out "${LONGLIVE2_CONFIG_PATH}"
    --prompt-path "${LONGLIVE2_PROMPT_PATH}"
    --output-folder "${LONGLIVE2_OUTPUT_DIR}"
    --prompt "${LONGLIVE2_PROMPT}"
    --write-prompt
    --overwrite-prompt
    --height "${LONGLIVE2_HEIGHT}"
    --width "${LONGLIVE2_WIDTH}"
    --frames "${LONGLIVE2_FRAMES}"
    --sp-size "${LONGLIVE2_SP_SIZE}"
    --dp-size "${LONGLIVE2_DP_SIZE}"
    --torch-compile "${LONGLIVE2_TORCH_COMPILE}"
  )
  if [[ -n "${LONGLIVE2_SAMPLING_STEPS}" ]]; then
    config_args+=(--sampling-steps "${LONGLIVE2_SAMPLING_STEPS}")
  fi
  if [[ -n "${LONGLIVE2_GENERATOR_CKPT}" ]]; then
    config_args+=(--generator-ckpt "${LONGLIVE2_GENERATOR_CKPT}")
  fi
  if [[ -n "${LONGLIVE2_LORA_CKPT}" ]]; then
    config_args+=(--lora-ckpt "${LONGLIVE2_LORA_CKPT}")
  fi
  if [[ -n "${LONGLIVE2_VAE_DEVICE}" ]]; then
    config_args+=(--vae-device "${LONGLIVE2_VAE_DEVICE}")
  fi
  if [[ -n "${LONGLIVE2_SCHEDULE_CSV}" ]]; then
    config_args+=(--schedule-csv "${LONGLIVE2_SCHEDULE_CSV}")
  fi
  if [[ -n "${LONGLIVE2_SHOT_PROMPTS}" ]]; then
    while IFS= read -r shot_prompt; do
      [[ -z "${shot_prompt}" ]] && continue
      config_args+=(--shot-prompt "${shot_prompt}")
    done <<<"${LONGLIVE2_SHOT_PROMPTS}"
  fi
  if [[ -n "${LONGLIVE2_SHOT_DURATIONS}" ]]; then
    IFS=',' read -r -a shot_duration_values <<<"${LONGLIVE2_SHOT_DURATIONS}"
    for shot_duration in "${shot_duration_values[@]}"; do
      [[ -z "${shot_duration}" ]] && continue
      config_args+=(--shot-duration "${shot_duration}")
    done
  fi
  python3 "${SCRIPT_DIR}/longlive2_config.py" "${config_args[@]}" --print-json >"${LONGLIVE2_RUN_DIR}/config_generation.json"
fi

NPROC=$((LONGLIVE2_SP_SIZE * LONGLIVE2_DP_SIZE))
ENTRYPOINT="inference_sp.py"
if [[ "${NPROC}" -le 1 ]]; then
  ENTRYPOINT="inference.py"
fi
PY="${LONGLIVE2_VENV_DIR}/bin/python"
if [[ ! -x "${PY}" ]]; then
  PY="python3"
fi
TORCHRUN="${LONGLIVE2_VENV_DIR}/bin/torchrun"
if [[ ! -x "${TORCHRUN}" ]]; then
  TORCHRUN="${PY} -m torch.distributed.run"
fi

if command_exists nvidia-smi; then
  GPU_NAMES="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
else
  GPU_NAMES="unknown"
fi
if [[ "${LONGLIVE2_PROFILE}" == nvfp4* && "${GPU_NAMES}" != *"B200"* && "${GPU_NAMES}" != *"GB200"* && "${GPU_NAMES}" != *"RTX 5090"* && "${GPU_NAMES}" != *"RTX5090"* ]]; then
  message="NVFP4 profile selected on GPU(s) '${GPU_NAMES}'. LongLive2's published max-FPS NVFP4 path is Blackwell-oriented; Hopper testing should normally start with bf16_sp sequence parallel."
  if [[ "${LONGLIVE2_STRICT_PROFILE_GPU_MATCH}" == "1" ]]; then
    echo "[error] ${message}" >&2
    exit 1
  fi
  echo "[warn] ${message}" >&2
fi

python3 - "${PLAN_JSON}" "${LONGLIVE2_RUN_ID}" "${LONGLIVE2_SRC_DIR}" "${LONGLIVE2_CONFIG_PATH}" "${ENTRYPOINT}" "${NPROC}" "${LONGLIVE2_CUDA_VISIBLE_DEVICES}" "${LONGLIVE2_PROFILE}" "${GPU_NAMES}" "${LONGLIVE2_GENERATOR_CKPT}" "${LONGLIVE2_LORA_CKPT}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out, run_id, src_dir, config_path, entrypoint, nproc, devices, profile, gpu_names, generator_ckpt, lora_ckpt = sys.argv[1:]
payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "run_id": run_id,
    "src_dir": src_dir,
    "config_path": config_path,
    "entrypoint": entrypoint,
    "nproc_per_node": int(nproc),
    "cuda_visible_devices": devices,
    "profile": profile,
    "gpu_names": gpu_names,
    "generator_ckpt": generator_ckpt,
    "lora_ckpt": lora_ckpt,
}
Path(out).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

if [[ "${LONGLIVE2_DRY_RUN}" == "1" ]]; then
  video_log "LongLive2 dry-run plan written to ${PLAN_JSON}."
  if [[ "${NPROC}" -gt 1 ]]; then
    echo "cd ${LONGLIVE2_SRC_DIR} && ${TORCHRUN} --standalone --nnodes=1 --nproc_per_node=${NPROC} ${ENTRYPOINT} --config_path ${LONGLIVE2_CONFIG_PATH}"
  else
    echo "cd ${LONGLIVE2_SRC_DIR} && ${PY} ${ENTRYPOINT} --config_path ${LONGLIVE2_CONFIG_PATH}"
  fi
  exit 0
fi

if [[ ! -d "${LONGLIVE2_SRC_DIR}" ]]; then
  echo "[error] LongLive2 source dir not found: ${LONGLIVE2_SRC_DIR}" >&2
  exit 1
fi

telemetry_pid=""
cleanup() {
  if [[ -n "${telemetry_pid}" ]]; then
    kill "${telemetry_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if command_exists nvidia-smi; then
  nvidia-smi --query-gpu=timestamp,index,name,utilization.gpu,memory.used,memory.total --format=csv -l 1 >"${GPU_TELEMETRY}" 2>/dev/null &
  telemetry_pid="$!"
fi

video_log "Launching LongLive2 ${ENTRYPOINT} with nproc=${NPROC}."
(
  cd "${LONGLIVE2_SRC_DIR}"
  if [[ -n "${LONGLIVE2_CUDA_VISIBLE_DEVICES}" ]]; then
    export CUDA_VISIBLE_DEVICES="${LONGLIVE2_CUDA_VISIBLE_DEVICES}"
  fi
  if [[ "${NPROC}" -gt 1 ]]; then
    # shellcheck disable=SC2086
    ${TORCHRUN} --standalone --nnodes=1 --nproc_per_node="${NPROC}" "${ENTRYPOINT}" --config_path "${LONGLIVE2_CONFIG_PATH}"
  else
    "${PY}" "${ENTRYPOINT}" --config_path "${LONGLIVE2_CONFIG_PATH}"
  fi
) 2>&1 | tee "${RUN_LOG}"

python3 "${SCRIPT_DIR}/longlive2_run_report.py" report --run-dir "${LONGLIVE2_RUN_DIR}" --config "${LONGLIVE2_CONFIG_PATH}"
