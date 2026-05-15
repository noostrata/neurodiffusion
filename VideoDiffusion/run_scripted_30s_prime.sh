#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

POLICY_JSON="${MAGI_GPU_POLICY_JSON:-${REPO_ROOT}/scripts/prime/magi_gpu_policies.json}"
TMP_DIR="${SCRIPT_DIR}/.tmp"
mkdir -p "${TMP_DIR}"

MODE="lifecycle"
TIER=""
BUDGET_USD="${BUDGET_USD:-}"
REGIONS="${REGIONS:-}"
SCHEDULE_CSV="${SCHEDULE_CSV:-VideoDiffusion/prompt_schedules/cyberpunk_30s_hybrid.csv}"
RUN_TAG="${SCRIPTED_RUN_TAG:-prime_$(date +%Y%m%d_%H%M%S)_${RANDOM}}"
HOURLY_RATE_USD_ARG=""
DEVICES_ARG=""
RESTORE_MODE="${RESTORE_MODE:-${MAGI_RESTORE_MODE:-auto}}"
RUNTIME_TAG_ARG="${RUNTIME_TAG:-${MAGI_RUNTIME_TAG:-}}"
DRY_RUN="0"
SELECTION_GOAL="${SELECTION_GOAL:-realtime}"
MIN_GPU_COUNT="${MIN_GPU_COUNT:-0}"
MAX_PROVISION_RETRIES="${MAX_PROVISION_RETRIES:-4}"

PRIME_AVAILABILITY_ID_ARG="${PRIME_AVAILABILITY_ID:-}"
SELECTED_GPU_TYPE_ARG="${SELECTED_GPU_TYPE:-}"
SELECTED_GPU_COUNT_ARG="${SELECTED_GPU_COUNT:-}"
SELECTED_REGION_ARG="${SELECTED_REGION:-}"

usage() {
  cat <<'EOF'
Usage:
  bash VideoDiffusion/run_scripted_30s_prime.sh --mode lifecycle --tier 4.5b [options]
  bash VideoDiffusion/run_scripted_30s_prime.sh --mode in-pod --tier 24b [options]

Modes:
  lifecycle: discover/select/provision/run/terminate on Prime Intellect.
  in-pod: run the local in-pod scripted runner (test_scripted_30s.sh).

Options:
  --mode <lifecycle|in-pod>
  --tier <4.5b|24b>
  --budget-usd <float>           (default from policy, currently 15)
  --regions <csv>                (default from policy)
  --schedule-csv <path>          (default VideoDiffusion/prompt_schedules/cyberpunk_30s_hybrid.csv)
  --hourly-rate-usd <float>      (required for in-pod; inferred in lifecycle)
  --devices <csv>                (in-pod only; default derived from selected gpu count)
  --restore-mode <mode>          auto|tuple|image (lifecycle only; default auto)
  --runtime-tag <tag>            R2 runtime tuple tag for restore (lifecycle only)
  --selection-goal <goal>        realtime|cost (lifecycle only; default realtime)
  --min-gpu-count <int>          force minimum selected gpu count (lifecycle only)
  --max-provision-retries <int>  max total provision attempts with auto reselection (default 4)
  --run-tag <string>             (artifact/run correlation tag)
  --dry-run                      (lifecycle discovery + selection only)

Lifecycle override options (skip discovery/selection):
  --availability-id <id>
  --selected-gpu-type <type>
  --selected-gpu-count <int>
  --selected-region <region>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --tier)
      TIER="$2"
      shift 2
      ;;
    --budget-usd)
      BUDGET_USD="$2"
      shift 2
      ;;
    --regions)
      REGIONS="$2"
      shift 2
      ;;
    --schedule-csv)
      SCHEDULE_CSV="$2"
      shift 2
      ;;
    --hourly-rate-usd)
      HOURLY_RATE_USD_ARG="$2"
      shift 2
      ;;
    --devices)
      DEVICES_ARG="$2"
      shift 2
      ;;
    --restore-mode)
      RESTORE_MODE="$2"
      shift 2
      ;;
    --runtime-tag)
      RUNTIME_TAG_ARG="$2"
      shift 2
      ;;
    --selection-goal)
      SELECTION_GOAL="$2"
      shift 2
      ;;
    --min-gpu-count)
      MIN_GPU_COUNT="$2"
      shift 2
      ;;
    --max-provision-retries)
      MAX_PROVISION_RETRIES="$2"
      shift 2
      ;;
    --run-tag)
      RUN_TAG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    --availability-id)
      PRIME_AVAILABILITY_ID_ARG="$2"
      shift 2
      ;;
    --selected-gpu-type)
      SELECTED_GPU_TYPE_ARG="$2"
      shift 2
      ;;
    --selected-gpu-count)
      SELECTED_GPU_COUNT_ARG="$2"
      shift 2
      ;;
    --selected-region)
      SELECTED_REGION_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${TIER}" ]]; then
  echo "[error] --tier is required." >&2
  usage
  exit 1
fi
if [[ "${TIER}" != "4.5b" && "${TIER}" != "24b" ]]; then
  echo "[error] --tier must be 4.5b or 24b." >&2
  exit 1
fi
if [[ "${MODE}" != "lifecycle" && "${MODE}" != "in-pod" ]]; then
  echo "[error] --mode must be lifecycle or in-pod." >&2
  exit 1
fi
if [[ "${SELECTION_GOAL}" != "realtime" && "${SELECTION_GOAL}" != "cost" ]]; then
  echo "[error] --selection-goal must be realtime or cost." >&2
  exit 1
fi
if ! [[ "${MIN_GPU_COUNT}" =~ ^[0-9]+$ ]]; then
  echo "[error] --min-gpu-count must be a non-negative integer." >&2
  exit 1
fi
if ! [[ "${MAX_PROVISION_RETRIES}" =~ ^[0-9]+$ ]]; then
  echo "[error] --max-provision-retries must be a non-negative integer." >&2
  exit 1
fi
if [[ "${RESTORE_MODE}" != "auto" && "${RESTORE_MODE}" != "tuple" && "${RESTORE_MODE}" != "image" ]]; then
  echo "[error] --restore-mode must be auto, tuple, or image." >&2
  exit 1
fi
if [[ ! -f "${POLICY_JSON}" ]]; then
  echo "[error] Policy file not found: ${POLICY_JSON}" >&2
  exit 1
fi

DEFAULT_REGIONS="$(
  python3 - "${POLICY_JSON}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
print(",".join(d.get("regions_default", [])))
PY
)"
DEFAULT_BUDGET="$(
  python3 - "${POLICY_JSON}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
print(d.get("budget_defaults", {}).get("usd", 15))
PY
)"
CALIB_RUNG_LIST_DEFAULT="$(
  python3 - "${POLICY_JSON}" "${TIER}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
tier = sys.argv[2]
vals = d.get("tiers", {}).get(tier, {}).get("calibration_ladders", [])
print(",".join(str(int(x)) for x in vals if int(x) > 0))
PY
)"

if [[ -z "${REGIONS}" ]]; then
  REGIONS="${DEFAULT_REGIONS}"
fi
if [[ -z "${BUDGET_USD}" ]]; then
  BUDGET_USD="${DEFAULT_BUDGET}"
fi
if [[ -z "${CALIB_RUNG_LIST:-}" ]]; then
  export CALIB_RUNG_LIST="${CALIB_RUNG_LIST_DEFAULT}"
fi

abs_path() {
  local p="$1"
  if [[ "${p}" = /* ]]; then
    printf "%s\n" "${p}"
    return 0
  fi
  if [[ -f "${REPO_ROOT}/${p}" ]]; then
    printf "%s\n" "${REPO_ROOT}/${p}"
    return 0
  fi
  if [[ -f "${SCRIPT_DIR}/${p}" ]]; then
    printf "%s\n" "${SCRIPT_DIR}/${p}"
    return 0
  fi
  if [[ -f "${p}" ]]; then
    printf "%s\n" "$(cd -- "$(dirname -- "${p}")" && pwd)/$(basename -- "${p}")"
    return 0
  fi
  echo "[error] Path not found: ${p}" >&2
  return 1
}

repo_rel_path() {
  local p="$1"
  python3 - "${REPO_ROOT}" "${p}" <<'PY'
import os
import sys
repo = os.path.realpath(sys.argv[1])
path = os.path.realpath(sys.argv[2])
if os.path.commonpath([repo, path]) != repo:
    raise SystemExit(2)
print(os.path.relpath(path, repo))
PY
}

SCHEDULE_ABS="$(abs_path "${SCHEDULE_CSV}")"

if [[ "${MODE}" == "in-pod" ]]; then
  HOURLY_RATE_USD="${HOURLY_RATE_USD_ARG:-${HOURLY_RATE_USD:-}}"
  if [[ -z "${HOURLY_RATE_USD}" ]]; then
    echo "[error] in-pod mode requires --hourly-rate-usd (or HOURLY_RATE_USD)." >&2
    exit 1
  fi

  if [[ -n "${DEVICES_ARG}" ]]; then
    export CUDA_VISIBLE_DEVICES="${DEVICES_ARG}"
  else
    export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
  fi

  if [[ "${TIER}" == "24b" ]]; then
    export MAGI_TIER="24b"
    export MAGI_CONFIG_FILE="${MAGI_CONFIG_FILE:-MAGI-1/example/24B/24B_config.json}"
    export MAGI_NUM_STEPS="${MAGI_NUM_STEPS:-8}"
  else
    export MAGI_TIER="4p5b"
    # Default to reliable non-quant 4.5B flow to avoid missing distill calibration artifacts.
    export MAGI_CONFIG_FILE="${MAGI_CONFIG_FILE:-example/4.5B/4.5B_distill_config.json}"
    export MAGI_FP8="${MAGI_FP8:-0}"
    export MAGI_NUM_STEPS="${MAGI_NUM_STEPS:-16}"
  fi

  export BUDGET_USD
  export HOURLY_RATE_USD
  export SCHEDULE_CSV="${SCHEDULE_ABS}"
  export SCRIPTED_RUN_TAG="${RUN_TAG}"

  echo "[in-pod] tier=${TIER} devices=${CUDA_VISIBLE_DEVICES} budget=${BUDGET_USD} rate=${HOURLY_RATE_USD}"
  bash "${SCRIPT_DIR}/test_scripted_30s.sh"

  summary_path="$(find "${SCRIPT_DIR}/.tmp" -type f -name "*${RUN_TAG}*_summary.json" | head -n1 || true)"
  if [[ -n "${summary_path}" ]]; then
    echo "[in-pod] summary=${summary_path}"
  fi
  exit 0
fi

SCAN_JSON_BASE="${TMP_DIR}/magi_offer_scan_${TIER}_${RUN_TAG}"
SCAN_CSV_BASE="${TMP_DIR}/magi_offer_scan_${TIER}_${RUN_TAG}"
SELECT_JSON_BASE="${TMP_DIR}/magi_selected_offer_${TIER}_${RUN_TAG}"
SCAN_JSON="${SCAN_JSON_BASE}.json"
SCAN_CSV="${SCAN_CSV_BASE}.csv"
SELECT_JSON="${SELECT_JSON_BASE}.json"
TELEMETRY_JSONL="${TMP_DIR}/magi_lifecycle_telemetry_${RUN_TAG}.jsonl"
SCHEDULE_REL="$(repo_rel_path "${SCHEDULE_ABS}")"
: > "${TELEMETRY_JSONL}"

PRIME_AVAILABILITY_ID="${PRIME_AVAILABILITY_ID_ARG}"
SELECTED_GPU_TYPE="${SELECTED_GPU_TYPE_ARG}"
SELECTED_GPU_COUNT="${SELECTED_GPU_COUNT_ARG}"
SELECTED_REGION="${SELECTED_REGION_ARG}"
HOURLY_RATE_USD="${HOURLY_RATE_USD_ARG:-${HOURLY_RATE_USD:-}}"

append_telemetry() {
  local status="$1"
  local attempt="$2"
  local message="${3:-}"
  python3 - "${TELEMETRY_JSONL}" "${status}" "${RUN_TAG}" "${TIER}" "${SELECTION_GOAL}" "${attempt}" "${PRIME_AVAILABILITY_ID:-}" "${SELECTED_GPU_TYPE:-}" "${SELECTED_GPU_COUNT:-}" "${SELECTED_REGION:-}" "${HOURLY_RATE_USD:-}" "${message}" <<'PY'
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]
payload = {
    "ts_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "status": sys.argv[2],
    "run_tag": sys.argv[3],
    "tier": sys.argv[4],
    "selection_goal": sys.argv[5],
    "attempt": int(sys.argv[6]),
    "availability_id": sys.argv[7],
    "gpu_type": sys.argv[8],
    "gpu_count": sys.argv[9],
    "region": sys.argv[10],
    "hourly_rate_usd": sys.argv[11],
    "message": sys.argv[12],
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, ensure_ascii=True) + "\n")
PY
}

run_query_and_select_attempt() {
  local attempt="$1"
  local excluded_ids="$2"
  local attempt_scan_json="${SCAN_JSON_BASE}_attempt${attempt}.json"
  local attempt_scan_csv="${SCAN_CSV_BASE}_attempt${attempt}.csv"
  local attempt_select_json="${SELECT_JSON_BASE}_attempt${attempt}.json"
  if [[ "${DRY_RUN}" == "1" ]]; then
    python3 "${REPO_ROOT}/scripts/prime/query_magi_offers.py" \
      --tier "${TIER}" \
      --regions "${REGIONS}" \
      --policy "${POLICY_JSON}" \
      --out-json "${attempt_scan_json}" \
      --out-csv "${attempt_scan_csv}" \
      --dry-run
  else
    python3 "${REPO_ROOT}/scripts/prime/query_magi_offers.py" \
      --tier "${TIER}" \
      --regions "${REGIONS}" \
      --policy "${POLICY_JSON}" \
      --out-json "${attempt_scan_json}" \
      --out-csv "${attempt_scan_csv}"
  fi
  cp -f "${attempt_scan_json}" "${SCAN_JSON}"
  cp -f "${attempt_scan_csv}" "${SCAN_CSV}"

  select_output="$(
    python3 "${REPO_ROOT}/scripts/prime/select_magi_offer.py" \
      --scan-json "${attempt_scan_json}" \
      --policy "${POLICY_JSON}" \
      --selection-goal "${SELECTION_GOAL}" \
      --min-gpu-count "${MIN_GPU_COUNT}" \
      --exclude-availability-ids "${excluded_ids}" \
      --out-json "${attempt_select_json}" \
      --print-env
  )"
  echo "${select_output}"
  cp -f "${attempt_select_json}" "${SELECT_JSON}"

  while IFS='=' read -r key value; do
    case "${key}" in
      PRIME_AVAILABILITY_ID) PRIME_AVAILABILITY_ID="${value}" ;;
      SELECTED_GPU_TYPE) SELECTED_GPU_TYPE="${value}" ;;
      SELECTED_GPU_COUNT) SELECTED_GPU_COUNT="${value}" ;;
      HOURLY_RATE_USD) HOURLY_RATE_USD="${value}" ;;
      SELECTED_REGION) SELECTED_REGION="${value}" ;;
    esac
  done < <(printf "%s\n" "${select_output}" | grep -E '^(PRIME_AVAILABILITY_ID|SELECTED_GPU_TYPE|SELECTED_GPU_COUNT|HOURLY_RATE_USD|SELECTED_REGION)=' || true)
}

AUTO_SELECT="0"
if [[ -z "${PRIME_AVAILABILITY_ID}" ]]; then
  AUTO_SELECT="1"
  run_query_and_select_attempt "1" ""
fi

if [[ -z "${PRIME_AVAILABILITY_ID}" || -z "${HOURLY_RATE_USD}" ]]; then
  echo "[error] lifecycle mode requires a selected availability and hourly rate." >&2
  exit 1
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  append_telemetry "dry_run_selected" "1" "dry-run completed"
  echo "[lifecycle] dry-run complete."
  echo "[lifecycle] tier=${TIER}"
  echo "[lifecycle] restore_mode=${RESTORE_MODE}"
  echo "[lifecycle] runtime_tag=${RUNTIME_TAG_ARG:-<unset>}"
  echo "[lifecycle] selection_goal=${SELECTION_GOAL}"
  echo "[lifecycle] min_gpu_count=${MIN_GPU_COUNT}"
  echo "[lifecycle] max_provision_retries=${MAX_PROVISION_RETRIES}"
  echo "[lifecycle] availability_id=${PRIME_AVAILABILITY_ID}"
  echo "[lifecycle] gpu_type=${SELECTED_GPU_TYPE}"
  echo "[lifecycle] gpu_count=${SELECTED_GPU_COUNT}"
  echo "[lifecycle] region=${SELECTED_REGION}"
  echo "[lifecycle] hourly_rate_usd=${HOURLY_RATE_USD}"
  echo "[lifecycle] scan_json=${SCAN_JSON}"
  echo "[lifecycle] selected_json=${SELECT_JSON}"
  echo "[lifecycle] telemetry_jsonl=${TELEMETRY_JSONL}"
  exit 0
fi

POD_CREATED="0"
POD_ID=""
cleanup() {
  if [[ "${POD_CREATED}" == "1" && -n "${POD_ID}" ]]; then
    PRIME_POD_ID="${POD_ID}" bash "${REPO_ROOT}/scripts/prime/terminate_magi_pod.sh" || true
  fi
}
trap cleanup EXIT

attempt=1
failed_availability_ids=""
attempt_limit=1
if [[ "${AUTO_SELECT}" == "1" ]]; then
  if [[ "${MAX_PROVISION_RETRIES}" -gt 0 ]]; then
    attempt_limit="${MAX_PROVISION_RETRIES}"
  fi
fi

while [[ "${attempt}" -le "${attempt_limit}" ]]; do
  if [[ "${AUTO_SELECT}" == "1" && "${attempt}" -gt 1 ]]; then
    run_query_and_select_attempt "${attempt}" "${failed_availability_ids}"
  fi
  if [[ -z "${PRIME_AVAILABILITY_ID}" || -z "${HOURLY_RATE_USD}" ]]; then
    echo "[error] selection did not produce availability_id/hourly_rate on attempt=${attempt}." >&2
    append_telemetry "selection_failed" "${attempt}" "missing availability/rate"
    exit 1
  fi

  echo "[lifecycle] provision attempt ${attempt}/${attempt_limit} availability_id=${PRIME_AVAILABILITY_ID} gpu=${SELECTED_GPU_TYPE} x${SELECTED_GPU_COUNT} region=${SELECTED_REGION} rate=${HOURLY_RATE_USD}"
  append_telemetry "provision_attempt" "${attempt}" "starting provision"

  set +e
  provision_out="$(
    PRIME_AVAILABILITY_ID="${PRIME_AVAILABILITY_ID}" \
    MAGI_RUN_ID="${RUN_TAG}" \
    bash "${REPO_ROOT}/scripts/prime/provision_magi_pod.sh" 2>&1
  )"
  provision_rc=$?
  set -e
  echo "${provision_out}"

  if [[ "${provision_rc}" -eq 0 ]]; then
    POD_ID="$(printf "%s\n" "${provision_out}" | awk -F= '/^PRIME_POD_ID=/{print $2; exit}')"
    if [[ -n "${POD_ID}" ]]; then
      POD_CREATED="1"
      append_telemetry "provision_ready" "${attempt}" "pod_id=${POD_ID}"
      break
    fi
    provision_rc=97
  fi

  append_telemetry "provision_failed" "${attempt}" "create rc=${provision_rc}"
  if [[ "${AUTO_SELECT}" == "1" && "${attempt}" -lt "${attempt_limit}" ]]; then
    if [[ -n "${PRIME_AVAILABILITY_ID}" ]]; then
      if [[ -n "${failed_availability_ids}" ]]; then
        failed_availability_ids="${failed_availability_ids},${PRIME_AVAILABILITY_ID}"
      else
        failed_availability_ids="${PRIME_AVAILABILITY_ID}"
      fi
    fi
    echo "[warn] provision failed on attempt=${attempt}; retrying with a different availability_id."
    attempt=$((attempt + 1))
    continue
  fi

  echo "[error] provision failed after ${attempt} attempt(s)." >&2
  echo "[error] telemetry_jsonl=${TELEMETRY_JSONL}" >&2
  exit "${provision_rc}"
done

if [[ "${POD_CREATED}" != "1" || -z "${POD_ID}" ]]; then
  echo "[error] failed to provision pod." >&2
  echo "[error] telemetry_jsonl=${TELEMETRY_JSONL}" >&2
  exit 1
fi

set +e
MAGI_TIER="${TIER}" \
PRIME_POD_ID="${POD_ID}" \
SELECTED_GPU_COUNT="${SELECTED_GPU_COUNT:-1}" \
HOURLY_RATE_USD="${HOURLY_RATE_USD}" \
BUDGET_USD="${BUDGET_USD}" \
MAGI_RUN_ID="${RUN_TAG}" \
SCHEDULE_CSV="${SCHEDULE_REL}" \
MAGI_RESTORE_MODE="${RESTORE_MODE}" \
MAGI_RUNTIME_TAG="${RUNTIME_TAG_ARG}" \
bash "${REPO_ROOT}/scripts/prime/run_magi_remote.sh"
REMOTE_RC=$?
set -e
if [[ "${REMOTE_RC}" -ne 0 ]]; then
  append_telemetry "remote_failed" "${attempt}" "run_magi_remote rc=${REMOTE_RC}"
  echo "[error] remote execution failed rc=${REMOTE_RC}" >&2
  echo "[error] telemetry_jsonl=${TELEMETRY_JSONL}" >&2
  exit "${REMOTE_RC}"
fi

append_telemetry "completed" "${attempt}" "lifecycle success"
echo "[lifecycle] completed tier=${TIER} pod_id=${POD_ID}"
echo "[lifecycle] telemetry_jsonl=${TELEMETRY_JSONL}"
