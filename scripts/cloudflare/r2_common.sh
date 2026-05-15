#!/usr/bin/env bash

r2_has_boto3() {
  local py="$1"
  "${py}" - <<'PY' >/dev/null 2>&1
import boto3  # noqa: F401
PY
}

r2_resolve_python_with_boto3() {
  local candidate=""
  for candidate in \
    "${R2_BOOTSTRAP_VENV}/bin/python" \
    "${PYTHON_BIN:-python3}" \
    "python3"; do
    if command -v "${candidate}" >/dev/null 2>&1 && r2_has_boto3 "${candidate}"; then
      printf "%s\n" "${candidate}"
      return 0
    fi
  done
  return 1
}

r2_ensure_python_with_boto3() {
  local quiet="${1:-1}"
  local need_bootstrap="0"

  : "${REPO_ROOT:?Set REPO_ROOT before sourcing r2_common.sh}"
  : "${R2_BOOTSTRAP_VENV:?Set R2_BOOTSTRAP_VENV before sourcing r2_common.sh}"

  if [[ ! -x "${R2_BOOTSTRAP_VENV}/bin/python" ]]; then
    need_bootstrap="1"
  elif ! r2_has_boto3 "${R2_BOOTSTRAP_VENV}/bin/python"; then
    need_bootstrap="1"
  fi

  if [[ "${need_bootstrap}" == "1" ]]; then
    if [[ "${quiet}" == "1" ]]; then
      bash "${REPO_ROOT}/scripts/cloudflare/bootstrap_r2.sh" --dry-run >/dev/null
    else
      bash "${REPO_ROOT}/scripts/cloudflare/bootstrap_r2.sh" --dry-run >&2
    fi
  fi

  if ! r2_resolve_python_with_boto3; then
    echo "[error] boto3 is not available in helper or system python after bootstrap." >&2
    return 1
  fi
}
