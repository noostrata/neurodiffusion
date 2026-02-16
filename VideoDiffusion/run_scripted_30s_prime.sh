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
DRY_RUN="0"

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
    export MAGI_CONFIG_FILE="${MAGI_CONFIG_FILE:-example/4.5B/4.5B_distill_quant_config.json}"
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

SCAN_JSON="${TMP_DIR}/magi_offer_scan_${TIER}_${RUN_TAG}.json"
SCAN_CSV="${TMP_DIR}/magi_offer_scan_${TIER}_${RUN_TAG}.csv"
SELECT_JSON="${TMP_DIR}/magi_selected_offer_${TIER}_${RUN_TAG}.json"
SCHEDULE_REL="$(repo_rel_path "${SCHEDULE_ABS}")"

PRIME_AVAILABILITY_ID="${PRIME_AVAILABILITY_ID_ARG}"
SELECTED_GPU_TYPE="${SELECTED_GPU_TYPE_ARG}"
SELECTED_GPU_COUNT="${SELECTED_GPU_COUNT_ARG}"
SELECTED_REGION="${SELECTED_REGION_ARG}"
HOURLY_RATE_USD="${HOURLY_RATE_USD_ARG:-${HOURLY_RATE_USD:-}}"

if [[ -z "${PRIME_AVAILABILITY_ID}" ]]; then
  if [[ "${DRY_RUN}" == "1" ]]; then
    python3 "${REPO_ROOT}/scripts/prime/query_magi_offers.py" \
      --tier "${TIER}" \
      --regions "${REGIONS}" \
      --policy "${POLICY_JSON}" \
      --out-json "${SCAN_JSON}" \
      --out-csv "${SCAN_CSV}" \
      --dry-run
  else
    python3 "${REPO_ROOT}/scripts/prime/query_magi_offers.py" \
      --tier "${TIER}" \
      --regions "${REGIONS}" \
      --policy "${POLICY_JSON}" \
      --out-json "${SCAN_JSON}" \
      --out-csv "${SCAN_CSV}"
  fi

  select_output="$(
    python3 "${REPO_ROOT}/scripts/prime/select_magi_offer.py" \
      --scan-json "${SCAN_JSON}" \
      --policy "${POLICY_JSON}" \
      --out-json "${SELECT_JSON}" \
      --print-env
  )"
  echo "${select_output}"
  while IFS='=' read -r key value; do
    case "${key}" in
      PRIME_AVAILABILITY_ID) PRIME_AVAILABILITY_ID="${value}" ;;
      SELECTED_GPU_TYPE) SELECTED_GPU_TYPE="${value}" ;;
      SELECTED_GPU_COUNT) SELECTED_GPU_COUNT="${value}" ;;
      HOURLY_RATE_USD) HOURLY_RATE_USD="${value}" ;;
      SELECTED_REGION) SELECTED_REGION="${value}" ;;
    esac
  done < <(printf "%s\n" "${select_output}" | grep -E '^(PRIME_AVAILABILITY_ID|SELECTED_GPU_TYPE|SELECTED_GPU_COUNT|HOURLY_RATE_USD|SELECTED_REGION)=')
fi

if [[ -z "${PRIME_AVAILABILITY_ID}" || -z "${HOURLY_RATE_USD}" ]]; then
  echo "[error] lifecycle mode requires a selected availability and hourly rate." >&2
  exit 1
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "[lifecycle] dry-run complete."
  echo "[lifecycle] tier=${TIER}"
  echo "[lifecycle] availability_id=${PRIME_AVAILABILITY_ID}"
  echo "[lifecycle] gpu_type=${SELECTED_GPU_TYPE}"
  echo "[lifecycle] gpu_count=${SELECTED_GPU_COUNT}"
  echo "[lifecycle] region=${SELECTED_REGION}"
  echo "[lifecycle] hourly_rate_usd=${HOURLY_RATE_USD}"
  echo "[lifecycle] scan_json=${SCAN_JSON}"
  echo "[lifecycle] selected_json=${SELECT_JSON}"
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

provision_out="$(
  PRIME_AVAILABILITY_ID="${PRIME_AVAILABILITY_ID}" \
  MAGI_RUN_ID="${RUN_TAG}" \
  bash "${REPO_ROOT}/scripts/prime/provision_magi_pod.sh"
)"
echo "${provision_out}"
while IFS='=' read -r key value; do
  case "${key}" in
    PRIME_POD_ID) POD_ID="${value}" ;;
  esac
done < <(printf "%s\n" "${provision_out}" | grep -E '^PRIME_POD_ID=')

if [[ -z "${POD_ID}" ]]; then
  echo "[error] failed to parse PRIME_POD_ID from provision output." >&2
  exit 1
fi
POD_CREATED="1"

MAGI_TIER="${TIER}" \
PRIME_POD_ID="${POD_ID}" \
SELECTED_GPU_COUNT="${SELECTED_GPU_COUNT:-1}" \
HOURLY_RATE_USD="${HOURLY_RATE_USD}" \
BUDGET_USD="${BUDGET_USD}" \
MAGI_RUN_ID="${RUN_TAG}" \
SCHEDULE_CSV="${SCHEDULE_REL}" \
bash "${REPO_ROOT}/scripts/prime/run_magi_remote.sh"

echo "[lifecycle] completed tier=${TIER} pod_id=${POD_ID}"
