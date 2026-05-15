#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${VAST_CONFIG_FILE:-${REPO_ROOT}/config/vast.env}"
PRESET_VAST_INSTANCE_ID="${VAST_INSTANCE_ID+x}"
PRESET_VAST_INSTANCE_ID_VAL="${VAST_INSTANCE_ID:-}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi
if [[ -n "${PRESET_VAST_INSTANCE_ID}" ]]; then
  VAST_INSTANCE_ID="${PRESET_VAST_INSTANCE_ID_VAL}"
fi

if ! command -v vastai >/dev/null 2>&1; then
  echo "[error] vastai CLI not found in PATH." >&2
  exit 1
fi

if [[ -z "${VAST_INSTANCE_ID:-}" ]]; then
  echo "[vast-terminate] VAST_INSTANCE_ID is empty; nothing to terminate."
  exit 0
fi

instances_json="$(vastai show instances --raw)"
exists="$(
  INSTANCES_JSON="${instances_json}" python3 - "${VAST_INSTANCE_ID}" <<'PY'
import json
import os
import sys
target = str(sys.argv[1])
payload = json.loads(os.environ["INSTANCES_JSON"])
instances = payload.get("instances") if isinstance(payload, dict) else payload
for row in instances if isinstance(instances, list) else []:
    if not isinstance(row, dict):
        continue
    if str(row.get("id") or row.get("instance_id") or row.get("contract_id") or "") == target:
        print("1")
        raise SystemExit(0)
print("0")
PY
)"

if [[ "${exists}" != "1" ]]; then
  echo "[vast-terminate] Instance '${VAST_INSTANCE_ID}' not found or already removed."
  exit 0
fi

echo "[vast-terminate] Destroying instance '${VAST_INSTANCE_ID}'..."
vastai destroy instance "${VAST_INSTANCE_ID}" --raw
echo "[vast-terminate] Remaining instances:"
vastai show instances --raw
