#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "[check] shell syntax"
shell_files=()
while IFS= read -r f; do
  shell_files+=("${f}")
done < <(
  find ImageDiffusion VideoDiffusion scripts \
    \( -path 'VideoDiffusion/MAGI-1' \
      -o -path 'VideoDiffusion/.vendors' \
      -o -path 'VideoDiffusion/.cache' \
      -o -path 'VideoDiffusion/.tmp' \
      -o -path '*/.venv' \
      -o -path '*/__pycache__' \) -prune \
    -o -type f -name '*.sh' -print | sort
)
for f in "${shell_files[@]}"; do
  bash -n "${f}"
done

echo "[check] python compile"
python_files=()
while IFS= read -r f; do
  python_files+=("${f}")
done < <(
  find ImageDiffusion VideoDiffusion scripts \
    \( -path 'VideoDiffusion/MAGI-1' \
      -o -path 'VideoDiffusion/.vendors' \
      -o -path 'VideoDiffusion/.cache' \
      -o -path 'VideoDiffusion/.tmp' \
      -o -path '*/.venv' \
      -o -path '*/__pycache__' \) -prune \
    -o -type f -name '*.py' -print | sort
)
python3 -m py_compile "${python_files[@]}"

echo "[check] provider offer selftests"
python3 scripts/prime/selftest_offer_common.py
python3 scripts/vast/selftest_video_offers.py
python3 scripts/vast/show_credit.py --selftest
python3 scripts/prune_artifacts.py --selftest
python3 VideoDiffusion/longlive2_config.py selftest
python3 VideoDiffusion/longlive2_run_report.py selftest
bash VideoDiffusion/run_longlive2_sp_benchmark.sh \
  --dry-run \
  --run-dir VideoDiffusion/.tmp/check_longlive2_sp_benchmark \
  --height 320 \
  --width 576 \
  --frames 16
python3 VideoDiffusion/scope_run_report.py selftest
python3 VideoDiffusion/run_scope_longlive_vast_matrix.py --selftest

echo "[check] local integration selftests"
python3 VideoDiffusion/eeg_control/selftest.py

echo "[check] json contracts"
python3 -m json.tool scripts/prime/magi_gpu_policies.json >/dev/null
python3 -m json.tool scripts/prime/krea_gpu_policies.json >/dev/null
python3 -m json.tool VideoDiffusion/runtime-manifest.schema.json >/dev/null
python3 -m json.tool VideoDiffusion/runtime-manifest-v2.schema.json >/dev/null
python3 -m json.tool VideoDiffusion/eeg_control/prompt_map.example.json >/dev/null

echo "[check] ok"
