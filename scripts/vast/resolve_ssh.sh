#!/usr/bin/env bash
#
# Resolve SSH connection details for a Vast.ai instance.
#
# Outputs shell assignments safe to eval:
#   VAST_SSH_USER='root'
#   VAST_SSH_HOST='1.2.3.4'
#   VAST_SSH_PORT='12345'

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${VAST_CONFIG_FILE:-${REPO_ROOT}/config/vast.env}"
PRESET_VAST_INSTANCE_ID="${VAST_INSTANCE_ID+x}"
PRESET_VAST_SSH_HOST="${VAST_SSH_HOST+x}"
PRESET_VAST_SSH_USER="${VAST_SSH_USER+x}"
PRESET_VAST_SSH_PORT="${VAST_SSH_PORT+x}"
PRESET_VAST_INSTANCE_ID_VAL="${VAST_INSTANCE_ID:-}"
PRESET_VAST_SSH_HOST_VAL="${VAST_SSH_HOST:-}"
PRESET_VAST_SSH_USER_VAL="${VAST_SSH_USER:-}"
PRESET_VAST_SSH_PORT_VAL="${VAST_SSH_PORT:-}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi
if [[ -n "${PRESET_VAST_INSTANCE_ID}" ]]; then
  VAST_INSTANCE_ID="${PRESET_VAST_INSTANCE_ID_VAL}"
fi
if [[ -n "${PRESET_VAST_SSH_HOST}" ]]; then
  VAST_SSH_HOST="${PRESET_VAST_SSH_HOST_VAL}"
fi
if [[ -n "${PRESET_VAST_SSH_USER}" ]]; then
  VAST_SSH_USER="${PRESET_VAST_SSH_USER_VAL}"
fi
if [[ -n "${PRESET_VAST_SSH_PORT}" ]]; then
  VAST_SSH_PORT="${PRESET_VAST_SSH_PORT_VAL}"
fi

if [[ -n "${VAST_SSH_HOST:-}" ]]; then
  : "${VAST_SSH_USER:=root}"
  : "${VAST_SSH_PORT:=22}"
  printf "VAST_SSH_USER=%q\n" "${VAST_SSH_USER}"
  printf "VAST_SSH_HOST=%q\n" "${VAST_SSH_HOST}"
  printf "VAST_SSH_PORT=%q\n" "${VAST_SSH_PORT}"
  exit 0
fi

: "${VAST_INSTANCE_ID:?Set VAST_INSTANCE_ID in config/vast.env or provide VAST_SSH_HOST manually}"

if ! command -v vastai >/dev/null 2>&1; then
  echo "resolve_ssh.sh: 'vastai' CLI not found in PATH" >&2
  exit 1
fi

INSTANCES_JSON="$(vastai show instances --raw)"
INSTANCES_JSON="${INSTANCES_JSON}" python3 - "${VAST_INSTANCE_ID}" "${VAST_SSH_USER:-root}" <<'PY'
import json
import os
import re
import shlex
import sys

target_id = str(sys.argv[1])
default_user = sys.argv[2] or "root"
payload = json.loads(os.environ["INSTANCES_JSON"])
instances = payload.get("instances") if isinstance(payload, dict) else payload
if not isinstance(instances, list):
    raise SystemExit("Unexpected vastai show instances payload shape.")

inst = None
for row in instances:
    if not isinstance(row, dict):
        continue
    if str(row.get("id") or row.get("instance_id") or row.get("contract_id") or "") == target_id:
        inst = row
        break
if inst is None:
    raise SystemExit(f"Vast instance {target_id!r} not found.")

def first(*keys):
    for key in keys:
        value = inst.get(key)
        if value not in (None, "", "N/A"):
            return value
    return None

user = str(first("ssh_user", "user") or default_user)
host = first("ssh_host", "public_ipaddr", "public_ip", "host")
port = first("ssh_port", "direct_ssh_port", "port")

for key in ("ssh_url", "ssh", "direct_ssh"):
    raw = inst.get(key)
    if isinstance(raw, str) and raw.strip():
        m = re.search(r"(?:(?P<user>[^@\s]+)@)?(?P<host>[A-Za-z0-9_.:-]+)(?:\s+-p\s+|:)(?P<port>\d+)", raw)
        if m:
            user = m.group("user") or user
            host = host or m.group("host")
            port = port or m.group("port")

ports = inst.get("ports")
if (not host or not port) and isinstance(ports, dict):
    for key, value in ports.items():
        if "22" not in str(key):
            continue
        rows = value if isinstance(value, list) else [value]
        for row in rows:
            if isinstance(row, dict):
                host = host or row.get("HostIp") or row.get("host_ip") or row.get("ip")
                port = port or row.get("HostPort") or row.get("host_port") or row.get("port")
                break
        if host and port:
            break

if not host or not port:
    keys = ", ".join(sorted(str(k) for k in inst.keys()))
    raise SystemExit(
        f"Could not resolve SSH host/port for Vast instance {target_id}. "
        f"Set VAST_SSH_HOST/VAST_SSH_PORT manually. Instance keys: {keys}"
    )

print(f"VAST_SSH_USER={shlex.quote(str(user))}")
print(f"VAST_SSH_HOST={shlex.quote(str(host))}")
print(f"VAST_SSH_PORT={shlex.quote(str(port))}")
PY
