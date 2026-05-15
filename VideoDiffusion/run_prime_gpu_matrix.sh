#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
POLICY_JSON="${MAGI_GPU_POLICY_JSON:-${REPO_ROOT}/scripts/prime/magi_gpu_policies.json}"

TIER=""
BUDGET_USD="${BUDGET_USD:-}"
REGIONS="${REGIONS:-}"
SCHEDULE_CSV="${SCHEDULE_CSV:-VideoDiffusion/prompt_schedules/cyberpunk_30s_hybrid.csv}"
SLICE_BUDGET_USD="${MATRIX_SLICE_USD:-3}"
MAX_RUNS="${MATRIX_MAX_RUNS:-10}"
RESTORE_MODE="${RESTORE_MODE:-auto}"
RUNTIME_TAG="${RUNTIME_TAG:-}"
DRY_RUN="0"

usage() {
  cat <<'EOF'
Usage:
  bash VideoDiffusion/run_prime_gpu_matrix.sh --tier <4.5b|24b> [options]

Options:
  --tier <4.5b|24b>       Required.
  --budget-usd <float>    Total matrix budget. Default from policy.
  --slice-usd <float>     Per-candidate budget slice. Default 3.
  --regions <csv>         Region override. Default from policy.
  --schedule-csv <path>   Prompt schedule CSV.
  --max-runs <int>        Maximum candidate attempts.
  --restore-mode <mode>   auto|tuple|image (default: auto)
  --runtime-tag <tag>     Runtime tag for R2 restore path.
  --dry-run               Do not provision pods; only produce planned matrix report.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      TIER="$2"
      shift 2
      ;;
    --budget-usd)
      BUDGET_USD="$2"
      shift 2
      ;;
    --slice-usd)
      SLICE_BUDGET_USD="$2"
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
    --max-runs)
      MAX_RUNS="$2"
      shift 2
      ;;
    --restore-mode)
      RESTORE_MODE="$2"
      shift 2
      ;;
    --runtime-tag)
      RUNTIME_TAG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${TIER}" ]]; then
  echo "[error] --tier is required." >&2
  exit 1
fi
if [[ "${TIER}" != "4.5b" && "${TIER}" != "24b" ]]; then
  echo "[error] --tier must be 4.5b or 24b." >&2
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

if [[ -z "${REGIONS}" ]]; then
  REGIONS="$(
    python3 - "${POLICY_JSON}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
print(",".join(d.get("regions_default", [])))
PY
  )"
fi
if [[ -z "${BUDGET_USD}" ]]; then
  BUDGET_USD="$(
    python3 - "${POLICY_JSON}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
print(d.get("budget_defaults", {}).get("usd", 15))
PY
  )"
fi

OUT_JSON="${SCRIPT_DIR}/.tmp/magi_matrix_${TIER}.json"
OUT_CSV="${SCRIPT_DIR}/.tmp/magi_matrix_${TIER}.csv"
SCAN_JSON="${SCRIPT_DIR}/.tmp/magi_offer_scan_${TIER}_matrix.json"
SCAN_CSV="${SCRIPT_DIR}/.tmp/magi_offer_scan_${TIER}_matrix.csv"
CANDIDATES_TSV="${SCRIPT_DIR}/.tmp/magi_matrix_candidates_${TIER}.tsv"

mkdir -p "${SCRIPT_DIR}/.tmp"
printf "run_idx,run_tag,availability_id,gpu_type,gpu_count,region,provider,hourly_rate_usd,budget_slice_usd,cost_estimate_usd,steady_tpoc_p90_s,cue_fidelity_ratio,pass,exit_code,status,summary_json\n" > "${OUT_CSV}"

python3 "${REPO_ROOT}/scripts/prime/query_magi_offers.py" \
  --tier "${TIER}" \
  --regions "${REGIONS}" \
  --policy "${POLICY_JSON}" \
  --out-json "${SCAN_JSON}" \
  --out-csv "${SCAN_CSV}"

python3 - "${SCAN_JSON}" "${POLICY_JSON}" "${TIER}" "${CANDIDATES_TSV}" <<'PY'
import json
import sys

scan_path, policy_path, tier, out_path = sys.argv[1:]

with open(scan_path, "r", encoding="utf-8") as f:
    scan = json.load(f)
with open(policy_path, "r", encoding="utf-8") as f:
    policy = json.load(f)

offers = scan.get("offers", [])
min_viable = int(policy.get("tiers", {}).get(tier, {}).get("min_viable_nproc", 1))
regions = policy.get("regions_default", [])
region_rank = {r: i for i, r in enumerate(regions)}

rows = []
for o in offers:
    if not isinstance(o, dict):
        continue
    try:
        gpu_count = int(o.get("gpu_count"))
        price = float(o.get("price_value"))
    except Exception:
        continue
    if gpu_count < min_viable or price <= 0:
        continue
    avail = str(o.get("availability_id") or "").strip()
    if not avail:
        continue
    row = {
        "availability_id": avail,
        "gpu_type": str(o.get("gpu_type") or "").strip(),
        "gpu_count": gpu_count,
        "region": str(o.get("region") or "").strip(),
        "provider": str(o.get("provider") or "").strip(),
        "price_value": price,
    }
    rows.append(row)

rows.sort(
    key=lambda x: (
        x["price_value"],
        -x["gpu_count"],
        region_rank.get(x["region"], 10**6),
        x["provider"],
    )
)

seen = set()
deduped = []
for r in rows:
    k = (r["availability_id"], r["gpu_type"], r["gpu_count"], r["region"], r["provider"])
    if k in seen:
        continue
    seen.add(k)
    deduped.append(r)

with open(out_path, "w", encoding="utf-8") as f:
    for r in deduped:
        f.write(
            f"{r['availability_id']}\t{r['gpu_type']}\t{r['gpu_count']}\t"
            f"{r['region']}\t{r['provider']}\t{r['price_value']}\n"
        )
PY

if [[ ! -s "${CANDIDATES_TSV}" ]]; then
  echo "[matrix] No viable offers found for tier=${TIER} regions=${REGIONS}"
  python3 - "${OUT_JSON}" "${OUT_CSV}" "${TIER}" "${BUDGET_USD}" "${REGIONS}" <<'PY'
import csv
import json
import sys
from datetime import datetime, timezone

out_json, out_csv, tier, budget, regions = sys.argv[1:]
rows = []
with open(out_csv, "r", encoding="utf-8", newline="") as f:
    for row in csv.DictReader(f):
        rows.append(row)
payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "tier": tier,
    "budget_usd": float(budget),
    "regions": regions.split(","),
    "rows": rows,
    "summary": {
        "attempted": 0,
        "passed": 0,
        "estimated_spend_usd": 0.0,
    },
}
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY
  echo "[matrix] json=${OUT_JSON}"
  echo "[matrix] csv=${OUT_CSV}"
  exit 0
fi

spent_usd="0"
attempted=0
passed=0
run_idx=0

while IFS=$'\t' read -r availability_id gpu_type gpu_count region provider price_value; do
  if [[ -z "${availability_id}" ]]; then
    continue
  fi
  if [[ "${attempted}" -ge "${MAX_RUNS}" ]]; then
    break
  fi
  remaining_usd="$(
    python3 - "${BUDGET_USD}" "${spent_usd}" <<'PY'
import sys
b = float(sys.argv[1]); s = float(sys.argv[2])
print(max(0.0, b - s))
PY
  )"
  can_run="$(
    python3 - "${remaining_usd}" <<'PY'
import sys
print(1 if float(sys.argv[1]) > 0.25 else 0)
PY
  )"
  if [[ "${can_run}" != "1" ]]; then
    break
  fi

  run_idx=$((run_idx + 1))
  attempted=$((attempted + 1))
  run_tag="matrix_${TIER//./p}_${run_idx}_$(date +%H%M%S)"
  budget_slice="$(
    python3 - "${SLICE_BUDGET_USD}" "${remaining_usd}" <<'PY'
import sys
a = float(sys.argv[1]); b = float(sys.argv[2])
print(min(a, b))
PY
  )"

  echo "[matrix] run=${run_idx} tier=${TIER} gpu=${gpu_type}x${gpu_count} region=${region} rate=${price_value} budget_slice=${budget_slice}"

  rc=0
  status="OK"
  summary_json=""
  tpoc_p90=""
  cue_fidelity=""
  pass="0"
  cost_estimate="${budget_slice}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    status="DRY_RUN"
    rc=0
    cost_estimate="0"
  else
    set +e
    run_cmd=(
      bash "${SCRIPT_DIR}/run_scripted_30s_prime.sh"
      --mode lifecycle
      --tier "${TIER}"
      --budget-usd "${budget_slice}"
      --restore-mode "${RESTORE_MODE}"
      --schedule-csv "${SCHEDULE_CSV}"
      --run-tag "${run_tag}"
      --availability-id "${availability_id}"
      --selected-gpu-type "${gpu_type}"
      --selected-gpu-count "${gpu_count}"
      --selected-region "${region}"
      --hourly-rate-usd "${price_value}"
    )
    if [[ -n "${RUNTIME_TAG}" ]]; then
      run_cmd+=(--runtime-tag "${RUNTIME_TAG}")
    fi
    "${run_cmd[@]}"
    rc=$?
    set -e

    if [[ "${rc}" -ne 0 ]]; then
      status="FAILED"
    fi

    summary_json="$(find "${SCRIPT_DIR}/.tmp/remote_${run_tag}" -type f -name "*${run_tag}*_summary.json" | head -n1 || true)"

    if [[ -n "${summary_json}" && -f "${summary_json}" ]]; then
      read -r tpoc_p90 cue_fidelity cost_estimate <<<"$(
        python3 - "${summary_json}" "${price_value}" <<'PY'
import json
import sys
from datetime import datetime

path = sys.argv[1]
hourly = float(sys.argv[2])
with open(path, "r", encoding="utf-8") as f:
    d = json.load(f)
metrics = d.get("metrics") or {}
tpoc = metrics.get("steady_tpoc_p90_s")
fidelity = metrics.get("cue_fidelity_ratio")
start_ts = d.get("start_ts")
end_ts = d.get("end_ts")
cost = None
if isinstance(start_ts, str) and isinstance(end_ts, str):
    try:
        s = datetime.fromisoformat(start_ts.replace("Z", "+00:00"))
        e = datetime.fromisoformat(end_ts.replace("Z", "+00:00"))
        runtime_s = max(0.0, (e - s).total_seconds())
        cost = hourly * (runtime_s / 3600.0)
    except Exception:
        cost = None
if cost is None:
    cfg = d.get("config") or {}
    max_runtime = cfg.get("max_runtime_sec")
    if isinstance(max_runtime, int):
        cost = hourly * (max_runtime / 3600.0)
if cost is None:
    cost = 0.0
print(tpoc if tpoc is not None else "", fidelity if fidelity is not None else "", cost)
PY
      )"
    fi

    pass="$(
      python3 - "${tpoc_p90:-nan}" "${cue_fidelity:-nan}" "${rc}" <<'PY'
import math
import sys
try:
    tpoc = float(sys.argv[1])
except Exception:
    tpoc = float("nan")
try:
    fidelity = float(sys.argv[2])
except Exception:
    fidelity = float("nan")
rc = int(sys.argv[3])
ok = (rc == 0) and (not math.isnan(tpoc)) and (tpoc <= 1.0) and (not math.isnan(fidelity)) and (fidelity >= 0.95)
print(1 if ok else 0)
PY
    )"
  fi

  if [[ "${pass}" == "1" ]]; then
    passed=$((passed + 1))
  fi

  spent_usd="$(
    python3 - "${spent_usd}" "${cost_estimate}" <<'PY'
import sys
a = float(sys.argv[1]); b = float(sys.argv[2] or 0.0)
print(a + max(0.0, b))
PY
  )"

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "${run_idx}" "${run_tag}" "${availability_id}" "${gpu_type}" "${gpu_count}" "${region}" "${provider}" \
    "${price_value}" "${budget_slice}" "${cost_estimate}" "${tpoc_p90}" "${cue_fidelity}" "${pass}" "${rc}" "${status}" "${summary_json}" \
    >> "${OUT_CSV}"
done < "${CANDIDATES_TSV}"

python3 - "${OUT_JSON}" "${OUT_CSV}" "${TIER}" "${BUDGET_USD}" "${REGIONS}" "${attempted}" "${passed}" "${spent_usd}" <<'PY'
import csv
import json
import sys
from datetime import datetime, timezone

out_json, out_csv, tier, budget, regions, attempted, passed, spent = sys.argv[1:]
rows = []
with open(out_csv, "r", encoding="utf-8", newline="") as f:
    for row in csv.DictReader(f):
        rows.append(row)

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "tier": tier,
    "budget_usd": float(budget),
    "regions": [r for r in regions.split(",") if r],
    "rows": rows,
    "summary": {
        "attempted": int(attempted),
        "passed": int(passed),
        "estimated_spend_usd": float(spent),
    },
}
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY

echo "[matrix] json=${OUT_JSON}"
echo "[matrix] csv=${OUT_CSV}"
