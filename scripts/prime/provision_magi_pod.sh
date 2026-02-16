#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${PRIME_CONFIG_FILE:-${REPO_ROOT}/config/prime.env}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

if ! command -v prime >/dev/null 2>&1; then
  echo "[error] prime CLI not found in PATH." >&2
  exit 1
fi

: "${PRIME_AVAILABILITY_ID:?Set PRIME_AVAILABILITY_ID (availability offer short ID).}"

RUN_ID="${MAGI_RUN_ID:-$(date +%Y%m%d_%H%M%S)_${RANDOM}}"
POD_NAME="${PRIME_POD_NAME:-magi-${RUN_ID}}"
POD_IMAGE="${PRIME_POD_IMAGE:-ubuntu_22_cuda_12}"
POD_DISK_GB="${PRIME_POD_DISK_GB:-120}"
POLL_INTERVAL_S="${PRIME_POD_POLL_INTERVAL_S:-5}"
PROVISION_TIMEOUT_S="${PRIME_POD_TIMEOUT_S:-900}"
OUT_DIR="${REPO_ROOT}/VideoDiffusion/.tmp"
OUT_JSON="${OUT_DIR}/magi_pod_${RUN_ID}.json"

mkdir -p "${OUT_DIR}"

echo "[provision] creating pod name=${POD_NAME} availability_id=${PRIME_AVAILABILITY_ID} image=${POD_IMAGE} disk=${POD_DISK_GB}GB"
CREATE_OUTPUT="$(
  prime pods create \
    --id "${PRIME_AVAILABILITY_ID}" \
    --name "${POD_NAME}" \
    --image "${POD_IMAGE}" \
    --disk-size "${POD_DISK_GB}" \
    --yes 2>&1
)"
echo "${CREATE_OUTPUT}"

extract_pod_id_from_list() {
  local name="$1"
  prime pods list -o json | python3 -c '
import json
import sys

target = sys.argv[1]
data = json.load(sys.stdin)
pods = data.get("pods") if isinstance(data, dict) else data
if not isinstance(pods, list):
    raise SystemExit(1)
for pod in pods:
    if not isinstance(pod, dict):
        continue
    if (pod.get("name") or "") == target:
        pod_id = str(pod.get("id") or "").strip()
        if pod_id:
            print(pod_id)
            raise SystemExit(0)
raise SystemExit(1)
' "${name}"
}

extract_pod_id_from_create_output() {
  python3 -c '
import re
import sys
txt = sys.stdin.read()
m = re.search(r"\b[a-f0-9]{32}\b", txt)
if not m:
    raise SystemExit(1)
print(m.group(0))
'
}

parse_status_line() {
  python3 -c '
import json
import sys
d = json.load(sys.stdin)
status = str(d.get("status") or "").strip()
ip = str(d.get("ip") or "").strip()
ssh = str(d.get("ssh") or "").strip()
print("\t".join([status, ip, ssh]))
'
}

POD_ID=""
deadline=$((SECONDS + PROVISION_TIMEOUT_S))
while [[ -z "${POD_ID}" && ${SECONDS} -lt ${deadline} ]]; do
  if pod_id="$(extract_pod_id_from_list "${POD_NAME}" 2>/dev/null)"; then
    POD_ID="${pod_id}"
    break
  fi
  sleep "${POLL_INTERVAL_S}"
done

if [[ -z "${POD_ID}" ]]; then
  if pod_id="$(printf "%s" "${CREATE_OUTPUT}" | extract_pod_id_from_create_output 2>/dev/null)"; then
    POD_ID="${pod_id}"
  fi
fi

if [[ -z "${POD_ID}" ]]; then
  echo "[error] Could not resolve pod ID for pod name '${POD_NAME}'." >&2
  exit 1
fi

echo "[provision] pod id=${POD_ID}"

READY="0"
LAST_STATUS=""
LAST_IP=""
LAST_SSH=""
while [[ ${SECONDS} -lt ${deadline} ]]; do
  status_json="$(prime pods status "${POD_ID}" -o json)"
  IFS=$'\t' read -r status ip ssh <<<"$(printf "%s" "${status_json}" | parse_status_line)"
  LAST_STATUS="${status}"
  LAST_IP="${ip}"
  LAST_SSH="${ssh}"

  case "${status}" in
    TERMINATED|FAILED|ERROR|DELETED)
      echo "[error] Pod entered failure state: ${status}" >&2
      printf "%s\n" "${status_json}" > "${OUT_JSON}"
      exit 1
      ;;
  esac

  if [[ -n "${ssh}" && "${ssh}" != "N/A" && -n "${ip}" && "${ip}" != "N/A" ]]; then
    READY="1"
    break
  fi

  sleep "${POLL_INTERVAL_S}"
done

status_json="$(prime pods status "${POD_ID}" -o json)"
python3 -c '
import json
import sys
from datetime import datetime, timezone

raw_json, out_json, run_id, pod_name, availability_id, pod_id, ready = sys.argv[1:]
d = json.loads(raw_json)
payload = {
    "run_id": run_id,
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "pod_name": pod_name,
    "pod_id": pod_id,
    "availability_id": availability_id,
    "ready": bool(int(ready)),
    "pod_status": d,
}
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
' "${status_json}" "${OUT_JSON}" "${RUN_ID}" "${POD_NAME}" "${PRIME_AVAILABILITY_ID}" "${POD_ID}" "${READY}"

if [[ "${READY}" != "1" ]]; then
  echo "[error] Pod did not become SSH-ready within timeout (${PROVISION_TIMEOUT_S}s)." >&2
  echo "[error] Last status=${LAST_STATUS} ip=${LAST_IP} ssh=${LAST_SSH}" >&2
  echo "[error] Metadata: ${OUT_JSON}" >&2
  exit 1
fi

echo "[provision] ready status=${LAST_STATUS} ip=${LAST_IP}"
echo "PRIME_POD_ID=${POD_ID}"
echo "PRIME_POD_NAME=${POD_NAME}"
echo "MAGI_POD_METADATA_JSON=${OUT_JSON}"
