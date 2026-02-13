#!/usr/bin/env bash
# Autostart helper (optional)
#
# Prime pods don't have a universal "template on-start script" mechanism.
# If you need autostart, use your preferred process manager (systemd, tmux, nohup).

set -euo pipefail

LOG_FILE="/root/magi_onstart.log"
PROJECT_DIR="${VIDEO_DIFFUSION_DIR:-/root/VideoDiffusion}"
MAGI_DIR="${PROJECT_DIR}/MAGI-1"
STREAM_SCRIPT="${PROJECT_DIR}/realtime_magi_stream.py"
# ENV_NAME="magi" # No longer needed

echo "Executing onstart.sh at $(date)" >> ${LOG_FILE}

# Source Conda environment - Removed
# echo "Sourcing Conda..." >> ${LOG_FILE}
# source /opt/conda/etc/profile.d/conda.sh || echo "Failed to source conda" >> ${LOG_FILE}

# Activate Conda environment - Removed
# echo "Activating environment ${ENV_NAME}..." >> ${LOG_FILE}
# conda activate ${ENV_NAME} || echo "Failed to activate conda env ${ENV_NAME}" >> ${LOG_FILE}

PYTHON_BIN="python3"
if ! command -v "${PYTHON_BIN}" &> /dev/null; then
  PYTHON_BIN="python"
fi
if ! command -v "${PYTHON_BIN}" &> /dev/null; then
  echo "Error: python not found. Cannot run script." >> ${LOG_FILE}
  exit 1
fi

# Navigate to the code directory
if [ -d "${PROJECT_DIR}" ]; then
  echo "Changing directory to ${PROJECT_DIR}..." >> ${LOG_FILE}
  cd "${PROJECT_DIR}"
else
  echo "Error: Directory ${PROJECT_DIR} not found." >> ${LOG_FILE}
  exit 1
fi

if [ ! -d "${MAGI_DIR}" ]; then
  echo "Error: MAGI-1 directory not found at ${MAGI_DIR}." >> ${LOG_FILE}
  exit 1
fi

# Check if the stream script exists
if [ -f "${STREAM_SCRIPT}" ]; then
  # Set environment variables (adjust GPU count if needed)
  export CUDA_VISIBLE_DEVICES="${VIDEO_MAGE_VISIBLE_DEVICES:-0}"
  echo "Starting ${STREAM_SCRIPT} using ${PYTHON_BIN}... Outputting to ${LOG_FILE}" >> ${LOG_FILE}
  # Run the script in the background, redirecting stdout and stderr
  "${PYTHON_BIN}" "${STREAM_SCRIPT}" >> "${LOG_FILE}" 2>&1 &
  echo "${STREAM_SCRIPT} started in background." >> ${LOG_FILE}
else
  echo "Error: Stream script ${STREAM_SCRIPT} not found." >> ${LOG_FILE}
  exit 1
fi

echo "onstart.sh finished at $(date)" >> ${LOG_FILE} 
