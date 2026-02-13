#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

log() {
  printf '[magi-setup] %s\n' "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

has_cuda_nvcc() {
  command_exists nvcc || [ -x /usr/local/cuda/bin/nvcc ]
}

resolve_python_bin() {
  if command_exists python3; then
    printf '%s\n' "$(command -v python3)"
    return 0
  fi

  if command_exists python; then
    printf '%s\n' "$(command -v python)"
    return 0
  fi

  return 1
}

detect_torch_cuda_archs() {
  local python_bin="$1"
  local archs

  archs="$(
    "${python_bin}" - <<'PY'
import torch

if not torch.cuda.is_available():
    raise SystemExit(1)

archs = []
for i in range(torch.cuda.device_count()):
    props = torch.cuda.get_device_properties(i)
    archs.append(f"{props.major}.{props.minor}")

print(";".join(sorted(set(archs))))
PY
  )" || true

  if [ -n "${archs}" ]; then
    printf '%s\n' "${archs}"
  else
    printf '8.6\n'
  fi
}

arch_list_has_major() {
  # TORCH_CUDA_ARCH_LIST uses "major.minor" entries separated by ';', e.g. "8.0;9.0".
  local archs="$1"
  local major="$2"
  local IFS=';'
  local a

  for a in ${archs}; do
    a="${a//[[:space:]]/}"
    if [[ "${a}" == "${major}."* ]] || [[ "${a}" == "${major}" ]]; then
      return 0
    fi
  done

  return 1
}

apply_flash_attn_sm90_removal_patch() {
  local source_dir="$1"
  local setup_file="${source_dir}/setup.py"
  local python_file

  if [ ! -f "${setup_file}" ]; then
    return 1
  fi

  python_file="$(
    python3 - "${setup_file}" <<'PY'
import pathlib
import re
import sys

setup_path = pathlib.Path(sys.argv[1])
text = setup_path.read_text(encoding="utf-8")

replacements = [
    (r'"arch=compute_90a,code=sm_90a"', '"arch=compute_80,code=sm_80"'),
    (r'"arch=compute_90,code=sm_90"', '"arch=compute_80,code=sm_80"'),
    (r"'arch=compute_90a,code=sm_90a'", "'arch=compute_80,code=sm_80'"),
    (r"'arch=compute_90,code=sm_90'", "'arch=compute_80,code=sm_80'"),
]
patched = text
for pattern, replacement in replacements:
    patched = re.sub(pattern, replacement, patched)
if patched != text:
    setup_path.write_text(patched + "\n", encoding="utf-8")
    print("patched")
else:
    print("noop")
PY
  )"

  if [ "${python_file}" = "patched" ]; then
    return 0
  fi

  if [ "${python_file}" = "noop" ]; then
    return 0
  fi

  return 1
}

build_flash_attention_source() {
  local python_bin="$1"
  local version="$2"
  local archs="$3"
  local build_jobs="$4"
  local nvcc_threads="$5"
  local skip_sm90="$6"

  local flash_src_dir="/tmp/flash-attn-${version}-src"
  local nvcc_path

  if command_exists nvcc; then
    nvcc_path="$(command -v nvcc)"
  else
    nvcc_path="/usr/local/cuda/bin/nvcc"
  fi

  log "Cloning flash-attn ${version} source for constrained local build."
  rm -rf "${flash_src_dir}"
  mkdir -p "${flash_src_dir}"
  git clone --depth 1 --branch "v${version}" --single-branch https://github.com/Dao-AILab/flash-attention.git "${flash_src_dir}"

  if [ "${skip_sm90}" = "1" ]; then
    if ! apply_flash_attn_sm90_removal_patch "${flash_src_dir}"; then
      log "WARN: failed to patch flash-attn source for sm90 removal."
    fi
  fi

  log "Building flash-attn from source with TORCH_CUDA_ARCH_LIST=${archs} (MAX_JOBS=${build_jobs}, NVCC_THREADS=${nvcc_threads})."
  (
    cd "${flash_src_dir}"
    env PIP_USE_PEP517=0 \
      TORCH_CUDA_ARCH_LIST="${archs}" \
      PATH="$(dirname "${nvcc_path}"):${PATH}" \
      MAX_JOBS="${build_jobs}" \
      NVCC_THREADS="${nvcc_threads}" \
      "${python_bin}" setup.py build_ext --inplace
  )

  log "Installing flash-attn extension module."
  (
    cd "${flash_src_dir}"
    env PIP_USE_PEP517=0 \
      TORCH_CUDA_ARCH_LIST="${archs}" \
      PATH="$(dirname "${nvcc_path}"):${PATH}" \
      MAX_JOBS="${build_jobs}" \
      NVCC_THREADS="${nvcc_threads}" \
      "${python_bin}" setup.py install
  )
}

install_flash_attention() {
  local python_bin="$1"
  local version="${2:-2.4.2}"
  local archs="${3:-8.6}"
  local existing_version
  local build_jobs="${FLASH_ATTN_MAX_JOBS:-2}"
  local nvcc_threads="${FLASH_ATTN_NVCC_THREADS:-2}"
  local force_source="${FLASH_ATTN_FORCE_SOURCE:-0}"
  local allow_source="${FLASH_ATTN_ALLOW_SOURCE_BUILD:-1}"
  local skip_sm90="${FLASH_ATTN_SKIP_SM90:-AUTO}"

  if [ "${skip_sm90}" = "AUTO" ]; then
    if arch_list_has_major "${archs}" 9; then
      skip_sm90="0"
    else
      skip_sm90="1"
    fi
  fi

  existing_version="$("${python_bin}" -m pip show flash-attn | awk '/^Version:/ {print $2}' || true)"
  if [ "${existing_version:-}" = "${version}" ]; then
    log "flash-attn ${version} already installed; skipping."
    return 0
  fi
  if [ -n "${existing_version:-}" ] && [ "${existing_version%%+*}" = "${version}" ]; then
    log "flash-attn ${existing_version} already installed and compatible with requested base ${version}; skipping."
    return 0
  fi

  if [ -n "${existing_version:-}" ]; then
    log "Removing flash-attn ${existing_version} to install ${version}."
    "${python_bin}" -m pip uninstall -y flash-attn || true
  fi

  if [ "${force_source}" = "1" ]; then
    log "FLASH_ATTN_FORCE_SOURCE=1 set, skipping wheel probe."
  else
    log "Installing flash-attn ${version} (wheel-first strategy)."
    if TORCH_CUDA_ARCH_LIST="${archs}" "${python_bin}" -m pip install --no-build-isolation --no-cache-dir --only-binary :all: "flash-attn==${version}"; then
      log "flash-attn prebuilt install succeeded."
      log "Verifying flash-attn import."
      if ! "${python_bin}" - <<'PY'
import flash_attn

print(f"flash-attn install verified: {flash_attn.__version__}")
PY
      then
        log "flash-attn verification failed after install."
        return 1
      fi

      log "flash-attn prebuilt install verified."
      return 0
    fi

    log "No compatible flash-attn wheel found or wheel install failed."
  fi

  if [ "${allow_source}" != "1" ]; then
    log "Source build disabled (FLASH_ATTN_ALLOW_SOURCE_BUILD=0)."
    return 1
  fi

  if ! has_cuda_nvcc; then
    log "ERROR: nvcc not found. Source build is not possible."
    log "Install a CUDA toolkit package and rerun setup, or pin torch/CUDA to a build with published wheels."
    return 1
  fi

  log "Falling back to constrained source build (MAX_JOBS=${build_jobs}, NVCC_THREADS=${nvcc_threads}, archs=${archs})."
  if [ "${skip_sm90}" = "1" ]; then
    log "FLASH_ATTN_SKIP_SM90=${skip_sm90}: patching flash-attn source to avoid compute_90 build."
  fi
  log "Note: this can take several minutes on first install."
  build_flash_attention_source "${python_bin}" "${version}" "${archs}" "${build_jobs}" "${nvcc_threads}" "${skip_sm90}"
  
  log "Verifying flash-attn import."
  if ! "${python_bin}" - <<'PY'
import flash_attn

print(f"flash-attn install verified: {flash_attn.__version__}")
PY
  then
    log "flash-attn verification failed after install."
    return 1
  fi

  log "flash-attn source install verified."
  return 0
}

log "System bootstrap (single-GPU baseline)"
if [[ ${EUID:-1000} -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

${SUDO} apt-get update -y
${SUDO} apt-get install -y --no-install-recommends \
  git \
  git-lfs \
  ffmpeg \
  htop \
  build-essential \
  python3-dev \
  python3-venv \
  python3-pip \
  ninja-build \
  cmake

git lfs install

log "Preparing MAGI-1 repository"
if [ -d "${REPO_ROOT}/MAGI-1" ] && [ ! -d "${REPO_ROOT}/MAGI-1/.git" ]; then
  log "MAGI-1 exists but is not a git repo. Resetting it."
  rm -rf "${REPO_ROOT}/MAGI-1"
fi
if [ ! -d "${REPO_ROOT}/MAGI-1/.git" ]; then
  log "Cloning MAGI-1..."
  git clone --depth 1 https://github.com/SandAI-org/MAGI-1 "${REPO_ROOT}/MAGI-1"
else
  log "MAGI-1 checkout already present."
fi

cd "${REPO_ROOT}/MAGI-1"
if [ ! -f "requirements.txt" ]; then
  log "ERROR: requirements.txt not found in MAGI-1 checkout."
  log "Expected path: ${REPO_ROOT}/MAGI-1/requirements.txt"
  exit 1
fi

PYTHON_BIN="$(resolve_python_bin)" || {
  log "ERROR: Python interpreter not found. Install python3 before continuing."
  exit 1
}

SYSTEM_PYTHON_BIN="${PYTHON_BIN}"

MAGI_USE_VENV="${MAGI_USE_VENV:-1}"
MAGI_VENV_DIR="${MAGI_VENV_DIR:-${REPO_ROOT}/.venv}"
if [ "${MAGI_USE_VENV}" = "1" ]; then
  if [ ! -x "${MAGI_VENV_DIR}/bin/python" ]; then
    log "Creating Python venv at ${MAGI_VENV_DIR}"
    "${SYSTEM_PYTHON_BIN}" -m venv "${MAGI_VENV_DIR}"
  else
    log "Using existing Python venv at ${MAGI_VENV_DIR}"
  fi
  PYTHON_BIN="${MAGI_VENV_DIR}/bin/python"
fi

log "Using python: ${PYTHON_BIN}"

log "Installing base build tooling for Python extensions"
${PYTHON_BIN} -m pip install --upgrade pip setuptools wheel build setuptools-scm

MAGI_TORCH_SPEC="${MAGI_TORCH_SPEC:-torch==2.4.0+cu124}"
MAGI_TORCH_INDEX_URL="${MAGI_TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu124}"
MAGI_TORCHVISION_SPEC="${MAGI_TORCHVISION_SPEC:-torchvision==0.19.0+cu124}"
log "Ensuring ${MAGI_TORCH_SPEC} (index: ${MAGI_TORCH_INDEX_URL}) before installing requirements."
EXISTING_TORCH_BASE="$(
  ${PYTHON_BIN} - <<'PY' || true
try:
    import torch
except Exception:
    raise SystemExit(1)

print(str(torch.__version__).split("+", 1)[0])
PY
)"
DESIRED_TORCH_BASE="$(printf '%s' "${MAGI_TORCH_SPEC}" | sed -E 's/^torch==([^+]+).*/\1/')"
if [ -z "${EXISTING_TORCH_BASE}" ] || [ "${EXISTING_TORCH_BASE}" != "${DESIRED_TORCH_BASE}" ]; then
  log "Installing pinned torch base version ${DESIRED_TORCH_BASE} (current='${EXISTING_TORCH_BASE:-none}')."
  ${PYTHON_BIN} -m pip install --no-cache-dir --upgrade --index-url "${MAGI_TORCH_INDEX_URL}" --extra-index-url https://pypi.org/simple "${MAGI_TORCH_SPEC}"
else
  log "Pinned torch base version already present (${EXISTING_TORCH_BASE}); skipping torch install."
fi
log "Torch version check:"
${PYTHON_BIN} - <<'PY'
import torch

print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
print("is_available:", torch.cuda.is_available())
if torch.cuda.is_available():
    props = torch.cuda.get_device_properties(0)
    print("gpu:", props.name, f"cc={props.major}.{props.minor}")
PY

log "Ensuring ${MAGI_TORCHVISION_SPEC} (to avoid pip resolving a newer torchvision that forces a torch upgrade)."
${PYTHON_BIN} -m pip install --no-cache-dir --upgrade --index-url "${MAGI_TORCH_INDEX_URL}" --extra-index-url https://pypi.org/simple "${MAGI_TORCHVISION_SPEC}"

log "Installing MAGI-1 requirements (excluding flash-attn/flashinfer-python)"
REQ_TMP="$(mktemp)"
trap 'rm -f "${REQ_TMP}"' EXIT

grep -vE '^\s*(#|$|flash-attn|flashinfer-python)' requirements.txt > "${REQ_TMP}"
${PYTHON_BIN} -m pip install --no-build-isolation --no-cache-dir -r "${REQ_TMP}"

FLASH_ATTN_VERSION="${FLASH_ATTN_VERSION:-2.4.2}"
TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-$(detect_torch_cuda_archs "${PYTHON_BIN}")}"
export TORCH_CUDA_ARCH_LIST
export NVCC_THREADS="${FLASH_ATTN_NVCC_THREADS:-2}"
export MAX_JOBS="${FLASH_ATTN_MAX_JOBS:-2}"
export MAGI_ATTENTION_SKIP_SM90="${MAGI_ATTENTION_SKIP_SM90:-AUTO}"
if [ "${MAGI_ATTENTION_SKIP_SM90}" = "AUTO" ]; then
  if arch_list_has_major "${TORCH_CUDA_ARCH_LIST}" 9; then
    export MAGI_ATTENTION_SKIP_SM90=0
  else
    export MAGI_ATTENTION_SKIP_SM90=1
  fi
fi
if [ "${MAGI_ATTENTION_SKIP_SM90}" = "1" ]; then
  # For non-9.0 GPUs, skip expensive sm90-specific JIT prebuilds
  # and avoid nvshmem-dependent comm builds on one-GPU setups.
  export MAGI_ATTENTION_DISABLE_SM90_FEATURES="${MAGI_ATTENTION_DISABLE_SM90_FEATURES:-0}"
  export MAGI_ATTENTION_PREBUILD_FFA="${MAGI_ATTENTION_PREBUILD_FFA:-0}"
  export MAGI_ATTENTION_SKIP_MAGI_ATTN_COMM_BUILD="${MAGI_ATTENTION_SKIP_MAGI_ATTN_COMM_BUILD:-1}"
  export MAGI_ATTENTION_SKIP_FFA_UTILS_BUILD="${MAGI_ATTENTION_SKIP_FFA_UTILS_BUILD:-1}"
else
  # Prebuilding can take 20-30 minutes; keep it opt-in for cost control.
  export MAGI_ATTENTION_PREBUILD_FFA="${MAGI_ATTENTION_PREBUILD_FFA:-0}"
  # For one-GPU smoke tests, skip comm + utils builds by default to reduce build time and
  # avoid nvshmem-dependent failures. Override with MAGI_ATTENTION_SKIP_* env vars if needed.
  export MAGI_ATTENTION_SKIP_MAGI_ATTN_COMM_BUILD="${MAGI_ATTENTION_SKIP_MAGI_ATTN_COMM_BUILD:-1}"
  export MAGI_ATTENTION_SKIP_FFA_UTILS_BUILD="${MAGI_ATTENTION_SKIP_FFA_UTILS_BUILD:-1}"
fi
install_flash_attention "${PYTHON_BIN}" "${FLASH_ATTN_VERSION}" "${TORCH_CUDA_ARCH_LIST}"

if [ ! -d "${REPO_ROOT}/MAGI-1/MagiAttention" ]; then
  log "Cloning MagiAttention..."
  git clone https://github.com/SandAI-org/MagiAttention "${REPO_ROOT}/MAGI-1/MagiAttention"
else
  log "MagiAttention checkout already present."
fi

cd "${REPO_ROOT}/MAGI-1/MagiAttention"
MAGI_ATTENTION_REF="${MAGI_ATTENTION_REF:-26ce12c27bb16a86f6ae61bf066f8b38f7fc835b}"
log "Checking out MagiAttention ref: ${MAGI_ATTENTION_REF}"
git fetch --all --tags --prune || true
git checkout "${MAGI_ATTENTION_REF}"
git submodule update --init --recursive

patch_magiattention_flex_flash_attn_signature() {
  # MAGI-1 currently calls `magi_attention.functional.flex_flash_attn_func(..., max_seqlen_k=...)`.
  # Some MagiAttention refs only accept `max_seqlen_q`. Patch the signature to accept max_seqlen_k
  # (ignored) for compatibility, without requiring users to edit vendor repos by hand.
  local python_bin="$1"
  local file_path="$2"

  if [ ! -f "${file_path}" ]; then
    log "WARN: MagiAttention flex_flash_attn.py not found at ${file_path}; skipping compat patch."
    return 0
  fi

  "${python_bin}" - "$file_path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(True)

start = None
for i, line in enumerate(lines):
    if line.startswith("def flex_flash_attn_func("):
        start = i
        break
if start is None:
    print("[setup] flex_flash_attn_func def not found; skipping patch")
    raise SystemExit(0)

end = None
for j in range(start + 1, min(start + 250, len(lines))):
    if lines[j].lstrip().startswith(")"):
        end = j
        break
if end is None:
    raise SystemExit("[setup] could not find end of flex_flash_attn_func signature")

sig_block = "".join(lines[start : end + 1])
if "max_seqlen_k" in sig_block:
    print("[setup] MagiAttention already accepts max_seqlen_k; skipping patch")
    raise SystemExit(0)

out = []
patched = False
for idx, line in enumerate(lines):
    out.append(line)
    if idx <= start or idx > end:
        continue
    if not patched and line.lstrip().startswith("max_seqlen_q"):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}max_seqlen_k: int | None = None,  # compat for MAGI-1 callers\n")
        patched = True

if not patched:
    raise SystemExit("[setup] failed to patch MagiAttention: max_seqlen_q not found in signature")

path.write_text("".join(out), encoding="utf-8")
print("[setup] patched MagiAttention flex_flash_attn_func signature (added max_seqlen_k)")
PY
}

log "Applying MagiAttention compatibility patch (flex_flash_attn_func max_seqlen_k)"
patch_magiattention_flex_flash_attn_signature "${PYTHON_BIN}" "magi_attention/functional/flex_flash_attn.py"

if [ "${MAGI_ATTENTION_SKIP_SM90}" = "1" ]; then
  # Keep logs explicit: this run is optimized for single-GPU sm80-class hardware.
  export MAGI_ATTENTION_DISABLE_SM90_FEATURES="${MAGI_ATTENTION_DISABLE_SM90_FEATURES:-0}"
fi

log "Installing MagiAttention with system nvcc (skip SM90=${MAGI_ATTENTION_SKIP_SM90})"
export PATH="/usr/local/cuda/bin:$PATH"
${PYTHON_BIN} -m pip install --no-build-isolation --no-cache-dir .

cd "${REPO_ROOT}/MAGI-1"
log "Installing flashinfer-python (prebuilt first, source fallback)"
FLASHINFER_INDEX="$(
  ${PYTHON_BIN} - <<'PY' || true
import re

try:
    import torch
except Exception:
    raise SystemExit(1)

cu = getattr(torch.version, "cuda", None) or ""
m = re.match(r"^(\\d+)\\.(\\d+)", str(cu))
if m:
    cu_tag = f"cu{m.group(1)}{m.group(2)}"
else:
    cu_tag = "cu124"

ver = str(getattr(torch, "__version__", "2.5")).split("+", 1)[0]
parts = ver.split(".")
if len(parts) >= 2:
    torch_tag = f"torch{parts[0]}.{parts[1]}"
else:
    torch_tag = "torch2.5"

print(f"https://flashinfer.ai/whl/{cu_tag}/{torch_tag}/")
PY
)"
if [ -z "${FLASHINFER_INDEX}" ]; then
  FLASHINFER_INDEX="https://flashinfer.ai/whl/cu124/torch2.5/"
fi
log "flashinfer wheel index: ${FLASHINFER_INDEX}"
if ! ${PYTHON_BIN} -m pip install --no-build-isolation --no-cache-dir flashinfer-python==0.2.0.post2 -i "${FLASHINFER_INDEX}"; then
  log "flashinfer wheel unavailable at ${FLASHINFER_INDEX}. Falling back to source build."
  ${PYTHON_BIN} -m pip install --no-build-isolation --no-cache-dir flashinfer-python
fi

cd "${REPO_ROOT}"
log "Installing stream runtime packages"
# Hugging Face tooling comes from MAGI-1's pinned deps (transformers/tokenizers).
# Avoid upgrading huggingface_hub to >=1.0 which breaks those pins.
${PYTHON_BIN} -m pip install --no-cache-dir "huggingface_hub<1.0"

# Stream server deps (keep minimal to avoid pulling incompatible numpy>=2.0).
${PYTHON_BIN} -m pip install --no-cache-dir flask flask_cors

log "MAGI-1 setup complete"
log "Next: ./download_weights.sh"
log "Then run the one-GPU smoke test command in docs/video-magi1-streaming.md"
