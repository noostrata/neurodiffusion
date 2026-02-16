#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${PRIME_CONFIG_FILE:-${REPO_ROOT}/config/prime.env}"
PRESET_PRIME_POD_ID="${PRIME_POD_ID+x}"
PRESET_PRIME_POD_ID_VAL="${PRIME_POD_ID:-}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi
if [[ -n "${PRESET_PRIME_POD_ID}" ]]; then
  PRIME_POD_ID="${PRESET_PRIME_POD_ID_VAL}"
fi

if ! command -v prime >/dev/null 2>&1; then
  echo "[error] prime CLI not found in PATH." >&2
  exit 1
fi

if [[ -z "${PRIME_POD_ID:-}" ]]; then
  echo "[terminate] PRIME_POD_ID is empty; nothing to terminate."
  exit 0
fi

status_json="$(prime pods status "${PRIME_POD_ID}" -o json 2>/dev/null || true)"
if [[ -z "${status_json}" ]]; then
  echo "[terminate] Pod '${PRIME_POD_ID}' not found or already removed."
  exit 0
fi

status="$(
  python3 -c '
import json
import sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit(0)
print((d.get("status") or "").strip())
' "${status_json}"
)"

if [[ "${status}" == "TERMINATED" ]]; then
  echo "[terminate] Pod '${PRIME_POD_ID}' already TERMINATED."
  exit 0
fi

echo "[terminate] Terminating pod '${PRIME_POD_ID}' (status=${status:-unknown})..."
prime pods terminate "${PRIME_POD_ID}" --yes
echo "[terminate] Done."
