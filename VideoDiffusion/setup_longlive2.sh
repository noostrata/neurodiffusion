#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

LONGLIVE2_REPO_URL="${LONGLIVE2_REPO_URL:-https://github.com/NVlabs/LongLive.git}"
LONGLIVE2_REPO_REF="${LONGLIVE2_REPO_REF:-536d1b9a3563b078bea378aa968416543fd9d669}"
LONGLIVE2_SRC_DIR="${LONGLIVE2_SRC_DIR:-${SCRIPT_DIR}/.vendors/LongLive2}"
LONGLIVE2_PROFILE="${LONGLIVE2_PROFILE:-bf16_sp}"
LONGLIVE2_SKIP_BUILD="${LONGLIVE2_SKIP_BUILD:-0}"
LONGLIVE2_RUNTIME_ENV_FILE="${LONGLIVE2_RUNTIME_ENV_FILE:-${SCRIPT_DIR}/.longlive2_runtime.env}"
LONGLIVE2_VENV_DIR="${LONGLIVE2_VENV_DIR:-${LONGLIVE2_SRC_DIR}/.venv}"
LONGLIVE2_CUDA_ARCHS="${LONGLIVE2_CUDA_ARCHS:-}"
LONGLIVE2_FLASH_ATTN_CUDA_ARCHS="${LONGLIVE2_FLASH_ATTN_CUDA_ARCHS:-}"
LONGLIVE2_MAX_JOBS="${LONGLIVE2_MAX_JOBS:-}"
LONGLIVE2_NVCC_THREADS="${LONGLIVE2_NVCC_THREADS:-}"
LONGLIVE2_BUILD_FLASH_ATTN_FROM_SOURCE="${LONGLIVE2_BUILD_FLASH_ATTN_FROM_SOURCE:-}"
LONGLIVE2_FLASH_ATTN_REPO_URL="${LONGLIVE2_FLASH_ATTN_REPO_URL:-https://github.com/Dao-AILab/flash-attention.git}"
LONGLIVE2_FLASH_ATTN_REF="${LONGLIVE2_FLASH_ATTN_REF:-v2.8.3}"
LONGLIVE2_TRANSFORMERS_VERSION="${LONGLIVE2_TRANSFORMERS_VERSION:-4.57.3}"
LONGLIVE2_EXTRA_PIP_PACKAGES="${LONGLIVE2_EXTRA_PIP_PACKAGES:-decord}"
LONGLIVE2_NVFP4_TORCH_VERSION="${LONGLIVE2_NVFP4_TORCH_VERSION:-2.10.0}"
LONGLIVE2_NVFP4_TORCHVISION_VERSION="${LONGLIVE2_NVFP4_TORCHVISION_VERSION:-0.25.0}"

usage() {
  cat <<EOF
Usage:
  bash VideoDiffusion/setup_longlive2.sh [options]

Options:
  --profile <bf16_sp|nvfp4_s4|nvfp4_s2>
                                  Runtime profile (default: ${LONGLIVE2_PROFILE})
  --repo-ref <ref>              LongLive2 git ref (default: ${LONGLIVE2_REPO_REF})
  --src-dir <path>              Vendor checkout path (default: ${LONGLIVE2_SRC_DIR})
  --venv-dir <path>             Python venv path (default: ${LONGLIVE2_VENV_DIR})
  --skip-build                  Clone/config only; do not install dependencies
  --cuda-archs <archs>          Optional CUDA_ARCHS for NVFP4 extension builds
  --flash-attn-cuda-archs <archs>
                                  Optional FLASH_ATTN_CUDA_ARCHS for flash-attention source builds
  --max-jobs <count>            Optional MAX_JOBS for native extension builds
  --nvcc-threads <count>        Optional NVCC_THREADS for native extension builds
  --build-flash-attn-source     Build flash-attention from pinned source
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      LONGLIVE2_PROFILE="$2"
      shift 2
      ;;
    --repo-ref)
      LONGLIVE2_REPO_REF="$2"
      shift 2
      ;;
    --src-dir)
      LONGLIVE2_SRC_DIR="$2"
      shift 2
      ;;
    --venv-dir)
      LONGLIVE2_VENV_DIR="$2"
      shift 2
      ;;
    --skip-build)
      LONGLIVE2_SKIP_BUILD="1"
      shift
      ;;
    --cuda-archs)
      LONGLIVE2_CUDA_ARCHS="$2"
      shift 2
      ;;
    --flash-attn-cuda-archs)
      LONGLIVE2_FLASH_ATTN_CUDA_ARCHS="$2"
      shift 2
      ;;
    --max-jobs)
      LONGLIVE2_MAX_JOBS="$2"
      shift 2
      ;;
    --nvcc-threads)
      LONGLIVE2_NVCC_THREADS="$2"
      shift 2
      ;;
    --build-flash-attn-source)
      LONGLIVE2_BUILD_FLASH_ATTN_FROM_SOURCE="1"
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
    ;;
  nvfp4|nvfp4_s4|nvfp4_4step)
    LONGLIVE2_PROFILE="nvfp4_s4"
    ;;
  nvfp4_s2|nvfp4_2step)
    LONGLIVE2_PROFILE="nvfp4_s2"
    ;;
  *)
    echo "[error] unsupported LongLive2 profile '${LONGLIVE2_PROFILE}'." >&2
    exit 1
    ;;
esac

if ! command_exists git; then
  echo "[error] git is required to clone LongLive2." >&2
  exit 1
fi

mkdir -p "$(dirname -- "${LONGLIVE2_SRC_DIR}")"
if [[ ! -d "${LONGLIVE2_SRC_DIR}/.git" ]]; then
  video_log "Cloning LongLive2 into ${LONGLIVE2_SRC_DIR}."
  if ! git clone --filter=blob:none "${LONGLIVE2_REPO_URL}" "${LONGLIVE2_SRC_DIR}"; then
    video_log "Filtered LongLive2 clone failed; retrying full clone."
    git clone "${LONGLIVE2_REPO_URL}" "${LONGLIVE2_SRC_DIR}"
  fi
fi

video_log "Checking out LongLive2 ref ${LONGLIVE2_REPO_REF}."
if ! git -C "${LONGLIVE2_SRC_DIR}" checkout "${LONGLIVE2_REPO_REF}"; then
  video_log "LongLive2 ref ${LONGLIVE2_REPO_REF} was not present locally; fetching it."
  if ! git -C "${LONGLIVE2_SRC_DIR}" fetch --filter=blob:none origin "${LONGLIVE2_REPO_REF}"; then
    video_log "Specific filtered fetch failed; falling back to full fetch."
    git -C "${LONGLIVE2_SRC_DIR}" fetch --all --tags --prune
  fi
  git -C "${LONGLIVE2_SRC_DIR}" checkout "${LONGLIVE2_REPO_REF}" || git -C "${LONGLIVE2_SRC_DIR}" checkout FETCH_HEAD
fi

init_git_submodules() {
  local repo_dir="$1"
  if [[ ! -f "${repo_dir}/.gitmodules" ]]; then
    return
  fi
  local git_root
  git_root="$(git -C "${repo_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ "${git_root}" != "$(cd "${repo_dir}" && pwd)" ]]; then
    video_log "Cloning nested .gitmodules dependencies in ${repo_dir}."
    while read -r key path; do
      [[ -z "${key}" || -z "${path}" ]] && continue
      local name="${key#submodule.}"
      name="${name%.path}"
      local url
      url="$(git config -f "${repo_dir}/.gitmodules" --get "submodule.${name}.url")"
      if [[ -z "${url}" ]]; then
        echo "[error] Missing URL for nested submodule ${name} in ${repo_dir}/.gitmodules." >&2
        exit 1
      fi
      local target="${repo_dir}/${path}"
      if [[ -d "${target}/.git" ]]; then
        continue
      fi
      if [[ -e "${target}" ]]; then
        if [[ -n "$(find "${target}" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]]; then
          echo "[error] Nested submodule target exists but is not a git checkout: ${target}" >&2
          exit 1
        fi
        rmdir "${target}"
      fi
      video_log "Cloning ${url} into ${target}."
      if ! git clone --filter=blob:none --depth 1 "${url}" "${target}"; then
        video_log "Filtered shallow clone failed for ${url}; retrying shallow clone."
        if ! git clone --depth 1 "${url}" "${target}"; then
          video_log "Shallow clone failed for ${url}; retrying full clone."
          git clone "${url}" "${target}"
        fi
      fi
    done < <(git config -f "${repo_dir}/.gitmodules" --get-regexp '^submodule\..*\.path$')
    return
  fi
  video_log "Initializing git submodules in ${repo_dir}."
  git -C "${repo_dir}" submodule sync --recursive
  if ! git -C "${repo_dir}" submodule update --init --recursive --depth 1; then
    video_log "Shallow submodule update failed in ${repo_dir}; retrying without --depth."
    git -C "${repo_dir}" submodule update --init --recursive
  fi
}

init_git_submodules "${LONGLIVE2_SRC_DIR}"
init_git_submodules "${LONGLIVE2_SRC_DIR}/fouroversix"

mkdir -p "$(dirname -- "${LONGLIVE2_RUNTIME_ENV_FILE}")"
cat >"${LONGLIVE2_RUNTIME_ENV_FILE}" <<EOF
# Generated by setup_longlive2.sh. Do not commit.
LONGLIVE2_REPO_URL=${LONGLIVE2_REPO_URL}
LONGLIVE2_REPO_REF=${LONGLIVE2_REPO_REF}
LONGLIVE2_SRC_DIR=${LONGLIVE2_SRC_DIR}
LONGLIVE2_PROFILE=${LONGLIVE2_PROFILE}
LONGLIVE2_VENV_DIR=${LONGLIVE2_VENV_DIR}
LONGLIVE2_CUDA_ARCHS=${LONGLIVE2_CUDA_ARCHS}
LONGLIVE2_FLASH_ATTN_CUDA_ARCHS=${LONGLIVE2_FLASH_ATTN_CUDA_ARCHS}
LONGLIVE2_MAX_JOBS=${LONGLIVE2_MAX_JOBS}
LONGLIVE2_NVCC_THREADS=${LONGLIVE2_NVCC_THREADS}
LONGLIVE2_TRANSFORMERS_VERSION=${LONGLIVE2_TRANSFORMERS_VERSION}
LONGLIVE2_EXTRA_PIP_PACKAGES=${LONGLIVE2_EXTRA_PIP_PACKAGES}
EOF

if [[ "${LONGLIVE2_SKIP_BUILD}" == "1" ]]; then
  video_log "LongLive2 clone/config complete; build skipped."
  exit 0
fi

detect_blackwell_cuda_archs() {
  if [[ -n "${LONGLIVE2_CUDA_ARCHS}" ]]; then
    return
  fi
  if ! command_exists nvidia-smi; then
    return
  fi
  local gpu_names
  gpu_names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | tr '\n' ',' || true)"
  case "${gpu_names}" in
    *"RTX 5090"*|*"RTX5090"*)
      LONGLIVE2_CUDA_ARCHS="120"
      ;;
    *"GB200"*|*"GB300"*|*"B300"*|*"B200"*)
      LONGLIVE2_CUDA_ARCHS="100"
      ;;
  esac
}

if [[ "${LONGLIVE2_PROFILE}" == nvfp4* ]]; then
  detect_blackwell_cuda_archs
  if [[ -n "${LONGLIVE2_CUDA_ARCHS}" && -z "${LONGLIVE2_FLASH_ATTN_CUDA_ARCHS}" ]]; then
    LONGLIVE2_FLASH_ATTN_CUDA_ARCHS="${LONGLIVE2_CUDA_ARCHS//,/;}"
  fi
  if [[ -n "${LONGLIVE2_CUDA_ARCHS}" ]]; then
    video_log "Using CUDA_ARCHS=${LONGLIVE2_CUDA_ARCHS} for LongLive2 NVFP4 extension builds."
  else
    video_log "CUDA_ARCHS not set; LongLive2 NVFP4 extension builds will use upstream defaults."
  fi
fi

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command_exists "${PYTHON_BIN}"; then
  echo "[error] python3 is required." >&2
  exit 1
fi

if [[ ! -x "${LONGLIVE2_VENV_DIR}/bin/python" ]]; then
  video_log "Creating LongLive2 venv at ${LONGLIVE2_VENV_DIR}."
  "${PYTHON_BIN}" -m venv "${LONGLIVE2_VENV_DIR}"
fi

PY="${LONGLIVE2_VENV_DIR}/bin/python"
"${PY}" -m pip install -U pip setuptools wheel ninja packaging

pin_longlive2_python_deps() {
  if [[ -n "${LONGLIVE2_TRANSFORMERS_VERSION}" ]]; then
    video_log "Pinning transformers==${LONGLIVE2_TRANSFORMERS_VERSION} for LongLive2 X-CLIP imports."
    "${PY}" -m pip install "transformers==${LONGLIVE2_TRANSFORMERS_VERSION}"
  fi
}

install_longlive2_extra_python_deps() {
  if [[ -n "${LONGLIVE2_EXTRA_PIP_PACKAGES}" ]]; then
    read -r -a extra_packages <<<"${LONGLIVE2_EXTRA_PIP_PACKAGES}"
    video_log "Installing LongLive2 extra Python packages: ${LONGLIVE2_EXTRA_PIP_PACKAGES}."
    "${PY}" -m pip install "${extra_packages[@]}"
  fi
}

verify_longlive2_python_deps() {
  "${PY}" - <<'PY'
import decord  # noqa: F401
from transformers.models.x_clip.modeling_x_clip import x_clip_loss  # noqa: F401
print("[longlive2-setup] transformers x_clip_loss and decord imports ok")
PY
}

if [[ "${LONGLIVE2_PROFILE}" == "bf16_sp" ]]; then
  video_log "Installing BF16 SP LongLive2 dependencies."
  "${PY}" -m pip install --index-url https://download.pytorch.org/whl/cu128 torch==2.8.0 torchvision==0.23.0
  "${PY}" -m pip install -r "${LONGLIVE2_SRC_DIR}/requirements.txt"
  pin_longlive2_python_deps
  install_longlive2_extra_python_deps
  verify_longlive2_python_deps
  "${PY}" -m pip install flash-attn --no-build-isolation
else
  if [[ -z "${LONGLIVE2_BUILD_FLASH_ATTN_FROM_SOURCE}" ]]; then
    LONGLIVE2_BUILD_FLASH_ATTN_FROM_SOURCE="1"
  fi
  video_log "Installing NVFP4 LongLive2 dependencies."
  video_log "Preinstalling Torch ${LONGLIVE2_NVFP4_TORCH_VERSION} before upstream requirements to avoid duplicate CUDA stack downloads."
  "${PY}" -m pip install --index-url https://download.pytorch.org/whl/cu128 "torch==${LONGLIVE2_NVFP4_TORCH_VERSION}" "torchvision==${LONGLIVE2_NVFP4_TORCHVISION_VERSION}"
  "${PY}" -m pip install -r "${LONGLIVE2_SRC_DIR}/requirements.txt"
  "${PY}" -m pip install --upgrade --index-url https://download.pytorch.org/whl/cu128 "torch==${LONGLIVE2_NVFP4_TORCH_VERSION}" "torchvision==${LONGLIVE2_NVFP4_TORCHVISION_VERSION}"
  pin_longlive2_python_deps
  install_longlive2_extra_python_deps
  verify_longlive2_python_deps
  if [[ -n "${LONGLIVE2_MAX_JOBS}" ]]; then
    export MAX_JOBS="${LONGLIVE2_MAX_JOBS}"
    video_log "Using MAX_JOBS=${MAX_JOBS} for native extension builds."
  fi
  if [[ -n "${LONGLIVE2_NVCC_THREADS}" ]]; then
    export NVCC_THREADS="${LONGLIVE2_NVCC_THREADS}"
    video_log "Using NVCC_THREADS=${NVCC_THREADS} for native extension builds."
  fi
  if [[ -n "${LONGLIVE2_FLASH_ATTN_CUDA_ARCHS}" ]]; then
    export FLASH_ATTN_CUDA_ARCHS="${LONGLIVE2_FLASH_ATTN_CUDA_ARCHS}"
    video_log "Using FLASH_ATTN_CUDA_ARCHS=${FLASH_ATTN_CUDA_ARCHS} for flash-attention source builds."
  fi
  if [[ -n "${LONGLIVE2_CUDA_ARCHS}" ]]; then
    export CUDA_ARCHS="${LONGLIVE2_CUDA_ARCHS}"
    if [[ -z "${TORCH_CUDA_ARCH_LIST:-}" ]]; then
      TORCH_CUDA_ARCH_LIST="$(python3 - "${LONGLIVE2_CUDA_ARCHS}" <<'PY'
import sys

items = []
for raw in sys.argv[1].replace(";", ",").split(","):
    raw = raw.strip()
    if not raw:
        continue
    if "." in raw:
        items.append(raw)
        continue
    if len(raw) >= 2:
        items.append(f"{raw[:-1]}.{raw[-1]}")
    else:
        items.append(raw)
print(";".join(items))
PY
)"
      export TORCH_CUDA_ARCH_LIST
    fi
  fi
  (
    cd "${LONGLIVE2_SRC_DIR}/fouroversix"
    "${PY}" -m pip install --no-build-isolation -e .
  )
  if [[ "${LONGLIVE2_BUILD_FLASH_ATTN_FROM_SOURCE}" == "1" ]]; then
    FLASH_ATTN_DIR="${LONGLIVE2_SRC_DIR}/.vendors/flash-attention"
    if [[ ! -d "${FLASH_ATTN_DIR}/.git" ]]; then
      mkdir -p "$(dirname -- "${FLASH_ATTN_DIR}")"
      git clone "${LONGLIVE2_FLASH_ATTN_REPO_URL}" "${FLASH_ATTN_DIR}"
    fi
    git -C "${FLASH_ATTN_DIR}" fetch --all --tags --prune
    git -C "${FLASH_ATTN_DIR}" checkout "${LONGLIVE2_FLASH_ATTN_REF}"
    (
      cd "${FLASH_ATTN_DIR}"
      "${PY}" -m pip install --no-build-isolation -e .
    )
  fi
  (
    cd "${LONGLIVE2_SRC_DIR}/utils/kernel"
    "${PY}" setup.py build_ext --inplace
  )
fi

video_log "LongLive2 setup complete: profile=${LONGLIVE2_PROFILE} src=${LONGLIVE2_SRC_DIR}"
