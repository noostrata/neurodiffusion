# Prime Intellect

_Last validated: 2026-02-18 with `prime` CLI `v0.5.36`._

All provisioning for this repository uses Prime Intellect pods.

## One-time local setup

1. Install Prime CLI:
   - `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - `uv tool install prime`
2. Authenticate and bind SSH key:
   - `prime login`
   - `prime config set-api-key`
   - `prime config set-ssh-key-path <PATH_TO_YOUR_SSH_KEY>`
3. Verify config:
   - `prime config view`

## Team context and identity

If credits are in a team account, align CLI context before any pod commands:

- `prime teams list`
- `prime config set-team-id <TEAM_ID>`
- `prime whoami`
- `prime config view`

`prime whoami` should show `Type: Team` and the expected `Team ID`.

## Credits and billing visibility

Current CLI/API behavior (validated 2026-02-16):

- `prime whoami` exposes identity + token scopes, not numeric credits.
- `prime teams list` exposes team metadata, not balance.
- `prime --help` (`v0.5.36`) lists no billing/wallet command in the account command group.
- No documented `prime` command currently returns wallet balance directly.

Use the Prime billing dashboard for numeric credits:

- `https://app.primeintellect.ai/dashboard/billing`

Operational rule: if balance cannot be queried by CLI, treat budget as a hard time cap from hourly rate math and terminate pods immediately after each smoke pass.

## Pod lifecycle (canonical commands)

Check live availability right before creating a pod:

- `prime availability list --gpu-type H100_80GB --regions eu_north -o json`
- `prime availability list --gpu-type RTX4090_24GB --regions eu_north -o json`

Create:

- `prime pods create --id <AVAILABILITY_ID> --name neurodiffusion --image ubuntu_22_cuda_12 --gpu-count 1 --disk-size 120 --yes`

Inspect:

- `prime pods list`
- `prime pods list -o json`
- `prime pods status <POD_ID>`
- `prime pods status <POD_ID> -o json`

Connect:

- `prime pods ssh <POD_ID>`

Terminate when done (preferred and explicit spend stop):

- `prime pods terminate <POD_ID> --yes`
- `prime pods list -o json` (confirm no unused active pods remain)

Ephemeral IP host-key note:

- Prime pods can reuse IPs with different host keys. For automation on short-lived pods, use:
  - `PRIME_STRICT_HOST_KEY_CHECKING=no`
  - `PRIME_USER_KNOWN_HOSTS_FILE=/dev/null`
  - `PRIME_GLOBAL_KNOWN_HOSTS_FILE=/dev/null`

Terminate all currently running pods (optional, requires `jq`):

```bash
prime pods list -o json | jq -r '.pods[].id' | xargs -r -n1 prime pods terminate --yes
```

Note: this CLI version has `terminate` (no `prime pods stop` command).

## Prime-first MAGI lifecycle scripts

This repo now provides deterministic wrappers for discovery, selection, provisioning, remote run, and teardown:

- `python3 scripts/prime/query_magi_offers.py --tier <4.5b|24b> --regions <csv>`
- `python3 scripts/prime/select_magi_offer.py --scan-json <path> --selection-goal <realtime|cost> --print-env`
- `bash scripts/prime/provision_magi_pod.sh`
- `bash scripts/prime/run_magi_remote.sh` (restore runtime from R2, execute run, pull artifacts, upload run outputs)
- `bash scripts/prime/terminate_magi_pod.sh`

`run_magi_remote.sh` forwards optional runtime/calibration env overrides to in-pod runs:

- `MAGI_VIDEO_SIZE_H`, `MAGI_VIDEO_SIZE_W`, `MAGI_NUM_STEPS`, `MAGI_NUM_FRAMES`, `MAGI_WINDOW_SIZE`, `MAGI_CONFIG_FILE`
- `MAGI_CP_SIZE`, `MAGI_PP_SIZE`
- `CALIB_CHUNKS`, `CALIB_TIMEOUT_S`, `CALIB_RUNG_LIST`
- `SCHEDULE_TIMEOUT_S`, `SERVER_READY_TIMEOUT_S`, `TARGET_TPOC_S`
- `QUEUE_LEN`, `DROP_OLD_ON_PROMPT`, `JPEG_QUALITY`

SSH contract notes (validated on Runpod + Datacrunch):

- Do not assume port `22`; parse `prime pods status <POD_ID> -o json` field `ssh` and use its `-p <port>`.
- `run_magi_remote.sh` now resolves host/user/port first, then builds ssh/scp options from resolved values.
- On remote run failure, artifact sync is attempted before returning non-zero.
- Remote artifact sync now pulls run-tag files only (not full remote `.tmp`) to avoid multi-GB transfer stalls.
- Temp archive creation in `run_magi_remote.sh` now uses portable `mktemp` behavior.

## Model-aware offer scan and remote build (MAGI + Krea)

For cross-model selection/build orchestration use:

- `python3 scripts/prime/query_video_offers.py --model <magi|krea> --tier <tier>`
- `python3 scripts/prime/select_video_offer.py --model <magi|krea> --scan-json <path> --selection-goal <realtime|cost> --print-env`
- `bash scripts/prime/build_video_runtime_remote.sh`

Model policies:

- MAGI: `scripts/prime/magi_gpu_policies.json`
- Krea: `scripts/prime/krea_gpu_policies.json`

Krea default realtime ranking policy currently targets:

1. `B200_180GB x1` with `flash`
2. `H100_80GB x1` with `sage`
3. `GH200_96GB x1` / `H200_141GB x1` with `sage`
4. `L40S_48GB x1` / `RTX6000Ada_48GB x1` with `sage`

Remote build + publish workflow:

```bash
VIDEO_MODEL=krea \
ATTN_BACKEND=auto \
VIDEO_REMOTE_PUBLISH_PREBUILD=1 \
bash scripts/prime/build_video_runtime_remote.sh
```

Policy source:

- `scripts/prime/magi_gpu_policies.json`

Tier policy defaults:

- `4.5b` candidates: `RTX4090_24GB`, `A6000_48GB`, `A100_80GB`, `H100_80GB`, `H200_141GB`
- `24b` candidates: `H100_80GB`, `H200_141GB`
- regions default: `eu_north,eu_east,eu_west,united_states`
- target: steady-state `p90 TPOC <= 1.0s`
- budget default: `$15`

Deterministic offer selection rule:

1. filter by required GPU count:
   - `realtime`: uses policy `realtime_min_nproc` floor
   - `cost`: uses policy `min_viable_nproc` floor
   - `--min-gpu-count <N>` can raise the floor further
2. lower `price_value`
3. higher `gpu_count`
4. preferred region order from policy
5. provider lexical order

One-command lifecycle entrypoint:

```bash
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode lifecycle \
  --tier 4.5b \
  --budget-usd 15 \
  --selection-goal realtime \
  --min-gpu-count 4 \
  --max-provision-retries 4 \
  --restore-mode auto \
  --runtime-tag <runtime_tag> \
  --regions eu_north,eu_east,eu_west,united_states
```

Operational notes:

- `--max-provision-retries` sets max total provision attempts and handles stale availability IDs by re-querying/reselecting and excluding failed IDs.
- lifecycle attempt/provision telemetry is written to `VideoDiffusion/.tmp/magi_lifecycle_telemetry_<run_tag>.jsonl`.

Dry-run (discovery + selection only):

```bash
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode lifecycle \
  --tier 4.5b \
  --regions eu_north \
  --dry-run
```

## Startup acceleration strategy (recommended)

For repeated MAGI tests, use this order:

1. Prime custom image/template with MAGI base dependencies preinstalled.
2. Cloudflare R2 cache/artifact store (`docs/cloudflare-r2.md`).
3. Runtime pull of only small delta assets (new schedules, minor script changes).

Why this matters:

- avoids reinstalling heavy dependency stacks on every fresh pod
- reduces repeated `flash-attn` compile pressure
- keeps runs reproducible across regions/providers

CLI template provisioning example:

```bash
prime pods create \
  --id <AVAILABILITY_ID> \
  --image custom_template \
  --custom-template-id <TEMPLATE_ID> \
  --yes
```

API equivalent uses `image: "custom_template"` plus `customTemplateId`.

R2 storage prefixes to keep stable:

- `neurodiffusion/wheelhouse/`
- `neurodiffusion/env-cache/`
- `neurodiffusion/images/`
- `neurodiffusion/runs/`
- `neurodiffusion/manifests/runtime-tuples/`

Tuple publish/restore helpers in this repo:

- publish: `WEIGHTS_DIR=/root/neurodiffusion/VideoDiffusion/MAGI-1/. bash VideoDiffusion/publish_r2_prebuild.sh --runtime-tag <runtime_tag> --tiers 4.5b,24b --include-weights --allow-missing-image`
- restore: `bash VideoDiffusion/restore_r2_prebuild.sh --mode auto --runtime-tag <runtime_tag> --tier 4.5b --apply-venv-target /root/neurodiffusion/VideoDiffusion/.venv --apply-weights-target /root/neurodiffusion/VideoDiffusion/MAGI-1`

Note:

- MAGI `download_weights.sh` normalizes `MAGI-1/downloads/` with symlinks.
- Use real-file weights source (`MAGI-1/.` or staged equivalent) during tuple publish to avoid symlink-only archives.
- Latest direct validation on this path produced a full 30s clip on `A100 80GB x1` (`384x384`, `8` steps, `720` frames) and then terminated pod.

Local bootstrap for R2:

```bash
source /Users/xenochain/agents/secrets/r2_full_access.env
```

Then follow `docs/cloudflare-r2.md` for upload/download contract.

## Availability snapshot (dynamic market)

These values are volatile. Re-query immediately before provisioning.

Live sample captured from this workstation at `2026-02-16T22:04:22Z` (lowest observed listing for each query):

```bash
prime availability list --gpu-type RTX4090_24GB --gpu-count 1 --regions eu_north -o json
prime availability list --gpu-type H100_80GB --gpu-count 1 --regions eu_north -o json
prime availability list --gpu-type H100_80GB --gpu-count 8 --regions united_states -o json
prime availability disks --regions eu_north -o json
```

| Region | Query | Lowest observed listing |
| --- | --- | --- |
| `eu_north` | `RTX4090_24GB`, `gpu-count=1` | `runpod`, `$0.6068/h` |
| `eu_north` | `H100_80GB`, `gpu-count=1` | `datacrunch` (spot), `$0.8015/h` |
| `eu_north` | `H100_80GB`, `gpu-count=1` | `datacrunch` (non-spot), `$2.29/h` |
| `united_states` | `H100_80GB`, `gpu-count=8` | `lambdalabs`, `$23.92/h` |

## Budget quick math

Canonical budget formulas and monthly comparison tables are in:

- `docs/budget-analysis.md`

Quick formulas:

- `cost_usd = hours * hourly_price`
- `hours = budget_usd / hourly_price`

Use this one-liner to compute runtime from the currently selected offer:

```bash
python3 - <<'PY'
budget_usd = 15.0
hourly_rate_usd = 0.6068  # replace with current selected offer
print((budget_usd / hourly_rate_usd), "hours")
PY
```

Practical policy:

1. Run setup + one chunk smoke on 1 GPU.
2. Measure latency/throughput.
3. Scale GPU count only if target latency is still missed.

## Local repo wiring

Create `config/prime.env` from `config/prime.env.example`, then set:

- `PRIME_POD_ID`
- `PRIME_SSH_KEY_PATH`

Recommended for portability:

- leave `PRIME_SSH_HOST` unset
- leave `PRIME_SSH_PORT` unset
- let `scripts/prime/resolve_ssh.sh` resolve host/port from `prime pods status <POD_ID> -o json`

Then run scripts from:

- `docs/image-streaming.md`
- `docs/video-magi1-streaming.md`

## Region codes

Common Prime `--regions` values:

- `eu_north` (Northern Europe)
- `eu_west`
- `eu_east`
- `united_states`
- `canada`
- `asia_northeast`
- `asia_south`
- `australia`
- `middle_east`
- `south_america`
- `africa`

## Cost discipline checklist

1. Start with one GPU and lowest-cost smoke profile.
2. Keep test clips short (24 or 96 frames).
3. Export outputs immediately and terminate pod.
4. Recreate pod only when another test batch is needed.
