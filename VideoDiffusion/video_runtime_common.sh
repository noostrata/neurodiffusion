#!/usr/bin/env bash
set -euo pipefail

video_log() {
  printf '[video-runtime] %s\n' "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

to_lower() {
  printf '%s\n' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

normalize_video_model() {
  local raw="${1:-magi}"
  local model
  model="$(to_lower "${raw}")"
  case "${model}" in
    magi|krea|scope|longlive)
      if [[ "${model}" == "longlive" ]]; then
        printf 'scope\n'
        return 0
      fi
      printf '%s\n' "${model}"
      ;;
    *)
      echo "[error] Unsupported VIDEO_MODEL='${raw}'. Use magi, krea, scope, or longlive." >&2
      return 1
      ;;
  esac
}

normalize_attn_backend() {
  local raw="${1:-auto}"
  local backend
  backend="$(to_lower "${raw}")"
  case "${backend}" in
    auto|sage|flash|sdpa)
      printf '%s\n' "${backend}"
      ;;
    *)
      echo "[error] Unsupported ATTN_BACKEND='${raw}'. Use auto|sage|flash|sdpa." >&2
      return 1
      ;;
  esac
}

detect_primary_gpu_name() {
  if ! command_exists nvidia-smi; then
    printf 'unknown\n'
    return 0
  fi

  local name
  name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 | tr -d '\r' || true)"
  if [[ -z "${name}" ]]; then
    printf 'unknown\n'
    return 0
  fi
  printf '%s\n' "${name}"
}

resolve_attn_backend() {
  local requested
  requested="$(normalize_attn_backend "${1:-auto}")"
  if [[ "${requested}" != "auto" ]]; then
    printf '%s\n' "${requested}"
    return 0
  fi

  local gpu
  gpu="$(detect_primary_gpu_name)"
  local gpu_lc
  gpu_lc="$(to_lower "${gpu}")"

  if [[ "${gpu_lc}" == *"b200"* ]]; then
    printf 'flash\n'
    return 0
  fi

  if [[ "${gpu_lc}" == *"h100"* ]] || [[ "${gpu_lc}" == *"h200"* ]] || [[ "${gpu_lc}" == *"gh200"* ]] || \
     [[ "${gpu_lc}" == *"l40s"* ]] || [[ "${gpu_lc}" == *"rtx"* ]] || [[ "${gpu_lc}" == *"ada"* ]] || \
     [[ "${gpu_lc}" == *"a6000"* ]] || [[ "${gpu_lc}" == *"rtx 6000"* ]] || [[ "${gpu_lc}" == *"rtx6000"* ]]; then
    printf 'sage\n'
    return 0
  fi

  printf 'sdpa\n'
}

default_tiers_for_model() {
  local model
  model="$(normalize_video_model "${1:-magi}")"
  if [[ "${model}" == "krea" ]]; then
    printf 'krea-b200-flashattn,krea-hopper-sage,krea-ampere-sage-or-sdpa\n'
  elif [[ "${model}" == "scope" ]]; then
    printf 'scope-longlive-24gb,scope-longlive-hopper\n'
  else
    printf '4.5b,24b\n'
  fi
}
