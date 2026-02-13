#!/usr/bin/env bash
# Setup script for the SD-Turbo real-time streaming server on a Prime Intellect pod.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"
VENV_DIR="${VENV_DIR:-${PROJECT_DIR}/.venv}"

echo "[setup] installing OS deps"
cd "${PROJECT_DIR}"

if [[ ${EUID:-1000} -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

${SUDO} apt-get update -y
${SUDO} apt-get install -y --no-install-recommends git python3-pip python3-venv

echo "[setup] installing Python deps (this can take a while)"
if [[ ! -d "${VENV_DIR}" ]]; then
  python3 -m venv "${VENV_DIR}"
fi

VENV_PY="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_PY} -m pip"

${VENV_PIP} install --upgrade pip

REQ_FILE="${SCRIPT_DIR}/requirements.txt"
if [[ -f "${REQ_FILE}" ]]; then
  ${VENV_PIP} install -r "${REQ_FILE}"
else
  # Fallback if setup.sh was copied without requirements.txt
  ${VENV_PIP} install \
    --extra-index-url https://download.pytorch.org/whl/cu118 \
    "torch==2.0.1+cu118" "torchvision==0.15.2+cu118"
  ${VENV_PIP} install \
    "numpy==1.26.4" \
    "diffusers==0.24.0" "transformers==4.32.0" "accelerate==0.23.0" "xformers==0.0.22" \
    "Flask" "Flask-Cors"
fi

echo "[ok] setup complete"
echo "[next] start the server from your local machine:"
echo "       bash ImageDiffusion/start_stream_server.sh"
