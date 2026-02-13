#!/usr/bin/env bash
# Download MAGI-1 weights via the Hugging Face CLI.

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/MAGI-1"
TARGET_REPO_ID="sand-ai/MAGI-1"
WEIGHT_VARIANT="${VIDEO_MAGE_WEIGHT_VARIANT:-4.5B_distill_quant}"

case "$WEIGHT_VARIANT" in
  4.5B|4.5B_distill|4.5B_distill_quant)
    WEIGHT_VARIANT_NAME="4.5B_distill_quant"
    WEIGHT_VARIANT_PATH="ckpt/magi/${WEIGHT_VARIANT_NAME}/*"
    if [ "${WEIGHT_VARIANT}" = "4.5B_distill" ]; then
      WEIGHT_VARIANT_NAME="4.5B_distill"
      WEIGHT_VARIANT_PATH="ckpt/magi/${WEIGHT_VARIANT_NAME}/*"
    fi
    ;;
  24B|24B_distill_quant)
    WEIGHT_VARIANT_NAME="24B_distill_quant"
    WEIGHT_VARIANT_PATH="ckpt/magi/${WEIGHT_VARIANT_NAME}/*"
    ;;
  *)
    echo "Error: unsupported VIDEO_MAGE_WEIGHT_VARIANT='${WEIGHT_VARIANT}'."
    echo "Supported values: 4.5B, 4.5B_distill, 4.5B_distill_quant, 24B, 24B_distill_quant"
    exit 1
    ;;
esac

# --- Ensure Environment Activated ---
# Check if git and git-lfs are available (still needed for repo check)
if ! command -v git &> /dev/null; then
    echo "Error: git command not found."
    exit 1
fi

# If setup.sh created a venv, prefer its `hf` binary so users don't need to activate it.
VIDEO_MAGE_VENV_DIR="${VIDEO_MAGE_VENV_DIR:-${SCRIPT_DIR}/.venv}"

# Prefer the modern `hf` CLI; fall back to `huggingface-cli`.
HF_BIN=""
if [ -x "${VIDEO_MAGE_VENV_DIR}/bin/hf" ]; then
    HF_BIN="${VIDEO_MAGE_VENV_DIR}/bin/hf"
elif command -v hf &> /dev/null; then
    HF_BIN="hf"
elif [ -x "${VIDEO_MAGE_VENV_DIR}/bin/huggingface-cli" ]; then
    HF_BIN="${VIDEO_MAGE_VENV_DIR}/bin/huggingface-cli"
elif command -v huggingface-cli &> /dev/null; then
    HF_BIN="huggingface-cli"
else
    echo "Error: neither 'hf' nor 'huggingface-cli' was found."
    echo "Run: bash setup.sh (installs it into ${VIDEO_MAGE_VENV_DIR})"
    exit 1
fi

# --- Check/Update Repo ---
echo ">>> [Step 5] Ensuring MAGI-1 repository is present..."
if [ ! -d "${REPO_DIR}" ]; then
    echo "MAGI-1 directory not found. Please run setup.sh first."
    exit 1
else
    echo "MAGI-1 directory found."
fi

# --- Ensure Logged into Hugging Face ---
echo ">>> [Step 5] Ensure you are logged into Hugging Face CLI."
echo "If the downloads fail, run one of these first:"
echo "  hf auth login"
echo "  huggingface-cli login"
# Add an explicit check or login attempt here if needed

# --- Download Files ---
cd "${REPO_DIR}" # Execute downloads *inside* the MAGI-1 directory

# --- Main Model Weights ---
MODEL_WEIGHTS_INCLUDE_PATTERN="${WEIGHT_VARIANT_PATH}"
echo ">>> [Step 5] Downloading ${WEIGHT_VARIANT} distilled weights..."
mkdir -p ./ckpt/magi # Ensure parent directories exist
if [ -d "./ckpt/magi/${WEIGHT_VARIANT_NAME}" ] && [ -n "$(ls -A "./ckpt/magi/${WEIGHT_VARIANT_NAME}" 2>/dev/null || true)" ]; then
    echo ">>> [Step 5] ckpt/magi/${WEIGHT_VARIANT_NAME} already populated; skipping model download."
else
    ${HF_BIN} download --repo-type model "${TARGET_REPO_ID}" \
    --include="${MODEL_WEIGHTS_INCLUDE_PATTERN}" \
    --local-dir .
fi

# --- VAE Weights ---
VAE_INCLUDE_PATTERN="ckpt/vae/*"
echo ">>> [Step 5] Downloading VAE Weights..."
mkdir -p ./ckpt # Ensure parent directory exists
if [ -d "./ckpt/vae" ] && [ -n "$(ls -A "./ckpt/vae" 2>/dev/null || true)" ]; then
    echo ">>> [Step 5] ckpt/vae already populated; skipping VAE download."
else
    ${HF_BIN} download --repo-type model "${TARGET_REPO_ID}" \
    --include="${VAE_INCLUDE_PATTERN}" \
    --local-dir .
fi

# --- T5 Weights ---
T5_LOCAL_DIR="./t5"
echo ">>> [Step 5] Downloading complete T5 snapshot to ${T5_LOCAL_DIR}..."
mkdir -p ${T5_LOCAL_DIR}
if [ -f "${T5_LOCAL_DIR}/config.json" ]; then
    echo ">>> [Step 5] ${T5_LOCAL_DIR} already looks populated; skipping T5 download."
else
    ${HF_BIN} download --repo-type model DeepFloyd/t5-v1_1-xxl \
        --local-dir "${T5_LOCAL_DIR}"
fi

# --- Normalize to upstream config layout ---
# Upstream example configs reference:
#   ./downloads/<variant>
#   ./downloads/vae
#   ./downloads/t5_pretrained/t5-v1_1-xxl
# To avoid copying huge files, we create symlinks into downloads/.
echo ">>> [Step 5] Normalizing weight layout for upstream configs (downloads/*)..."
mkdir -p "./downloads"
mkdir -p "./downloads/t5_pretrained"

ensure_link() {
  local src_rel="$1"
  local dst="$2"
  if [ -L "${dst}" ]; then
    ln -sfn "${src_rel}" "${dst}"
    return 0
  fi
  if [ -e "${dst}" ]; then
    echo ">>> [Step 5] NOTE: ${dst} exists (not a symlink). Leaving as-is."
    return 0
  fi
  ln -s "${src_rel}" "${dst}"
}

if [ -d "./ckpt/magi/${WEIGHT_VARIANT_NAME}" ]; then
  ensure_link "../ckpt/magi/${WEIGHT_VARIANT_NAME}" "./downloads/${WEIGHT_VARIANT_NAME}"
else
  echo ">>> [Step 5] WARN: missing ./ckpt/magi/${WEIGHT_VARIANT_NAME}; model symlink not created."
fi

if [ -d "./ckpt/vae" ]; then
  ensure_link "../ckpt/vae" "./downloads/vae"
else
  echo ">>> [Step 5] WARN: missing ./ckpt/vae; VAE symlink not created."
fi

if [ -d "./t5" ]; then
  ensure_link "../../t5" "./downloads/t5_pretrained/t5-v1_1-xxl"
else
  echo ">>> [Step 5] WARN: missing ./t5; T5 symlink not created."
fi

# Go back to original directory
cd ..

echo ">>> Weight download (Step 5) complete! <<<"
echo "Weights should now be present within the '${REPO_DIR}' directory structure."
if [ "${WEIGHT_VARIANT}" = "4.5B_distill" ]; then
  echo "For non-quant smoke tests, use:"
  echo "VIDEO_MAGE_FP8=0"
  echo "VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_config.json"
  echo "If motion is weak, use an explicit motion-heavy prompt."
else
  echo "For quantized smoke, use VIDEO_MAGE_CONFIG=example/4.5B/4.5B_distill_quant_config.json."
  echo "For explicit motion cues, prefer this prompt:"
  echo "\"Slow dolly shot through a busy cyberpunk alley at night, neon signs flickering, light rain, passing cars and pedestrians moving\""
fi
