#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=VideoDiffusion/video_runtime_common.sh
source "${SCRIPT_DIR}/video_runtime_common.sh"

KREA_REPO_URL="${KREA_REPO_URL:-https://github.com/krea-ai/realtime-video.git}"
KREA_REPO_REF="${KREA_REPO_REF:-main}"
KREA_SRC_DIR="${KREA_SRC_DIR:-${SCRIPT_DIR}/.vendors/krea-realtime-video}"
KREA_VENV_DIR="${KREA_VENV_DIR:-${SCRIPT_DIR}/.venv-krea}"
KREA_PYTHON_BIN="${KREA_PYTHON_BIN:-auto}"
KREA_REQUIREMENTS_LOCK="${KREA_REQUIREMENTS_LOCK:-${SCRIPT_DIR}/requirements-krea.lock.txt}"
KREA_RUNTIME_ENV_FILE="${KREA_RUNTIME_ENV_FILE:-${SCRIPT_DIR}/.krea_runtime.env}"

ATTN_BACKEND_REQUESTED="$(normalize_attn_backend "${ATTN_BACKEND:-auto}")"
ATTN_BACKEND_RESOLVED="$(resolve_attn_backend "${ATTN_BACKEND_REQUESTED}")"

FLASH_ATTN_VERSION="${FLASH_ATTN_VERSION:-2.7.4.post1}"
FLASH_ATTN_ALLOW_SOURCE_BUILD="${FLASH_ATTN_ALLOW_SOURCE_BUILD:-0}"
SAGEATTENTION_REQUIRED="${SAGEATTENTION_REQUIRED:-0}"

apt_get_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    apt-get "$@"
    return
  fi
  if command_exists sudo; then
    sudo apt-get "$@"
    return
  fi
  echo "[error] apt-get requires root or passwordless sudo on this host." >&2
  return 1
}

add_apt_repo_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    add-apt-repository "$@"
    return
  fi
  if command_exists sudo; then
    sudo add-apt-repository "$@"
    return
  fi
  echo "[error] add-apt-repository requires root or passwordless sudo on this host." >&2
  return 1
}

ensure_python_venv_support() {
  local py_exec="$1"
  if "${py_exec}" - <<'PY' >/dev/null 2>&1
import ensurepip  # noqa: F401
PY
  then
    return 0
  fi

  if ! command_exists apt-get; then
    echo "[error] python3 ensurepip is unavailable and apt-get is not present." >&2
    return 1
  fi

  video_log "Installing python venv support via apt-get."
  export DEBIAN_FRONTEND=noninteractive
  apt_get_cmd update -y
  if [[ "${py_exec}" == *"python3.11"* ]]; then
    apt_get_cmd install -y python3.11-venv python3-pip || true
  else
    apt_get_cmd install -y python3-venv python3-pip || true
  fi

  "${py_exec}" - <<'PY' >/dev/null 2>&1
import ensurepip  # noqa: F401
PY
}

ensure_python311_runtime() {
  if command_exists python3.11; then
    return 0
  fi

  if ! command_exists apt-get; then
    echo "[error] python3.11 is required for Krea but apt-get is unavailable." >&2
    return 1
  fi

  video_log "Installing python3.11 runtime (required by upstream Krea package constraints)."
  export DEBIAN_FRONTEND=noninteractive
  apt_get_cmd update -y
  if apt_get_cmd install -y python3.11 python3.11-venv python3-pip; then
    return 0
  fi

  if ! command_exists add-apt-repository; then
    apt_get_cmd install -y software-properties-common
  fi
  add_apt_repo_cmd -y ppa:deadsnakes/ppa
  apt_get_cmd update -y
  apt_get_cmd install -y python3.11 python3.11-venv python3-pip
}

resolve_krea_python() {
  if [[ -n "${KREA_PYTHON_BIN}" && "${KREA_PYTHON_BIN}" != "auto" ]]; then
    if ! command_exists "${KREA_PYTHON_BIN}"; then
      echo "[error] KREA_PYTHON_BIN='${KREA_PYTHON_BIN}' not found in PATH." >&2
      return 1
    fi
    "${KREA_PYTHON_BIN}" - <<'PY' >/dev/null
import sys
assert (3, 11) <= sys.version_info[:2] < (3, 12), f"unsupported python version {sys.version}"
PY
    printf '%s\n' "${KREA_PYTHON_BIN}"
    return 0
  fi

  ensure_python311_runtime
  printf '%s\n' "python3.11"
}

ensure_krea_checkout() {
  if [[ -d "${KREA_SRC_DIR}/.git" ]]; then
    video_log "Updating existing Krea checkout in ${KREA_SRC_DIR}."
    git -C "${KREA_SRC_DIR}" fetch --all --tags --prune
  else
    video_log "Cloning Krea repository into ${KREA_SRC_DIR}."
    mkdir -p "$(dirname -- "${KREA_SRC_DIR}")"
    git clone "${KREA_REPO_URL}" "${KREA_SRC_DIR}"
  fi

  if git -C "${KREA_SRC_DIR}" rev-parse --verify --quiet "${KREA_REPO_REF}^{commit}" >/dev/null; then
    git -C "${KREA_SRC_DIR}" checkout --force "${KREA_REPO_REF}"
  elif git -C "${KREA_SRC_DIR}" rev-parse --verify --quiet "origin/${KREA_REPO_REF}^{commit}" >/dev/null; then
    git -C "${KREA_SRC_DIR}" checkout --force "origin/${KREA_REPO_REF}"
  else
    echo "[error] Could not resolve KREA_REPO_REF='${KREA_REPO_REF}' in ${KREA_SRC_DIR}." >&2
    exit 1
  fi
}

install_base_runtime() {
  local py_bin="$1"
  "${py_bin}" -m pip install --upgrade pip setuptools wheel

  if [[ -f "${KREA_REQUIREMENTS_LOCK}" ]]; then
    video_log "Installing pinned Krea bootstrap requirements from ${KREA_REQUIREMENTS_LOCK}."
    "${py_bin}" -m pip install -r "${KREA_REQUIREMENTS_LOCK}"
  fi

  video_log "Installing Krea package from source checkout."
  "${py_bin}" -m pip install --no-cache-dir -e "${KREA_SRC_DIR}"
}

ensure_venv_pip() {
  local py_bin="$1"
  if "${py_bin}" -m pip --version >/dev/null 2>&1; then
    return 0
  fi

  video_log "Bootstrapping pip inside Krea venv."
  "${py_bin}" -m ensurepip --upgrade || true

  if "${py_bin}" -m pip --version >/dev/null 2>&1; then
    return 0
  fi

  echo "[error] pip is unavailable in ${py_bin} after ensurepip." >&2
  return 1
}

venv_python_is_supported() {
  local py_bin="$1"
  "${py_bin}" - <<'PY' >/dev/null 2>&1
import sys
assert (3, 11) <= sys.version_info[:2] < (3, 12), f"unsupported python version {sys.version}"
PY
}

install_sage_attention() {
  local py_bin="$1"

  if [[ "${ATTN_BACKEND_RESOLVED}" != "sage" ]]; then
    return 0
  fi

  video_log "Attention backend resolved to sage. Attempting SageAttention install."
  local script_candidate
  for script_candidate in \
    "${KREA_SRC_DIR}/scripts/install_sageattention.sh" \
    "${KREA_SRC_DIR}/install_sageattention.sh"; do
    if [[ -f "${script_candidate}" ]]; then
      (cd "${KREA_SRC_DIR}" && bash "${script_candidate}")
      return 0
    fi
  done

  if "${py_bin}" -m pip install --no-cache-dir sageattention; then
    return 0
  fi

  if [[ "${SAGEATTENTION_REQUIRED}" == "1" ]]; then
    echo "[error] SageAttention install failed and SAGEATTENTION_REQUIRED=1." >&2
    exit 1
  fi

  video_log "WARN: SageAttention install failed. Runtime will fallback to available backend."
}

install_flash_attention() {
  local py_bin="$1"

  if [[ "${ATTN_BACKEND_RESOLVED}" != "flash" ]]; then
    return 0
  fi

  video_log "Attention backend resolved to flash. Installing flash-attn ${FLASH_ATTN_VERSION}."
  if "${py_bin}" -m pip install --no-build-isolation --no-cache-dir --only-binary :all: "flash-attn==${FLASH_ATTN_VERSION}"; then
    return 0
  fi

  if [[ "${FLASH_ATTN_ALLOW_SOURCE_BUILD}" == "1" ]]; then
    if command_exists apt-get; then
      video_log "Installing flash-attn source build toolchain (python3.11-dev, ninja-build)."
      export DEBIAN_FRONTEND=noninteractive
      apt_get_cmd update -y
      apt_get_cmd install -y python3.11-dev ninja-build
    else
      video_log "WARN: apt-get unavailable; flash-attn source build may fail without python headers/toolchain."
    fi
    video_log "No compatible wheel; attempting source build for flash-attn ${FLASH_ATTN_VERSION}."
    "${py_bin}" -m pip install --no-build-isolation --no-cache-dir "flash-attn==${FLASH_ATTN_VERSION}"
    return 0
  fi

  echo "[error] flash-attn wheel install failed and FLASH_ATTN_ALLOW_SOURCE_BUILD=0." >&2
  echo "[error] Set FLASH_ATTN_ALLOW_SOURCE_BUILD=1 to permit source builds." >&2
  exit 1
}

write_runtime_env_file() {
  mkdir -p "$(dirname -- "${KREA_RUNTIME_ENV_FILE}")"
  cat > "${KREA_RUNTIME_ENV_FILE}" <<EOF
KREA_SRC_DIR=${KREA_SRC_DIR}
KREA_VENV_DIR=${KREA_VENV_DIR}
ATTN_BACKEND=${ATTN_BACKEND_RESOLVED}
KREA_ATTN_BACKEND=${ATTN_BACKEND_RESOLVED}
EOF
  case "${ATTN_BACKEND_RESOLVED}" in
    flash|sdpa)
      {
        echo "DISABLE_SAGEATTENTION=1"
      } >> "${KREA_RUNTIME_ENV_FILE}"
      ;;
  esac
}

ensure_krea_checkout

KREA_PYTHON_EXE="$(resolve_krea_python)"
ensure_python_venv_support "${KREA_PYTHON_EXE}"

if [[ -x "${KREA_VENV_DIR}/bin/python" ]]; then
  if ! venv_python_is_supported "${KREA_VENV_DIR}/bin/python"; then
    video_log "Existing Krea venv uses unsupported Python; recreating ${KREA_VENV_DIR} with ${KREA_PYTHON_EXE}."
    rm -rf "${KREA_VENV_DIR}"
  fi
fi

if [[ ! -x "${KREA_VENV_DIR}/bin/python" ]]; then
  video_log "Creating Krea venv at ${KREA_VENV_DIR}."
  "${KREA_PYTHON_EXE}" -m venv "${KREA_VENV_DIR}"
fi
KREA_PYTHON="${KREA_VENV_DIR}/bin/python"

ensure_venv_pip "${KREA_PYTHON}"
install_base_runtime "${KREA_PYTHON}"
install_sage_attention "${KREA_PYTHON}"
install_flash_attention "${KREA_PYTHON}"
write_runtime_env_file

mkdir -p "${SCRIPT_DIR}/.cache/krea" "${SCRIPT_DIR}/.cache/huggingface"

video_log "Krea setup complete."
video_log "Resolved attention backend: ${ATTN_BACKEND_RESOLVED} (requested=${ATTN_BACKEND_REQUESTED}, gpu='$(detect_primary_gpu_name)')."
video_log "Runtime env file written to ${KREA_RUNTIME_ENV_FILE}."
video_log "Reminder: Krea upstream weights/license are currently non-commercial (CC BY-NC-SA 4.0)."
