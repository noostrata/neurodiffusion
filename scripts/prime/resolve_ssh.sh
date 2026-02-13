#!/usr/bin/env bash
#
# Resolve SSH connection details for a Prime Intellect pod.
#
# Outputs shell assignments that are safe to eval, e.g.:
#   PRIME_SSH_USER='root'
#   PRIME_SSH_HOST='1.2.3.4'
#   PRIME_SSH_PORT='22'
#
# Resolution order:
# 1) If PRIME_SSH_HOST is set (manual override), use PRIME_SSH_{USER,HOST,PORT}.
# 2) Else if PRIME_POD_ID is set, call `prime pods status <id> -o json` and parse `.ssh`.
#
# Intended usage:
#   eval "$(/path/to/scripts/prime/resolve_ssh.sh)"
#

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${PRIME_CONFIG_FILE:-${REPO_ROOT}/config/prime.env}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

if [[ -n "${PRIME_SSH_HOST:-}" ]]; then
  : "${PRIME_SSH_USER:=root}"
  : "${PRIME_SSH_PORT:=22}"
  printf "PRIME_SSH_USER=%q\n" "${PRIME_SSH_USER}"
  printf "PRIME_SSH_HOST=%q\n" "${PRIME_SSH_HOST}"
  printf "PRIME_SSH_PORT=%q\n" "${PRIME_SSH_PORT}"
  exit 0
fi

: "${PRIME_POD_ID:?Set PRIME_POD_ID in config/prime.env (or PRIME_SSH_HOST for manual override)}"

if ! command -v prime >/dev/null 2>&1; then
  echo "resolve_ssh.sh: 'prime' CLI not found in PATH" 1>&2
  exit 1
fi

prime pods status "${PRIME_POD_ID}" -o json | python3 -c '
import json, os, re, shlex, sys

data = json.load(sys.stdin)
pod_id = (data.get("id") or "").strip()
status = (data.get("status") or "").strip()
ssh_hint = (data.get("ssh") or "").strip()
ip = (data.get("ip") or "").strip()

m = re.search(r"(?P<user>[^@\s]+)@(?P<host>[^\s]+)\s+-p\s+(?P<port>\d+)", ssh_hint)
if m:
    user = m.group("user")
    host = m.group("host")
    port = m.group("port")
else:
    # Pod might not be ACTIVE yet; Prime CLI can return ssh/ip as "N/A".
    if ip and ip != "N/A":
        user = os.environ.get("PRIME_SSH_USER", "root")
        host = ip
        port = os.environ.get("PRIME_SSH_PORT", "22")
    else:
        raise SystemExit(
            f"Pod has no SSH info yet (pod_id={pod_id!r}, status={status!r}, ip={ip!r}, ssh={ssh_hint!r}). "
            "Wait for ACTIVE or set PRIME_SSH_HOST/PRIME_SSH_USER/PRIME_SSH_PORT manually."
        )

print(f"PRIME_SSH_USER={shlex.quote(user)}")
print(f"PRIME_SSH_HOST={shlex.quote(host)}")
print(f"PRIME_SSH_PORT={shlex.quote(port)}")
'
