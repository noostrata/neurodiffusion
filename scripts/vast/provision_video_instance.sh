#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${VAST_CONFIG_FILE:-${REPO_ROOT}/config/vast.env}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

if ! command -v vastai >/dev/null 2>&1; then
  echo "[error] vastai CLI not found in PATH." >&2
  exit 1
fi

: "${VAST_OFFER_ID:?Set VAST_OFFER_ID from scripts/vast/select_video_offer.py.}"

RUN_ID="${VAST_RUN_ID:-$(date +%Y%m%d_%H%M%S)_${RANDOM}}"
VAST_IMAGE="${VAST_IMAGE:-pytorch/pytorch:2.7.1-cuda12.8-cudnn9-devel}"
VAST_DISK_GB="${VAST_DISK_GB:-200}"
VAST_LABEL="${VAST_LABEL:-neurodiffusion_${RUN_ID}}"
VAST_ENV="${VAST_ENV:--p 8000:8000}"
VAST_ONSTART_CMD="${VAST_ONSTART_CMD:-touch ~/.no_auto_tmux; env >> /etc/environment}"
POLL_INTERVAL_S="${VAST_POLL_INTERVAL_S:-5}"
PROVISION_TIMEOUT_S="${VAST_PROVISION_TIMEOUT_S:-900}"
OUT_DIR="${REPO_ROOT}/VideoDiffusion/.tmp"
OUT_JSON="${OUT_DIR}/vast_instance_${RUN_ID}.json"

mkdir -p "${OUT_DIR}"

echo "[vast-provision] creating instance offer=${VAST_OFFER_ID} label=${VAST_LABEL} image=${VAST_IMAGE} disk=${VAST_DISK_GB}GB"
set +e
CREATE_OUTPUT="$(
  vastai create instance "${VAST_OFFER_ID}" \
    --image "${VAST_IMAGE}" \
    --disk "${VAST_DISK_GB}" \
    --ssh \
    --direct \
    --label "${VAST_LABEL}" \
    --env "${VAST_ENV}" \
    --onstart-cmd "${VAST_ONSTART_CMD}" \
    --cancel-unavail \
    --raw 2>&1
)"
CREATE_RC=$?
set -e
CREATE_OUTPUT_FOR_LOG="${CREATE_OUTPUT}" python3 - <<'PY'
import re
import os
import sys

raw = os.environ["CREATE_OUTPUT_FOR_LOG"]
raw = re.sub(r'("instance_api_key"\s*:\s*")[^"]+(")', r'\1<redacted>\2', raw)
print(raw, end="" if raw.endswith("\n") else "\n")
PY
if [[ "${CREATE_RC}" -ne 0 ]]; then
  echo "[error] vastai create instance failed with exit=${CREATE_RC}." >&2
  exit "${CREATE_RC}"
fi
create_succeeded="$(
  CREATE_OUTPUT_JSON="${CREATE_OUTPUT}" python3 - <<'PY'
import json
import os

raw = os.environ["CREATE_OUTPUT_JSON"].strip()
try:
    payload = json.loads(raw)
except Exception:
    payload = None

if isinstance(payload, dict) and payload.get("success") is True:
    print("1")
elif "failed with error" in raw.lower() or "no_such_ask" in raw.lower():
    print("0")
else:
    print("1" if payload is not None else "0")
PY
)"
if [[ "${create_succeeded}" != "1" ]]; then
  echo "[error] vastai create instance did not succeed; refusing to parse an instance id from error output." >&2
  exit 1
fi

extract_instance_id() {
  CREATE_OUTPUT_JSON="${CREATE_OUTPUT}" python3 - <<'PY'
import json
import os
import re
import sys

raw = os.environ["CREATE_OUTPUT_JSON"]
try:
    payload = json.loads(raw)
except Exception:
    payload = None

preferred = ("new_contract", "instance_id", "contract_id", "id")

def walk(obj):
    if isinstance(obj, dict):
        for key in preferred:
            value = obj.get(key)
            if isinstance(value, (int, str)) and str(value).strip().isdigit():
                print(str(value).strip())
                raise SystemExit(0)
        for value in obj.values():
            walk(value)
    elif isinstance(obj, list):
        for value in obj:
            walk(value)

if payload is not None:
    walk(payload)

m = re.search(r"\b\d{4,}\b", raw)
if m:
    print(m.group(0))
    raise SystemExit(0)
raise SystemExit(1)
PY
}

INSTANCE_ID="$(extract_instance_id 2>/dev/null || true)"
if [[ -z "${INSTANCE_ID}" ]]; then
  echo "[vast-provision] create output did not expose instance id; trying label lookup."
fi

find_instance_by_label() {
  INSTANCES_JSON="$(vastai show instances --raw)"
  INSTANCES_JSON="${INSTANCES_JSON}" python3 - "${VAST_LABEL}" <<'PY'
import json
import os
import sys
label = sys.argv[1]
payload = json.loads(os.environ["INSTANCES_JSON"])
instances = payload.get("instances") if isinstance(payload, dict) else payload
if not isinstance(instances, list):
    raise SystemExit(1)
for row in instances:
    if not isinstance(row, dict):
        continue
    if str(row.get("label") or row.get("name") or "") == label:
        value = row.get("id") or row.get("instance_id") or row.get("contract_id")
        if value:
            print(value)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

deadline=$((SECONDS + PROVISION_TIMEOUT_S))
while [[ -z "${INSTANCE_ID}" && ${SECONDS} -lt ${deadline} ]]; do
  INSTANCE_ID="$(find_instance_by_label 2>/dev/null || true)"
  if [[ -n "${INSTANCE_ID}" ]]; then
    break
  fi
  sleep "${POLL_INTERVAL_S}"
done

if [[ -z "${INSTANCE_ID}" ]]; then
  echo "[error] Could not resolve Vast instance ID for label '${VAST_LABEL}'." >&2
  exit 1
fi

echo "[vast-provision] instance id=${INSTANCE_ID}"

READY="0"
LAST_STATUS=""
START_ATTEMPTED="0"
while [[ ${SECONDS} -lt ${deadline} ]]; do
  instances_json="$(vastai show instances --raw)"
  instance_state="$(
    INSTANCES_JSON="${instances_json}" python3 - "${INSTANCE_ID}" <<'PY'
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
        values = [
            str(row.get("actual_status") or row.get("status") or "").strip(),
            str(row.get("cur_state") or "").strip(),
            str(row.get("intended_status") or "").strip(),
            str(row.get("status_msg") or "").replace("\n", " ").replace("\t", " ").strip(),
        ]
        print("\t".join(values))
        raise SystemExit(0)
print("\t\t\t")
PY
  )"
  IFS=$'\t' read -r status cur_state intended_status status_msg <<< "${instance_state}"
  LAST_STATUS="${status}"
  if [[ "${status}" == "running" ]]; then
    READY="1"
    printf "%s\n" "${instances_json}" > "${OUT_JSON}"
    break
  fi
  if [[ "${START_ATTEMPTED}" != "1" ]] && \
     [[ "${status}" == "stopped" || "${cur_state}" == "stopped" || "${intended_status}" == "stopped" ]] && \
     [[ "${status_msg}" == *"Successfully loaded"* ]]; then
    echo "[vast-provision] image loaded but instance is stopped; requesting start."
    vastai start instance "${INSTANCE_ID}" --raw || true
    START_ATTEMPTED="1"
  fi
  echo "[vast-provision] waiting status=${status:-unknown} cur_state=${cur_state:-unknown} intended=${intended_status:-unknown}"
  sleep "${POLL_INTERVAL_S}"
done

if [[ "${READY}" != "1" ]]; then
  vastai show instances --raw > "${OUT_JSON}" || true
  echo "[error] Vast instance did not reach running within timeout (${PROVISION_TIMEOUT_S}s). Last status=${LAST_STATUS:-unknown}" >&2
  echo "[error] Metadata: ${OUT_JSON}" >&2
  exit 1
fi

echo "[vast-provision] ready status=${LAST_STATUS}"
echo "VAST_INSTANCE_ID=${INSTANCE_ID}"
echo "VAST_LABEL=${VAST_LABEL}"
echo "VAST_INSTANCE_METADATA_JSON=${OUT_JSON}"
