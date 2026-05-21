#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUNTIME_TAG="${LONGLIVE2_VAST_RUNTIME_TAG:-longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1}"
RUN_ID="${LONGLIVE2_VAST_RUN_ID:-longlive2_sp_vast_smoke_$(date -u +%Y%m%dT%H%M%SZ)}"
REMOTE_ROOT="${LONGLIVE2_VAST_REMOTE_ROOT:-/workspace/neurodiffusion}"
REMOTE_VIDEO_DIR="${REMOTE_ROOT}/VideoDiffusion"
REMOTE_RUN_DIR="${LONGLIVE2_VAST_REMOTE_RUN_DIR:-/workspace/neurodiffusion_runs/${RUN_ID}}"
REMOTE_R2_ENV="${REMOTE_ROOT}/.secrets/r2_full_access.env"
R2_ENV_FILE="${R2_ENV_FILE:-/Users/xenochain/agents/secrets/r2_full_access.env}"
R2_PREFIX="${R2_PREFIX:-neurodiffusion}"
ARTIFACTS_ROOT="${NEURODIFFUSION_ARTIFACTS_ROOT:-${REPO_ROOT}/artifacts}"
LOCAL_OUT_DIR="${LONGLIVE2_VAST_LOCAL_OUT_DIR:-${ARTIFACTS_ROOT}/runs/longlive2/${RUN_ID}}"
PHASE_LOG="${LONGLIVE2_VAST_PHASE_LOG:-${LOCAL_OUT_DIR}/phase_markers.log}"
PHASE_REPORT="${LONGLIVE2_VAST_PHASE_REPORT:-${LOCAL_OUT_DIR}/phase_report.json}"
SELECTED_OFFER_LOCAL_JSON="${LONGLIVE2_VAST_SELECTED_OFFER_JSON:-${LOCAL_OUT_DIR}/selected_offer.json}"
OFFER_SCAN_LOCAL_JSON="${LONGLIVE2_VAST_OFFER_SCAN_JSON:-${LOCAL_OUT_DIR}/offer_scan.json}"
OFFER_SCAN_LOCAL_CSV="${LONGLIVE2_VAST_OFFER_SCAN_CSV:-${LOCAL_OUT_DIR}/offer_scan.csv}"
CREDIT_CHECK_JSON="${LONGLIVE2_VAST_CREDIT_JSON:-${LOCAL_OUT_DIR}/credit_check.json}"
BUDGET_PLAN_JSON="${LONGLIVE2_VAST_BUDGET_PLAN_JSON:-${LOCAL_OUT_DIR}/budget_plan.json}"

CREATE_INSTANCE="${LONGLIVE2_VAST_CREATE_INSTANCE:-0}"
KEEP_INSTANCE="${LONGLIVE2_VAST_KEEP_INSTANCE:-0}"
DESTROY_ON_EXIT="${LONGLIVE2_VAST_DESTROY_ON_EXIT:-}"
OFFER_ID="${VAST_OFFER_ID:-}"
GPU_REGEX="${LONGLIVE2_VAST_GPU_REGEX:-H200|H100|GH200|B200|GB200}"
OFFER_QUERY="${LONGLIVE2_VAST_OFFER_QUERY:-}"
MIN_GPU_COUNT="${LONGLIVE2_VAST_MIN_GPU_COUNT:-2}"
MAX_GPU_COUNT="${LONGLIVE2_VAST_MAX_GPU_COUNT:-2}"
MAX_DPH="${LONGLIVE2_VAST_MAX_DPH:-8.00}"
SELECTION_GOAL="${LONGLIVE2_VAST_SELECTION_GOAL:-cost}"
ALLOW_RUNTIME_GPU_MISMATCH="${LONGLIVE2_VAST_ALLOW_RUNTIME_GPU_MISMATCH:-0}"
VAST_DISK_GB="${VAST_DISK_GB:-300}"
VAST_IMAGE="${VAST_IMAGE:-pytorch/pytorch:2.8.0-cuda12.8-cudnn9-devel}"
VAST_ENV="${VAST_ENV:-}"
VAST_LABEL="${VAST_LABEL:-neurodiffusion_${RUN_ID}}"
PREFLIGHT="${LONGLIVE2_VAST_PREFLIGHT:-0}"
MAX_ALIVE_MIN="${LONGLIVE2_VAST_MAX_ALIVE_MIN:-45}"
BUDGET_ESTIMATE_MIN="${LONGLIVE2_VAST_BUDGET_ESTIMATE_MIN:-45}"
MIN_CREDIT_USD="${LONGLIVE2_VAST_MIN_CREDIT_USD:-7.00}"
MIN_CREDIT_RESERVE_USD="${LONGLIVE2_VAST_MIN_CREDIT_RESERVE_USD:-1.00}"
MAX_ESTIMATED_SPEND_USD="${LONGLIVE2_VAST_MAX_ESTIMATED_SPEND_USD:-6.00}"
REQUIRE_CREDIT_CHECK="${LONGLIVE2_VAST_REQUIRE_CREDIT_CHECK:-1}"

LONGLIVE2_PROFILE="${LONGLIVE2_PROFILE:-bf16_sp}"
LONGLIVE2_CUDA_ARCHS="${LONGLIVE2_CUDA_ARCHS:-}"
LONGLIVE2_HEIGHT="${LONGLIVE2_HEIGHT:-480}"
LONGLIVE2_WIDTH="${LONGLIVE2_WIDTH:-832}"
LONGLIVE2_FRAMES="${LONGLIVE2_FRAMES:-32}"
LONGLIVE2_SP_SIZE="${LONGLIVE2_SP_SIZE:-2}"
LONGLIVE2_DP_SIZE="${LONGLIVE2_DP_SIZE:-1}"
LONGLIVE2_SAMPLING_STEPS="${LONGLIVE2_SAMPLING_STEPS:-}"
LONGLIVE2_MIN_WALL_FPS="${LONGLIVE2_MIN_WALL_FPS:-}"
LONGLIVE2_SEED="${LONGLIVE2_SEED:-0}"
LONGLIVE2_PROMPT="${LONGLIVE2_PROMPT:-A reactive neon tunnel breathes with smooth cinematic motion.}"
LONGLIVE2_SCHEDULE_CSV="${LONGLIVE2_SCHEDULE_CSV:-}"
LONGLIVE2_SHOT_PROMPTS="${LONGLIVE2_SHOT_PROMPTS:-}"
LONGLIVE2_SHOT_DURATIONS="${LONGLIVE2_SHOT_DURATIONS:-}"
RESTORE_TUPLE="${LONGLIVE2_VAST_RESTORE_TUPLE:-1}"
DOWNLOAD_FALLBACK="${LONGLIVE2_VAST_DOWNLOAD_FALLBACK:-0}"
INCLUDE_WAN="${LONGLIVE2_VAST_INCLUDE_WAN:-1}"
RUN_SMOKE="${LONGLIVE2_VAST_RUN_SMOKE:-1}"
RUN_BENCHMARK="${LONGLIVE2_VAST_RUN_BENCHMARK:-0}"
PUBLISH_R2_ON_SUCCESS="${LONGLIVE2_VAST_PUBLISH_R2_ON_SUCCESS:-0}"
PUBLISH_INCLUDE_WEIGHTS="${LONGLIVE2_VAST_PUBLISH_INCLUDE_WEIGHTS:-1}"
PUBLISH_TIERS="${LONGLIVE2_VAST_PUBLISH_TIERS:-longlive2-bf16-sp-hopper}"
PUBLISH_ENV_COMPRESSION="${LONGLIVE2_VAST_PUBLISH_ENV_COMPRESSION:-zstd}"
PUBLISH_WEIGHTS_COMPRESSION="${LONGLIVE2_VAST_PUBLISH_WEIGHTS_COMPRESSION:-none}"
PUBLISH_BUILD_GPU_CLASS="${LONGLIVE2_VAST_PUBLISH_BUILD_GPU_CLASS:-hopper-sm90}"
PUBLISH_VALIDATED_PROFILES="${LONGLIVE2_VAST_PUBLISH_VALIDATED_PROFILES:-longlive2_bf16_sp_offline_smoke}"
DRY_RUN="${LONGLIVE2_VAST_DRY_RUN:-0}"
SSH_READY_TIMEOUT_S="${LONGLIVE2_VAST_SSH_READY_TIMEOUT_S:-240}"
TRANSFER_RETRIES="${LONGLIVE2_VAST_TRANSFER_RETRIES:-6}"
TRANSFER_RETRY_SLEEP_S="${LONGLIVE2_VAST_TRANSFER_RETRY_SLEEP_S:-10}"

SSH_KEY_PATH="${VAST_SSH_KEY_PATH:-${HOME}/.ssh/vast_neurodiffusion_rsa}"

usage() {
  cat <<EOF
Usage:
  bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh [options]

Safe default: requires VAST_INSTANCE_ID. To create a paid Vast instance, pass --create-instance.

Options:
  --create-instance             Query/select/provision a paid Vast instance before running
  --keep-instance               Do not destroy the instance on exit
  --instance-id <id>            Use an existing Vast instance
  --offer-id <id>               Use an explicit Vast offer id when creating
  --gpu-regex <regex>           Offer GPU filter (default: ${GPU_REGEX})
  --offer-query <query>         Override the Vast search query before local GPU filtering
  --min-gpu-count <count>       Minimum GPUs in selected offer (default: ${MIN_GPU_COUNT})
  --max-gpu-count <count>       Maximum GPUs in selected offer; 0 disables limit (default: ${MAX_GPU_COUNT})
  --max-dph <usd>               Max selected hourly rate (default: ${MAX_DPH})
  --preflight                   Run no-spend local checks, dry-runs, offer selection, and budget check
  --max-alive-min <minutes>     Hard local timeout budget for paid remote phases (default: ${MAX_ALIVE_MIN})
  --budget-estimate-min <min>   Planned spend estimate window (default: ${BUDGET_ESTIMATE_MIN})
  --min-credit-usd <usd>        Minimum Vast credit before paid create (default: ${MIN_CREDIT_USD})
  --min-credit-reserve-usd <usd>
                                  Credit reserve after planned spend (default: ${MIN_CREDIT_RESERVE_USD})
  --max-estimated-spend-usd <usd>
                                  Abort when selected offer estimate exceeds this (default: ${MAX_ESTIMATED_SPEND_USD})
  --no-require-credit-check     Warn instead of aborting if credit cannot be checked
  --runtime-tag <tag>           R2 LongLive2 runtime tuple (default: ${RUNTIME_TAG})
  --profile <bf16_sp|nvfp4_s4|nvfp4_s2>
                                  LongLive2 profile (default: ${LONGLIVE2_PROFILE})
  --blackwell-tier <sm120|sm100>
                                  Apply one-GPU NVFP4 defaults for RTX 5090 (sm120) or B200/GB200 (sm100)
  --blackwell-cold-build        Skip R2 restore and publish the NVFP4 tuple after a successful render
  --cuda-archs <archs>          CUDA_ARCHS passed to LongLive2 NVFP4 extension builds
  --height <pixels>             Output height, divisible by 16 (default: ${LONGLIVE2_HEIGHT})
  --width <pixels>              Output width, divisible by 16 (default: ${LONGLIVE2_WIDTH})
  --frames <count>              Output frames, divisible by 8 (default: ${LONGLIVE2_FRAMES})
  --sp-size <count>             Sequence-parallel size (default: ${LONGLIVE2_SP_SIZE})
  --dp-size <count>             Data-parallel group count (default: ${LONGLIVE2_DP_SIZE})
  --sampling-steps <count>      Sampling steps override
  --min-wall-fps <fps>          Minimum wall-clock render FPS for run_report acceptance
  --seed <int>                  Seed written into generated config (default: ${LONGLIVE2_SEED})
  --prompt <text>               Text prompt for smoke generation
  --schedule-csv <path>         Remote/repo EEG schedule CSV for prompt blocks
  --shot-prompt <text>          Multi-shot prompt; may be repeated
  --shot-duration <blocks>      Block count for each --shot-prompt
  --local-out-dir <path>        Local artifact directory (default: ${LOCAL_OUT_DIR})
  --no-restore                  Skip R2 tuple restore and run setup/download path
  --download-fallback           If restore fails, download LongLive2 model artifacts from HF
  --include-wan                 Also download Wan2.2 base assets during fallback (default)
  --no-include-wan              Skip Wan2.2 base assets; only valid for cache-only/debug use
  --run-benchmark               Run same-seed sp1/sp2 benchmark after restore/setup
  --benchmark-only              Skip the single smoke render and run only the sp1/sp2 benchmark
  --publish-r2-on-success       Publish env/cache tuple to R2 after a successful render and before teardown
  --no-publish-weights          Publish env/wheelhouse only when --publish-r2-on-success is set
  --publish-env-compression <mode>
                                  gzip|zstd|none for env archive (default: ${PUBLISH_ENV_COMPRESSION})
  --publish-weights-compression <mode>
                                  gzip|zstd|none for weights archive (default: ${PUBLISH_WEIGHTS_COMPRESSION})
  --allow-runtime-gpu-mismatch  Allow smXX runtime tag to select another GPU family
  --transfer-retries <count>     Retry idempotent SSH transfer phases (default: ${TRANSFER_RETRIES})
  --transfer-retry-sleep-s <sec> Sleep between transfer retries (default: ${TRANSFER_RETRY_SLEEP_S})
  --dry-run                     Print the plan; do not call Vast or SSH
EOF
}

apply_blackwell_tier() {
  local tier="$1"
  case "${tier}" in
    sm120|rtx5090|5090)
      RUNTIME_TAG="longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm120_prebuild1"
      GPU_REGEX="RTX.?5090"
      OFFER_QUERY="verified=True reliability>0.98 rentable=True num_gpus>=1 gpu_ram>=24 disk_space>300 disk_bw>500 inet_up>200 inet_down>200 direct_port_count>=2 cuda_max_good>=12.8"
      MAX_DPH="2.50"
      MIN_CREDIT_USD="4.00"
      MIN_CREDIT_RESERVE_USD="0.50"
      MAX_ESTIMATED_SPEND_USD="3.00"
      PUBLISH_BUILD_GPU_CLASS="blackwell-sm120"
      PUBLISH_VALIDATED_PROFILES="longlive2_nvfp4_s2_sm120_offline_smoke"
      LONGLIVE2_CUDA_ARCHS="120"
      ;;
    sm100|b200|gb200)
      RUNTIME_TAG="longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm100_prebuild1"
      GPU_REGEX="GB200|GB300|B300|B200"
      OFFER_QUERY="verified=True reliability>0.98 rentable=True num_gpus>=1 gpu_ram>=80 disk_space>300 disk_bw>500 inet_up>200 inet_down>200 direct_port_count>=2 cuda_max_good>=12.8"
      MAX_DPH="12.00"
      MIN_CREDIT_USD="14.00"
      MIN_CREDIT_RESERVE_USD="1.00"
      MAX_ESTIMATED_SPEND_USD="12.00"
      PUBLISH_BUILD_GPU_CLASS="blackwell-sm100"
      PUBLISH_VALIDATED_PROFILES="longlive2_nvfp4_s2_sm100_offline_smoke"
      LONGLIVE2_CUDA_ARCHS="100"
      ;;
    *)
      echo "[error] unsupported Blackwell tier '${tier}'; use sm120 or sm100." >&2
      exit 1
      ;;
  esac
  LONGLIVE2_PROFILE="nvfp4_s2"
  LONGLIVE2_SP_SIZE="1"
  LONGLIVE2_DP_SIZE="1"
  LONGLIVE2_SAMPLING_STEPS="${LONGLIVE2_SAMPLING_STEPS:-2}"
  LONGLIVE2_MIN_WALL_FPS="${LONGLIVE2_MIN_WALL_FPS:-24}"
  MIN_GPU_COUNT="1"
  MAX_GPU_COUNT="1"
  SELECTION_GOAL="cost"
  MAX_ALIVE_MIN="90"
  BUDGET_ESTIMATE_MIN="90"
  VAST_DISK_GB="350"
  PUBLISH_TIERS="longlive2-nvfp4-blackwell"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-instance)
      CREATE_INSTANCE="1"
      shift
      ;;
    --keep-instance)
      KEEP_INSTANCE="1"
      shift
      ;;
    --instance-id)
      VAST_INSTANCE_ID="$2"
      shift 2
      ;;
    --offer-id)
      OFFER_ID="$2"
      shift 2
      ;;
    --gpu-regex)
      GPU_REGEX="$2"
      shift 2
      ;;
    --offer-query)
      OFFER_QUERY="$2"
      shift 2
      ;;
    --min-gpu-count)
      MIN_GPU_COUNT="$2"
      shift 2
      ;;
    --max-gpu-count)
      MAX_GPU_COUNT="$2"
      shift 2
      ;;
    --max-dph)
      MAX_DPH="$2"
      shift 2
      ;;
    --preflight)
      PREFLIGHT="1"
      shift
      ;;
    --max-alive-min)
      MAX_ALIVE_MIN="$2"
      shift 2
      ;;
    --budget-estimate-min)
      BUDGET_ESTIMATE_MIN="$2"
      shift 2
      ;;
    --min-credit-usd)
      MIN_CREDIT_USD="$2"
      shift 2
      ;;
    --min-credit-reserve-usd)
      MIN_CREDIT_RESERVE_USD="$2"
      shift 2
      ;;
    --max-estimated-spend-usd)
      MAX_ESTIMATED_SPEND_USD="$2"
      shift 2
      ;;
    --no-require-credit-check)
      REQUIRE_CREDIT_CHECK="0"
      shift
      ;;
    --runtime-tag)
      RUNTIME_TAG="$2"
      shift 2
      ;;
    --profile)
      LONGLIVE2_PROFILE="$2"
      shift 2
      ;;
    --blackwell-tier)
      apply_blackwell_tier "$2"
      shift 2
      ;;
    --blackwell-cold-build)
      RESTORE_TUPLE="0"
      DOWNLOAD_FALLBACK="1"
      PUBLISH_R2_ON_SUCCESS="1"
      shift
      ;;
    --cuda-archs)
      LONGLIVE2_CUDA_ARCHS="$2"
      shift 2
      ;;
    --height)
      LONGLIVE2_HEIGHT="$2"
      shift 2
      ;;
    --width)
      LONGLIVE2_WIDTH="$2"
      shift 2
      ;;
    --frames)
      LONGLIVE2_FRAMES="$2"
      shift 2
      ;;
    --sp-size)
      LONGLIVE2_SP_SIZE="$2"
      shift 2
      ;;
    --dp-size)
      LONGLIVE2_DP_SIZE="$2"
      shift 2
      ;;
    --sampling-steps)
      LONGLIVE2_SAMPLING_STEPS="$2"
      shift 2
      ;;
    --min-wall-fps)
      LONGLIVE2_MIN_WALL_FPS="$2"
      shift 2
      ;;
    --seed)
      LONGLIVE2_SEED="$2"
      shift 2
      ;;
    --prompt)
      LONGLIVE2_PROMPT="$2"
      shift 2
      ;;
    --schedule-csv)
      LONGLIVE2_SCHEDULE_CSV="$2"
      shift 2
      ;;
    --shot-prompt)
      if [[ -n "${LONGLIVE2_SHOT_PROMPTS}" ]]; then
        LONGLIVE2_SHOT_PROMPTS="${LONGLIVE2_SHOT_PROMPTS}"$'\n'"$2"
      else
        LONGLIVE2_SHOT_PROMPTS="$2"
      fi
      shift 2
      ;;
    --shot-duration)
      if [[ -n "${LONGLIVE2_SHOT_DURATIONS}" ]]; then
        LONGLIVE2_SHOT_DURATIONS="${LONGLIVE2_SHOT_DURATIONS},$2"
      else
        LONGLIVE2_SHOT_DURATIONS="$2"
      fi
      shift 2
      ;;
    --local-out-dir)
      LOCAL_OUT_DIR="$2"
      PHASE_LOG="${LONGLIVE2_VAST_PHASE_LOG:-$2/phase_markers.log}"
      PHASE_REPORT="${LONGLIVE2_VAST_PHASE_REPORT:-$2/phase_report.json}"
      SELECTED_OFFER_LOCAL_JSON="${LONGLIVE2_VAST_SELECTED_OFFER_JSON:-$2/selected_offer.json}"
      OFFER_SCAN_LOCAL_JSON="${LONGLIVE2_VAST_OFFER_SCAN_JSON:-$2/offer_scan.json}"
      OFFER_SCAN_LOCAL_CSV="${LONGLIVE2_VAST_OFFER_SCAN_CSV:-$2/offer_scan.csv}"
      CREDIT_CHECK_JSON="${LONGLIVE2_VAST_CREDIT_JSON:-$2/credit_check.json}"
      BUDGET_PLAN_JSON="${LONGLIVE2_VAST_BUDGET_PLAN_JSON:-$2/budget_plan.json}"
      shift 2
      ;;
    --no-restore)
      RESTORE_TUPLE="0"
      shift
      ;;
    --download-fallback)
      DOWNLOAD_FALLBACK="1"
      shift
      ;;
    --include-wan)
      INCLUDE_WAN="1"
      shift
      ;;
    --no-include-wan)
      INCLUDE_WAN="0"
      shift
      ;;
    --run-benchmark)
      RUN_BENCHMARK="1"
      shift
      ;;
    --benchmark-only)
      RUN_SMOKE="0"
      RUN_BENCHMARK="1"
      shift
      ;;
    --publish-r2-on-success)
      PUBLISH_R2_ON_SUCCESS="1"
      shift
      ;;
    --no-publish-weights)
      PUBLISH_INCLUDE_WEIGHTS="0"
      shift
      ;;
    --publish-env-compression)
      PUBLISH_ENV_COMPRESSION="$2"
      shift 2
      ;;
    --publish-weights-compression)
      PUBLISH_WEIGHTS_COMPRESSION="$2"
      shift 2
      ;;
    --allow-runtime-gpu-mismatch)
      ALLOW_RUNTIME_GPU_MISMATCH="1"
      shift
      ;;
    --transfer-retries)
      TRANSFER_RETRIES="$2"
      shift 2
      ;;
    --transfer-retry-sleep-s)
      TRANSFER_RETRY_SLEEP_S="$2"
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
      echo "[error] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${LONGLIVE2_PROFILE}" in
  bf16|bf16_sp)
    LONGLIVE2_PROFILE="bf16_sp"
    ;;
  nvfp4|nvfp4_s4|nvfp4_4step)
    LONGLIVE2_PROFILE="nvfp4_s4"
    ;;
  nvfp4_s2|nvfp4_2step)
    LONGLIVE2_PROFILE="nvfp4_s2"
    ;;
  *)
    echo "[error] unsupported LongLive2 profile '${LONGLIVE2_PROFILE}'." >&2
    exit 1
    ;;
esac

if [[ -z "${LONGLIVE2_MIN_WALL_FPS}" ]]; then
  LONGLIVE2_MIN_WALL_FPS="0"
fi

runtime_arch_from_tag() {
  local tag="$1"
  if [[ "${tag}" =~ (^|[_-])(sm[0-9]+)([_-]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

validate_profile_runtime_tuple() {
  local arch
  arch="$(runtime_arch_from_tag "${RUNTIME_TAG}")"
  if [[ "${LONGLIVE2_PROFILE}" == nvfp4* ]]; then
    if [[ "${RESTORE_TUPLE}" == "1" && "${arch}" != "sm100" && "${arch}" != "sm120" && "${ALLOW_RUNTIME_GPU_MISMATCH}" != "1" ]]; then
      echo "[error] ${LONGLIVE2_PROFILE} is the LongLive2 NVFP4 path. The paper's limitation says NVFP4 acceleration is Blackwell-only, so use an sm100/sm120 runtime tag or pass --allow-runtime-gpu-mismatch only for intentional debugging." >&2
      exit 1
    fi
    if [[ "${GPU_REGEX}" =~ A100|H100|H200|GH200 ]] && [[ ! "${GPU_REGEX}" =~ B200|GB200|5090|RTX.?50|RTX.?60 ]] && [[ "${ALLOW_RUNTIME_GPU_MISMATCH}" != "1" ]]; then
      echo "[error] ${LONGLIVE2_PROFILE} with GPU regex '${GPU_REGEX}' targets non-Blackwell GPUs. Use bf16_sp for Hopper/Ampere SP, or choose B200/GB200/RTX50-class offers." >&2
      exit 1
    fi
  fi
  if [[ "${LONGLIVE2_PROFILE}" == "bf16_sp" && "${arch}" == "sm100" ]]; then
    echo "[longlive2-vast] note: bf16_sp on Blackwell is valid for proof/debug, but it is not the paper's max-FPS NVFP4 lane." >&2
  fi
}

validate_retry_settings() {
  python3 - "${TRANSFER_RETRIES}" "${TRANSFER_RETRY_SLEEP_S}" <<'PY'
import sys

retries = int(sys.argv[1])
sleep_s = float(sys.argv[2])
if retries < 1:
    raise SystemExit("transfer retries must be >= 1")
if sleep_s < 0:
    raise SystemExit("transfer retry sleep must be >= 0")
PY
}

validate_run_mode() {
  if [[ "${RUN_SMOKE}" != "1" && "${RUN_BENCHMARK}" != "1" ]]; then
    echo "[error] no LongLive2 work selected; enable smoke or benchmark mode." >&2
    exit 1
  fi
}

validate_profile_runtime_tuple
validate_retry_settings
validate_run_mode

q() {
  printf "%q" "$1"
}

RUN_DEADLINE_EPOCH_S=""
SSH_READY="0"
ARTIFACTS_PULLED="0"

mark_phase() {
  local phase="$1"
  local line
  line="$(printf '[longlive2-vast-ts] %s %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${phase}")"
  printf '%s\n' "${line}"
  mkdir -p "$(dirname -- "${PHASE_LOG}")"
  printf '%s\n' "${line}" >>"${PHASE_LOG}"
}

write_phase_report() {
  local exit_code="$1"
  python3 "${SCRIPT_DIR}/longlive2_run_report.py" phase-report \
    --phase-log "${PHASE_LOG}" \
    --out "${PHASE_REPORT}" \
    --run-id "${RUN_ID}" \
    --exit-code "${exit_code}" \
    --local-out-dir "${LOCAL_OUT_DIR}" \
    --selected-offer-json "${SELECTED_OFFER_LOCAL_JSON}" \
    --credit-json "${CREDIT_CHECK_JSON}" \
    --max-alive-min "${MAX_ALIVE_MIN}" \
    --budget-estimate-min "${BUDGET_ESTIMATE_MIN}" >/dev/null 2>&1 || true
}

start_alive_timer() {
  if python3 - "${MAX_ALIVE_MIN}" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
  then
    RUN_DEADLINE_EPOCH_S="$(
      python3 - "${MAX_ALIVE_MIN}" <<'PY'
import sys
import time
print(int(time.time() + float(sys.argv[1]) * 60))
PY
    )"
  fi
}

remaining_alive_timeout_s() {
  if [[ -z "${RUN_DEADLINE_EPOCH_S}" ]]; then
    echo "0"
    return
  fi
  python3 - "${RUN_DEADLINE_EPOCH_S}" <<'PY'
import sys
import time
remaining = int(float(sys.argv[1]) - time.time())
print(max(1, remaining))
PY
}

check_alive_budget() {
  if [[ -z "${RUN_DEADLINE_EPOCH_S}" ]]; then
    return
  fi
  local remaining
  remaining="$(remaining_alive_timeout_s)"
  if [[ "${remaining}" -le 1 ]]; then
    echo "[error] LongLive2 paid max-alive budget expired (${MAX_ALIVE_MIN} min)." >&2
    exit 124
  fi
}

remote_ssh() {
  ssh -i "${SSH_KEY_PATH}" \
    -p "${VAST_SSH_PORT}" \
    -o BatchMode=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=6 \
    -o StrictHostKeyChecking=accept-new \
    "${VAST_SSH_USER}@${VAST_SSH_HOST}" "$@"
}

remote_ssh_guarded() {
  check_alive_budget
  local timeout_s
  timeout_s="$(remaining_alive_timeout_s)"
  python3 - "${timeout_s}" "${SSH_KEY_PATH}" "${VAST_SSH_PORT}" "${VAST_SSH_USER}@${VAST_SSH_HOST}" "$1" <<'PY'
import subprocess
import sys

timeout_s = float(sys.argv[1])
key_path, port, host, remote_cmd = sys.argv[2:]
cmd = [
    "ssh",
    "-i",
    key_path,
    "-p",
    port,
    "-o",
    "BatchMode=yes",
    "-o",
    "ServerAliveInterval=30",
    "-o",
    "ServerAliveCountMax=6",
    "-o",
    "StrictHostKeyChecking=accept-new",
    host,
    remote_cmd,
]
try:
    proc = subprocess.run(cmd, timeout=timeout_s if timeout_s > 0 else None)
except subprocess.TimeoutExpired:
    print(f"[error] remote SSH phase timed out after {timeout_s:.0f}s", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(proc.returncode)
PY
}

remote_scp_dir_from() {
  mkdir -p "$2"
  scp -i "${SSH_KEY_PATH}" \
    -P "${VAST_SSH_PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -r "${VAST_SSH_USER}@${VAST_SSH_HOST}:$1/." "$2/"
}

remote_scp_dir_from_guarded() {
  check_alive_budget
  remote_scp_dir_from "$@"
}

wait_for_ssh_ping() {
  local timeout_s="${1:-60}"
  local deadline=$((SECONDS + timeout_s))
  local last_rc=0
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if remote_ssh "true" >/dev/null 2>&1; then
      SSH_READY="1"
      return 0
    fi
    last_rc=$?
    sleep 3
  done
  return "${last_rc}"
}

retry_idempotent_ssh_step() {
  local desc="$1"
  shift
  local attempt=1
  local rc=0
  while [[ "${attempt}" -le "${TRANSFER_RETRIES}" ]]; do
    check_alive_budget
    set +e
    "$@"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      return 0
    fi
    if [[ "${attempt}" -ge "${TRANSFER_RETRIES}" ]]; then
      echo "[error] ${desc} failed after ${attempt}/${TRANSFER_RETRIES} attempts (rc=${rc})" >&2
      return "${rc}"
    fi
    echo "[warn] ${desc} failed on attempt ${attempt}/${TRANSFER_RETRIES} (rc=${rc}); retrying after SSH stabilization" >&2
    sleep "${TRANSFER_RETRY_SLEEP_S}"
    wait_for_ssh_ping 60 >/dev/null 2>&1 || true
    attempt=$((attempt + 1))
  done
  return "${rc}"
}

cleanup_remote_secret() {
  if [[ -n "${VAST_SSH_HOST:-}" ]]; then
    remote_ssh "rm -f $(q "${REMOTE_R2_ENV}"); rmdir $(q "${REMOTE_ROOT}/.secrets") 2>/dev/null || true" >/dev/null 2>&1 || true
  fi
}

destroy_instance_if_needed() {
  local should_destroy="${DESTROY_ON_EXIT:-0}"
  if [[ "${KEEP_INSTANCE}" == "1" ]]; then
    should_destroy="0"
  elif [[ -z "${DESTROY_ON_EXIT}" && "${INSTANCE_CREATED:-0}" == "1" ]]; then
    should_destroy="1"
  fi
  if [[ "${should_destroy}" == "1" && -n "${VAST_INSTANCE_ID:-}" ]]; then
    mark_phase "teardown_start" || true
    VAST_INSTANCE_ID="${VAST_INSTANCE_ID}" bash "${REPO_ROOT}/scripts/vast/terminate_instance.sh" || true
    mark_phase "teardown_done" || true
  fi
}

finish() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ "${SSH_READY}" == "1" && "${ARTIFACTS_PULLED}" != "1" ]]; then
    mark_phase "artifact_pull_on_exit_start" || true
    pull_artifacts || true
    mark_phase "artifact_pull_on_exit_done" || true
  fi
  cleanup_remote_secret
  destroy_instance_if_needed
  write_phase_report "${rc}"
  exit "${rc}"
}
trap finish EXIT INT TERM

wait_for_ssh_auth() {
  local deadline=$((SECONDS + SSH_READY_TIMEOUT_S))
  local last_rc=0
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if remote_ssh "true" >/dev/null 2>&1; then
      SSH_READY="1"
      return 0
    fi
    last_rc=$?
    echo "[longlive2-vast] waiting for SSH auth (last_rc=${last_rc})" >&2
    sleep 5
  done
  echo "[error] SSH auth did not become ready within ${SSH_READY_TIMEOUT_S}s." >&2
  return "${last_rc}"
}

write_explicit_offer_metadata() {
  mkdir -p "${LOCAL_OUT_DIR}"
  python3 - "${SELECTED_OFFER_LOCAL_JSON}" "${OFFER_ID}" "${RUNTIME_TAG}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out, offer_id, runtime_tag = sys.argv[1:]
payload = {
    "provider": "vastai",
    "source": "explicit_offer_id",
    "runtime_tag": runtime_tag,
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "selected_offer": {"offer_id": offer_id},
}
Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

selected_offer_estimated_spend() {
  python3 - "${SELECTED_OFFER_LOCAL_JSON}" "${BUDGET_ESTIMATE_MIN}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
minutes = float(sys.argv[2])
if not path.is_file():
    raise SystemExit(1)
payload = json.loads(path.read_text(encoding="utf-8"))
offer = payload.get("selected_offer") if isinstance(payload, dict) else {}
try:
    dph = float(offer.get("dph_total"))
except Exception:
    raise SystemExit(1)
print(round(dph * minutes / 60.0, 6))
PY
}

write_budget_plan() {
  local estimated_spend="${1:-}"
  mkdir -p "${LOCAL_OUT_DIR}"
  python3 - "${BUDGET_PLAN_JSON}" "${RUN_ID}" "${MAX_ALIVE_MIN}" "${BUDGET_ESTIMATE_MIN}" "${MIN_CREDIT_USD}" "${MIN_CREDIT_RESERVE_USD}" "${MAX_ESTIMATED_SPEND_USD}" "${estimated_spend}" "${SELECTED_OFFER_LOCAL_JSON}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    out,
    run_id,
    max_alive_min,
    budget_estimate_min,
    min_credit_usd,
    reserve_usd,
    max_estimated_spend_usd,
    estimated_spend,
    selected_offer_json,
) = sys.argv[1:]
offer_payload = {}
path = Path(selected_offer_json)
if path.is_file():
    offer_payload = json.loads(path.read_text(encoding="utf-8"))
payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "run_id": run_id,
    "max_alive_min": float(max_alive_min),
    "budget_estimate_min": float(budget_estimate_min),
    "min_credit_usd": float(min_credit_usd),
    "min_credit_reserve_usd": float(reserve_usd),
    "max_estimated_spend_usd": float(max_estimated_spend_usd) if max_estimated_spend_usd else None,
    "estimated_spend_usd": float(estimated_spend) if estimated_spend else None,
    "selected_offer": offer_payload.get("selected_offer", {}),
}
Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

check_selected_offer_budget() {
  local estimated_spend
  estimated_spend="$(selected_offer_estimated_spend 2>/dev/null || true)"
  write_budget_plan "${estimated_spend}"
  if [[ -n "${estimated_spend}" && -n "${MAX_ESTIMATED_SPEND_USD}" ]]; then
    python3 - "${estimated_spend}" "${MAX_ESTIMATED_SPEND_USD}" <<'PY'
import sys
estimated = float(sys.argv[1])
maximum = float(sys.argv[2])
if estimated > maximum:
    print(
        f"[error] selected offer estimated spend ${estimated:.4f} exceeds max ${maximum:.4f}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
  fi
  set +e
  python3 "${REPO_ROOT}/scripts/vast/show_credit.py" \
    --out-json "${CREDIT_CHECK_JSON}" \
    --min-credit-usd "${MIN_CREDIT_USD}" \
    --reserve-usd "${MIN_CREDIT_RESERVE_USD}" \
    --estimated-spend-usd "${estimated_spend:-0}"
  local rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    if [[ "${REQUIRE_CREDIT_CHECK}" == "1" ]]; then
      echo "[error] Vast credit check failed or budget is insufficient; see ${CREDIT_CHECK_JSON}" >&2
      exit "${rc}"
    fi
    echo "[warn] Vast credit check failed or budget is insufficient, continuing because --no-require-credit-check was set." >&2
  fi
}

select_offer_if_needed() {
  if [[ -n "${OFFER_ID}" ]]; then
    write_explicit_offer_metadata
    return
  fi
  mkdir -p "${SCRIPT_DIR}/.tmp"
  mkdir -p "${LOCAL_OUT_DIR}"
  local scan_json="${SCRIPT_DIR}/.tmp/${RUN_ID}_longlive2_offer_scan.json"
  local scan_csv="${SCRIPT_DIR}/.tmp/${RUN_ID}_longlive2_offer_scan.csv"
  local selected_json="${SCRIPT_DIR}/.tmp/${RUN_ID}_longlive2_offer_selected.json"
  echo "[longlive2-vast] querying offers gpu_regex=${GPU_REGEX} max_dph=${MAX_DPH}"
  query_args=(
    --model longlive2
    --gpu-name-regex "${GPU_REGEX}"
    --out-json "${scan_json}"
    --out-csv "${scan_csv}"
  )
  if [[ -n "${OFFER_QUERY}" ]]; then
    query_args+=(--query "${OFFER_QUERY}")
  fi
  python3 "${REPO_ROOT}/scripts/vast/query_video_offers.py" "${query_args[@]}"
  select_args=(
    --scan-json "${scan_json}"
    --selection-goal "${SELECTION_GOAL}"
    --min-gpu-count "${MIN_GPU_COUNT}"
    --runtime-tag "${RUNTIME_TAG}"
    --out-json "${selected_json}"
  )
  if [[ -n "${MAX_DPH}" ]]; then
    select_args+=(--max-dph "${MAX_DPH}")
  fi
  if [[ -n "${MAX_GPU_COUNT}" ]]; then
    select_args+=(--max-gpu-count "${MAX_GPU_COUNT}")
  fi
  if [[ "${ALLOW_RUNTIME_GPU_MISMATCH}" == "1" ]]; then
    select_args+=(--allow-runtime-gpu-mismatch)
  fi
  python3 "${REPO_ROOT}/scripts/vast/select_video_offer.py" "${select_args[@]}"
  python3 - "${scan_json}" "${OFFER_SCAN_LOCAL_JSON}" "${selected_json}" "${SELECTED_OFFER_LOCAL_JSON}" <<'PY'
import json
import sys
from pathlib import Path

def scrub(value):
    if isinstance(value, dict):
        return {k: scrub(v) for k, v in value.items() if k != "raw"}
    if isinstance(value, list):
        return [scrub(item) for item in value]
    return value

for src, dst in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    payload = json.loads(Path(src).read_text(encoding="utf-8"))
    Path(dst).write_text(json.dumps(scrub(payload), indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  cp "${scan_csv}" "${OFFER_SCAN_LOCAL_CSV}"
  OFFER_ID="$(python3 - "${selected_json}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["selected_offer"]["offer_id"])
PY
)"
  echo "[longlive2-vast] selected offer=${OFFER_ID}"
}

create_instance_if_requested() {
  INSTANCE_CREATED="0"
  if [[ "${CREATE_INSTANCE}" != "1" ]]; then
    : "${VAST_INSTANCE_ID:?Set VAST_INSTANCE_ID or pass --create-instance.}"
    return
  fi
  select_offer_if_needed
  check_selected_offer_budget
  mkdir -p "${SCRIPT_DIR}/.tmp"
  local provision_log="${SCRIPT_DIR}/.tmp/${RUN_ID}_provision.log"
  echo "[longlive2-vast] creating paid Vast instance offer=${OFFER_ID} label=${VAST_LABEL}"
  set +e
  VAST_OFFER_ID="${OFFER_ID}" \
  VAST_LABEL="${VAST_LABEL}" \
  VAST_DISK_GB="${VAST_DISK_GB}" \
  VAST_IMAGE="${VAST_IMAGE}" \
  VAST_ENV="${VAST_ENV}" \
    bash "${REPO_ROOT}/scripts/vast/provision_video_instance.sh" >"${provision_log}" 2>&1
  local rc=$?
  set -e
  sed -n '1,120p' "${provision_log}"
  if [[ "${rc}" -ne 0 ]]; then
    echo "[error] provision failed; log=${provision_log}" >&2
    exit "${rc}"
  fi
  VAST_INSTANCE_ID="$(awk -F= '/^VAST_INSTANCE_ID=/{print $2}' "${provision_log}" | tail -n1)"
  if [[ -z "${VAST_INSTANCE_ID}" ]]; then
    echo "[error] could not parse VAST_INSTANCE_ID from ${provision_log}" >&2
    exit 1
  fi
  INSTANCE_CREATED="1"
}

ensure_remote_system_deps() {
  remote_ssh_guarded "set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
need_apt=0
for cmd in git curl ffmpeg python3 rsync zstd; do
  if ! command -v \"\${cmd}\" >/dev/null 2>&1; then need_apt=1; fi
done
if [[ \"\${need_apt}\" == \"1\" ]]; then
  for _ in \$(seq 1 90); do
    if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x dpkg >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends git curl ca-certificates rsync ffmpeg python3-venv python3-pip zstd >/dev/null
fi
echo '[longlive2-vast] remote system deps ready'
"
}

sync_repo_to_remote_once() {
  remote_ssh_guarded "mkdir -p $(q "${REMOTE_ROOT}") $(q "${REMOTE_ROOT}/.secrets") $(q "${REMOTE_RUN_DIR}")"
  rsync -az \
    --timeout=120 \
    --exclude '.git' \
    --exclude '.venv' \
    --exclude 'artifacts' \
    --exclude 'VideoDiffusion/MAGI-1' \
    --exclude 'VideoDiffusion/.venv' \
    --exclude 'VideoDiffusion/.venv-krea' \
    --exclude 'VideoDiffusion/.vendors' \
    --exclude 'VideoDiffusion/.cache' \
    --exclude 'VideoDiffusion/.tmp' \
    --exclude 'VideoDiffusion/*.mp4' \
    --exclude 'ImageDiffusion/.venv' \
    --exclude '__pycache__' \
    -e "ssh -i ${SSH_KEY_PATH} -p ${VAST_SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
    "${REPO_ROOT}/" "${VAST_SSH_USER}@${VAST_SSH_HOST}:${REMOTE_ROOT}/"
}

sync_repo_to_remote() {
  echo "[longlive2-vast] syncing repo to ${REMOTE_ROOT}"
  retry_idempotent_ssh_step "repo rsync upload" sync_repo_to_remote_once
}

copy_r2_secret_once() {
  if [[ ! -f "${R2_ENV_FILE}" ]]; then
    echo "[error] R2 env file not found: ${R2_ENV_FILE}" >&2
    exit 1
  fi
  scp -i "${SSH_KEY_PATH}" \
    -P "${VAST_SSH_PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    "${R2_ENV_FILE}" "${VAST_SSH_USER}@${VAST_SSH_HOST}:${REMOTE_R2_ENV}"
  remote_ssh_guarded "chmod 600 $(q "${REMOTE_R2_ENV}")"
}

copy_r2_secret() {
  retry_idempotent_ssh_step "R2 secret upload" copy_r2_secret_once
}

remote_setup_longlive2_clone_only() {
  setup_args=(--profile "${LONGLIVE2_PROFILE}")
  if [[ -n "${LONGLIVE2_CUDA_ARCHS}" ]]; then
    setup_args+=(--cuda-archs "${LONGLIVE2_CUDA_ARCHS}")
  fi
  setup_args+=(--skip-build)
  remote_ssh_guarded "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/setup_longlive2.sh $(printf '%q ' "${setup_args[@]}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/setup_longlive2_clone.log")"
}

remote_restore_or_download() {
  if [[ "${RESTORE_TUPLE}" == "1" ]]; then
    echo "[longlive2-vast] restoring R2 tuple ${RUNTIME_TAG}"
    set +e
    remote_ssh_guarded "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); R2_ENV_FILE=$(q "${REMOTE_R2_ENV}") R2_PREFIX=$(q "${R2_PREFIX}") bash VideoDiffusion/restore_r2_prebuild_model.sh --model longlive2 --mode tuple --runtime-tag $(q "${RUNTIME_TAG}") --apply-venv-target $(q "${REMOTE_VIDEO_DIR}/.vendors/LongLive2/.venv") --apply-weights-target $(q "${REMOTE_VIDEO_DIR}/.cache/longlive2") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/restore_longlive2_tuple.log")"
    local rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      return
    fi
    if [[ "${DOWNLOAD_FALLBACK}" != "1" ]]; then
      echo "[error] R2 tuple restore failed and download fallback is disabled." >&2
      exit "${rc}"
    fi
    echo "[longlive2-vast] restore failed; falling back to setup and model download"
  fi
  setup_args=(--profile "${LONGLIVE2_PROFILE}")
  if [[ -n "${LONGLIVE2_CUDA_ARCHS}" ]]; then
    setup_args+=(--cuda-archs "${LONGLIVE2_CUDA_ARCHS}")
  fi
  remote_ssh_guarded "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/setup_longlive2.sh $(printf '%q ' "${setup_args[@]}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/setup_longlive2_build.log")"
  download_args=(--profile "${LONGLIVE2_PROFILE}")
  if [[ "${INCLUDE_WAN}" == "1" ]]; then
    download_args+=(--include-wan)
  fi
  remote_ssh_guarded "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/download_longlive2_models.sh $(printf '%q ' "${download_args[@]}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/download_longlive2_models.log")"
}

remote_run_smoke() {
  run_args=(
    --profile "${LONGLIVE2_PROFILE}"
    --run-dir "${REMOTE_RUN_DIR}/offline"
    --height "${LONGLIVE2_HEIGHT}"
    --width "${LONGLIVE2_WIDTH}"
    --frames "${LONGLIVE2_FRAMES}"
    --sp-size "${LONGLIVE2_SP_SIZE}"
    --dp-size "${LONGLIVE2_DP_SIZE}"
    --seed "${LONGLIVE2_SEED}"
    --prompt "${LONGLIVE2_PROMPT}"
    --min-wall-fps "${LONGLIVE2_MIN_WALL_FPS}"
  )
  if [[ -n "${LONGLIVE2_SAMPLING_STEPS}" ]]; then
    run_args+=(--sampling-steps "${LONGLIVE2_SAMPLING_STEPS}")
  fi
  if [[ "${LONGLIVE2_PROFILE}" == nvfp4* ]]; then
    run_args+=(--strict-profile-gpu-match)
  fi
  if [[ "${PUBLISH_R2_ON_SUCCESS}" == "1" ]]; then
    run_args+=(--no-fail-on-report-reject)
  fi
  if [[ -n "${LONGLIVE2_SCHEDULE_CSV}" ]]; then
    run_args+=(--schedule-csv "${LONGLIVE2_SCHEDULE_CSV}")
  fi
  if [[ -n "${LONGLIVE2_SHOT_PROMPTS}" ]]; then
    while IFS= read -r shot_prompt; do
      [[ -z "${shot_prompt}" ]] && continue
      run_args+=(--shot-prompt "${shot_prompt}")
    done <<<"${LONGLIVE2_SHOT_PROMPTS}"
  fi
  if [[ -n "${LONGLIVE2_SHOT_DURATIONS}" ]]; then
    IFS=',' read -r -a shot_duration_values <<<"${LONGLIVE2_SHOT_DURATIONS}"
    for shot_duration in "${shot_duration_values[@]}"; do
      [[ -z "${shot_duration}" ]] && continue
      run_args+=(--shot-duration "${shot_duration}")
    done
  fi
  remote_ssh_guarded "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/run_longlive2_sp_offline.sh $(printf '%q ' "${run_args[@]}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/run_longlive2_sp_offline.wrapper.log")"
}

remote_check_smoke_report() {
  local mode="$1"
  remote_ssh_guarded "python3 - $(q "${mode}") $(q "${REMOTE_RUN_DIR}/offline/run_report.json") <<'PY'
import json
import sys
from pathlib import Path

mode, report_path = sys.argv[1:]
path = Path(report_path)
if not path.is_file():
    print(f'[error] LongLive2 run report missing: {path}', file=sys.stderr)
    raise SystemExit(1)
payload = json.loads(path.read_text(encoding='utf-8'))
acceptance = payload.get('acceptance') or {}
if mode == 'publish_eligible':
    required = (
        'video_exists_ok',
        'torchrun_errors_ok',
        'sp_marker_present',
        'telemetry_present',
        'artifact_nonblank_ok',
    )
    failed = [key for key in required if not acceptance.get(key)]
    if failed:
        print(f'[error] LongLive2 render is not eligible for R2 publish; failed={failed}', file=sys.stderr)
        raise SystemExit(1)
    print('[longlive2-vast] render is eligible for R2 publish')
    raise SystemExit(0)
if mode == 'full_acceptance':
    if not acceptance.get('passed'):
        failed = [key for key, value in acceptance.items() if key.endswith('_ok') and not value]
        print(f'[error] LongLive2 run did not meet full acceptance; failed={failed}', file=sys.stderr)
        raise SystemExit(1)
    print('[longlive2-vast] full LongLive2 acceptance passed')
    raise SystemExit(0)
print(f'[error] unknown report check mode: {mode}', file=sys.stderr)
raise SystemExit(1)
PY
"
}

remote_run_benchmark() {
  bench_args=(
    --run-dir "${REMOTE_RUN_DIR}/sp_benchmark"
    --profile "${LONGLIVE2_PROFILE}"
    --height "${LONGLIVE2_HEIGHT}"
    --width "${LONGLIVE2_WIDTH}"
    --frames "${LONGLIVE2_FRAMES}"
    --dp-size "${LONGLIVE2_DP_SIZE}"
    --seed "${LONGLIVE2_SEED}"
    --prompt "${LONGLIVE2_PROMPT}"
    --src-dir "${REMOTE_VIDEO_DIR}/.vendors/LongLive2"
  )
  if [[ -n "${LONGLIVE2_SAMPLING_STEPS}" ]]; then
    bench_args+=(--sampling-steps "${LONGLIVE2_SAMPLING_STEPS}")
  fi
  remote_ssh_guarded "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); bash VideoDiffusion/run_longlive2_sp_benchmark.sh $(printf '%q ' "${bench_args[@]}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/run_longlive2_sp_benchmark.wrapper.log")"
}

remote_publish_r2_tuple() {
  publish_args=(
    --model longlive2
    --runtime-tag "${RUNTIME_TAG}"
    --tiers "${PUBLISH_TIERS}"
    --build-gpu-class "${PUBLISH_BUILD_GPU_CLASS}"
    --validated-profiles "${PUBLISH_VALIDATED_PROFILES}"
    --env-compression "${PUBLISH_ENV_COMPRESSION}"
    --weights-compression "${PUBLISH_WEIGHTS_COMPRESSION}"
  )
  if [[ "${PUBLISH_INCLUDE_WEIGHTS}" == "1" ]]; then
    publish_args+=(--include-weights)
  fi
  remote_ssh_guarded "set -euo pipefail; cd $(q "${REMOTE_ROOT}"); R2_ENV_FILE=$(q "${REMOTE_R2_ENV}") R2_PREFIX=$(q "${R2_PREFIX}") ALLOW_MISSING_WEIGHTS=0 bash VideoDiffusion/publish_r2_prebuild_model.sh $(printf '%q ' "${publish_args[@]}") 2>&1 | tee $(q "${REMOTE_RUN_DIR}/publish_longlive2_r2_tuple.log")"
}

pull_artifacts() {
  echo "[longlive2-vast] pulling artifacts to ${LOCAL_OUT_DIR}"
  mkdir -p "${LOCAL_OUT_DIR}"
  retry_idempotent_ssh_step "artifact scp pullback" remote_scp_dir_from_guarded "${REMOTE_RUN_DIR}" "${LOCAL_OUT_DIR}"
  ARTIFACTS_PULLED="1"
}

run_preflight() {
  mkdir -p "${LOCAL_OUT_DIR}"
  mark_phase "preflight_start"
  echo "[longlive2-vast] preflight: scripts/check.sh"
  bash "${REPO_ROOT}/scripts/check.sh"
  echo "[longlive2-vast] preflight: git diff --check"
  git -C "${REPO_ROOT}" diff --check
  echo "[longlive2-vast] preflight: active Vast instances"
  local instances_raw
  instances_raw="$(vastai show instances --raw)"
  local active_count
  active_count="$(INSTANCES_JSON="${instances_raw}" python3 - <<'PY'
import json
import os
payload = json.loads(os.environ["INSTANCES_JSON"])
instances = payload.get("instances") if isinstance(payload, dict) else payload
print(len(instances) if isinstance(instances, list) else -1)
PY
)"
  if [[ "${active_count}" != "0" ]]; then
    echo "[error] Vast active instance count is ${active_count}; refusing preflight success." >&2
    exit 1
  fi
  echo "[longlive2-vast] preflight: offline LongLive2 dry run"
  preflight_offline_args=(
    --dry-run \
    --run-dir "${SCRIPT_DIR}/.tmp/${RUN_ID}_preflight_offline" \
    --profile "${LONGLIVE2_PROFILE}" \
    --height "${LONGLIVE2_HEIGHT}" \
    --width "${LONGLIVE2_WIDTH}" \
    --frames "${LONGLIVE2_FRAMES}" \
    --sp-size "${LONGLIVE2_SP_SIZE}" \
    --dp-size "${LONGLIVE2_DP_SIZE}" \
    --seed "${LONGLIVE2_SEED}" \
    --shot-prompt "A calm luminous ocean breathes slowly." \
    --shot-prompt "A frantic neon tunnel accelerates." \
    --min-wall-fps "${LONGLIVE2_MIN_WALL_FPS}"
  )
  if [[ -n "${LONGLIVE2_SAMPLING_STEPS}" ]]; then
    preflight_offline_args+=(--sampling-steps "${LONGLIVE2_SAMPLING_STEPS}")
  fi
  if [[ "${PUBLISH_R2_ON_SUCCESS}" == "1" ]]; then
    preflight_offline_args+=(--no-fail-on-report-reject)
  fi
  bash "${SCRIPT_DIR}/run_longlive2_sp_offline.sh" "${preflight_offline_args[@]}"
  if [[ "${RUN_BENCHMARK}" == "1" ]]; then
    echo "[longlive2-vast] preflight: benchmark dry run"
    bash "${SCRIPT_DIR}/run_longlive2_sp_benchmark.sh" \
      --dry-run \
      --run-dir "${SCRIPT_DIR}/.tmp/${RUN_ID}_preflight_benchmark" \
      --profile "${LONGLIVE2_PROFILE}" \
      --height "${LONGLIVE2_HEIGHT}" \
      --width "${LONGLIVE2_WIDTH}" \
      --frames "${LONGLIVE2_FRAMES}" \
      --dp-size "${LONGLIVE2_DP_SIZE}" \
      --seed "${LONGLIVE2_SEED}" \
      --prompt "${LONGLIVE2_PROMPT}"
  fi
  echo "[longlive2-vast] preflight: NVFP4-on-sm90 guard should fail"
  if bash "${BASH_SOURCE[0]}" \
    --dry-run \
    --profile nvfp4_s2 \
    --runtime-tag longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm90_prebuild1 \
    --gpu-regex 'H100|H200|GH200' >/tmp/longlive2_nvfp4_guard.out 2>/tmp/longlive2_nvfp4_guard.err; then
    echo "[error] NVFP4-on-sm90 guard unexpectedly passed." >&2
    cat /tmp/longlive2_nvfp4_guard.out >&2 || true
    cat /tmp/longlive2_nvfp4_guard.err >&2 || true
    exit 1
  fi
  echo "[longlive2-vast] preflight: offer selection and credit/budget check"
  select_offer_if_needed
  check_selected_offer_budget
  mark_phase "preflight_done"
  write_phase_report 0
  echo "[longlive2-vast] preflight ok local_dir=${LOCAL_OUT_DIR}"
}

if [[ "${PREFLIGHT}" == "1" ]]; then
  run_preflight
  exit 0
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  cat <<EOF
[longlive2-vast] dry-run
run_id=${RUN_ID}
create_instance=${CREATE_INSTANCE}
preflight=${PREFLIGHT}
runtime_tag=${RUNTIME_TAG}
offer_query=${OFFER_QUERY}
gpu_regex=${GPU_REGEX}
min_gpu_count=${MIN_GPU_COUNT}
max_gpu_count=${MAX_GPU_COUNT}
max_dph=${MAX_DPH}
max_alive_min=${MAX_ALIVE_MIN}
budget_estimate_min=${BUDGET_ESTIMATE_MIN}
min_credit_usd=${MIN_CREDIT_USD}
min_credit_reserve_usd=${MIN_CREDIT_RESERVE_USD}
max_estimated_spend_usd=${MAX_ESTIMATED_SPEND_USD}
profile=${LONGLIVE2_PROFILE}
cuda_archs=${LONGLIVE2_CUDA_ARCHS}
min_wall_fps=${LONGLIVE2_MIN_WALL_FPS}
geometry=${LONGLIVE2_HEIGHT}x${LONGLIVE2_WIDTH}
frames=${LONGLIVE2_FRAMES}
sp_size=${LONGLIVE2_SP_SIZE}
dp_size=${LONGLIVE2_DP_SIZE}
seed=${LONGLIVE2_SEED}
run_smoke=${RUN_SMOKE}
run_benchmark=${RUN_BENCHMARK}
schedule_csv=${LONGLIVE2_SCHEDULE_CSV}
local_out_dir=${LOCAL_OUT_DIR}
phase_report=${PHASE_REPORT}
publish_r2_on_success=${PUBLISH_R2_ON_SUCCESS}
publish_tiers=${PUBLISH_TIERS}
publish_include_weights=${PUBLISH_INCLUDE_WEIGHTS}
publish_env_compression=${PUBLISH_ENV_COMPRESSION}
publish_weights_compression=${PUBLISH_WEIGHTS_COMPRESSION}
transfer_retries=${TRANSFER_RETRIES}
transfer_retry_sleep_s=${TRANSFER_RETRY_SLEEP_S}
EOF
  exit 0
fi

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  echo "[error] Vast SSH key not found: ${SSH_KEY_PATH}" >&2
  exit 1
fi

cd "${REPO_ROOT}"
start_alive_timer
mark_phase "create_instance_start"
create_instance_if_requested
mark_phase "create_instance_done"

mark_phase "resolve_ssh_start"
eval "$(VAST_INSTANCE_ID="${VAST_INSTANCE_ID}" bash scripts/vast/resolve_ssh.sh)"
mark_phase "resolve_ssh_done"
mark_phase "ssh_ready_wait_start"
wait_for_ssh_auth
mark_phase "ssh_ready_wait_done"

remote_gpu="$(remote_ssh "nvidia-smi --query-gpu=name --format=csv,noheader | paste -sd ',' -" | tr -d '\r')"
echo "[longlive2-vast] run_id=${RUN_ID}"
echo "[longlive2-vast] instance=${VAST_INSTANCE_ID} gpu=${remote_gpu}"
echo "[longlive2-vast] runtime_tag=${RUNTIME_TAG}"

mark_phase "remote_system_deps_start"
ensure_remote_system_deps
mark_phase "remote_system_deps_done"
mark_phase "repo_sync_start"
sync_repo_to_remote
mark_phase "repo_sync_done"
if [[ "${RESTORE_TUPLE}" == "1" || "${PUBLISH_R2_ON_SUCCESS}" == "1" ]]; then
  mark_phase "copy_r2_secret_start"
  copy_r2_secret
  mark_phase "copy_r2_secret_done"
fi
mark_phase "setup_longlive2_start"
remote_setup_longlive2_clone_only
mark_phase "setup_longlive2_done"
mark_phase "restore_or_download_start"
remote_restore_or_download
mark_phase "restore_or_download_done"
if [[ "${RUN_SMOKE}" == "1" ]]; then
  mark_phase "longlive2_run_start"
  remote_run_smoke
  mark_phase "longlive2_run_done"
fi
if [[ "${RUN_BENCHMARK}" == "1" ]]; then
  mark_phase "longlive2_benchmark_start"
  remote_run_benchmark
  mark_phase "longlive2_benchmark_done"
fi
if [[ "${PUBLISH_R2_ON_SUCCESS}" == "1" ]]; then
  if [[ "${RUN_SMOKE}" == "1" ]]; then
    mark_phase "publish_eligibility_check_start"
    remote_check_smoke_report "publish_eligible"
    mark_phase "publish_eligibility_check_done"
  fi
  mark_phase "publish_r2_start"
  remote_publish_r2_tuple
  mark_phase "publish_r2_done"
fi
if [[ "${RUN_SMOKE}" == "1" && "${PUBLISH_R2_ON_SUCCESS}" == "1" ]]; then
  mark_phase "realtime_acceptance_check_start"
  remote_check_smoke_report "full_acceptance"
  mark_phase "realtime_acceptance_check_done"
fi
mark_phase "artifact_pull_start"
pull_artifacts
mark_phase "artifact_pull_done"

echo "[longlive2-vast] local_dir=${LOCAL_OUT_DIR}"
