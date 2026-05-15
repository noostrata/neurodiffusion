#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
R2_BOOTSTRAP_VENV="${R2_BOOTSTRAP_VENV:-${REPO_ROOT}/.venv/r2-bootstrap}"
APT_WAIT_MAX_S="${APT_WAIT_MAX_S:-300}"
APT_RETRY_COUNT="${APT_RETRY_COUNT:-3}"

wait_for_apt_lock() {
  local waited=0
  while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; do
    if [[ "${waited}" -ge "${APT_WAIT_MAX_S}" ]]; then
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 0
}

apt_with_retry() {
  local attempt=1
  while [[ "${attempt}" -le "${APT_RETRY_COUNT}" ]]; do
    if ! wait_for_apt_lock; then
      echo "[error] apt/dpkg lock did not clear within ${APT_WAIT_MAX_S}s." >&2
      return 1
    fi
    if DEBIAN_FRONTEND=noninteractive apt-get "$@" >/dev/null; then
      return 0
    fi
    if [[ "${attempt}" -lt "${APT_RETRY_COUNT}" ]]; then
      sleep $((attempt * 2))
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

has_boto3() {
  local py="$1"
  "${py}" - <<'PY' >/dev/null 2>&1
import boto3  # noqa: F401
PY
}

has_pip() {
  local py="$1"
  "${py}" -m pip --version >/dev/null 2>&1
}

R2_ENV_FILE="${R2_ENV_FILE:-/Users/xenochain/agents/secrets/r2_full_access.env}"
if [[ -f "${R2_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${R2_ENV_FILE}"
else
  if [[ -z "${AGENT_S3_BUCKET:-}" || -z "${AGENT_S3_ENDPOINT:-}" || -z "${AGENT_S3_ACCESS_KEY_ID:-}" || -z "${AGENT_S3_SECRET_ACCESS_KEY:-}" ]]; then
    echo "[error] R2 env file not found at '${R2_ENV_FILE}' and required AGENT_S3_* env vars are missing." >&2
    exit 1
  fi
fi

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "[error] Python interpreter not found: ${PYTHON_BIN}" >&2
  exit 1
fi

if ! has_boto3 "${PYTHON_BIN}"; then
  USE_HELPER_VENV="1"
  if [[ -x "${R2_BOOTSTRAP_VENV}/bin/python" ]] && ! has_pip "${R2_BOOTSTRAP_VENV}/bin/python"; then
    echo "[bootstrap] Repairing helper venv (pip missing): ${R2_BOOTSTRAP_VENV}"
    rm -rf "${R2_BOOTSTRAP_VENV}"
  fi
  if [[ ! -x "${R2_BOOTSTRAP_VENV}/bin/python" ]]; then
    echo "[bootstrap] Creating helper venv: ${R2_BOOTSTRAP_VENV}"
    if ! python3 -m venv "${R2_BOOTSTRAP_VENV}" >/dev/null 2>&1; then
      USE_HELPER_VENV="0"
    fi
  fi

  if [[ "${USE_HELPER_VENV}" == "1" ]] && ! has_pip "${R2_BOOTSTRAP_VENV}/bin/python"; then
    echo "[bootstrap] Repairing helper venv (pip unavailable after create): ${R2_BOOTSTRAP_VENV}"
    rm -rf "${R2_BOOTSTRAP_VENV}"
    if ! python3 -m venv "${R2_BOOTSTRAP_VENV}" >/dev/null 2>&1; then
      USE_HELPER_VENV="0"
    fi
  fi

  if [[ "${USE_HELPER_VENV}" == "1" ]]; then
    if ! has_boto3 "${R2_BOOTSTRAP_VENV}/bin/python"; then
      echo "[bootstrap] Installing boto3 into helper venv..."
      "${R2_BOOTSTRAP_VENV}/bin/python" -m pip install --upgrade pip >/dev/null
      "${R2_BOOTSTRAP_VENV}/bin/python" -m pip install boto3 >/dev/null
    fi
    if has_boto3 "${R2_BOOTSTRAP_VENV}/bin/python"; then
      PYTHON_BIN="${R2_BOOTSTRAP_VENV}/bin/python"
    fi
  fi

  if ! has_boto3 "${PYTHON_BIN}"; then
    if ! has_pip "${PYTHON_BIN}"; then
      if command -v apt-get >/dev/null 2>&1; then
        echo "[bootstrap] Installing python3-pip fallback via apt-get..."
        apt_with_retry update
        apt_with_retry install -y python3-pip
      else
        echo "[error] python3-pip is missing and apt-get is unavailable." >&2
        exit 1
      fi
    fi
    echo "[bootstrap] Installing boto3 into system python user site..."
    "${PYTHON_BIN}" -m pip install --user boto3 >/dev/null
  fi

  if ! has_boto3 "${PYTHON_BIN}"; then
    echo "[error] boto3 bootstrap failed for PYTHON_BIN=${PYTHON_BIN}" >&2
    exit 1
  fi
fi

ARGS=()
if [[ $# -gt 0 ]]; then
  ARGS=("$@")
fi
HAS_PREFIX_ARG="0"
for arg in "$@"; do
  if [[ "${arg}" == "--prefix" || "${arg}" == --prefix=* ]]; then
    HAS_PREFIX_ARG="1"
    break
  fi
done
if [[ "${HAS_PREFIX_ARG}" != "1" ]]; then
  ARGS+=(--prefix "${R2_PREFIX:-neurodiffusion}")
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/bootstrap_r2.py" "${ARGS[@]}"
