#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_SWEEP_RESOLUTIONS="${SCOPE_VAST_SWEEP_RESOLUTIONS:-320x576,336x592,352x576,368x640}"

has_resolutions_arg=0
for arg in "$@"; do
  if [[ "${arg}" == "--resolutions" ]]; then
    has_resolutions_arg=1
    break
  fi
done

if [[ "${has_resolutions_arg}" == "1" ]]; then
  exec bash "${SCRIPT_DIR}/run_scope_longlive_vast_smoke.sh" "$@"
fi

exec bash "${SCRIPT_DIR}/run_scope_longlive_vast_smoke.sh" \
  --resolutions "${DEFAULT_SWEEP_RESOLUTIONS}" \
  "$@"
