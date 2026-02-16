# Prime Intellect

_Last validated: 2026-02-16 with `prime` CLI `v0.5.36`._

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
- `python3 scripts/prime/select_magi_offer.py --scan-json <path> --print-env`
- `bash scripts/prime/provision_magi_pod.sh`
- `bash scripts/prime/run_magi_remote.sh`
- `bash scripts/prime/terminate_magi_pod.sh`

Policy source:

- `scripts/prime/magi_gpu_policies.json`

Tier policy defaults:

- `4.5b` candidates: `RTX4090_24GB`, `A6000_48GB`, `A100_80GB`, `H100_80GB`, `H200_141GB`
- `24b` candidates: `H100_80GB`, `H200_141GB`
- regions default: `eu_north,eu_east,eu_west,united_states`
- target: steady-state `p90 TPOC <= 1.0s`
- budget default: `$15`

Deterministic offer selection rule:

1. lower `price_value`
2. higher `gpu_count`
3. preferred region order from policy
4. provider lexical order

One-command lifecycle entrypoint:

```bash
bash VideoDiffusion/run_scripted_30s_prime.sh \
  --mode lifecycle \
  --tier 4.5b \
  --budget-usd 15 \
  --regions eu_north,eu_east,eu_west,united_states
```

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
- `neurodiffusion/runs/`

Local bootstrap for R2:

```bash
source /Users/xenochain/agents/secrets/r2_full_access.env
```

Then follow `docs/cloudflare-r2.md` for upload/download contract.

## Availability snapshot (2026-02-16, dynamic market)

These values are examples only. Re-query before provisioning.

| Region | SKU | GPUs | Price/hour |
| --- | --- | --- | --- |
| `eu_north` | H100 80GB Spot (`datacrunch`) | 1 | `$0.8015` |
| `eu_north` | H100 80GB Spot (`datacrunch`) | 2 | `$1.6030` |
| `eu_north` | H100 80GB Spot (`datacrunch`) | 8 | `$6.4120` |
| `eu_north` | RTX4090 24GB (`runpod`) | 1 | `$0.6068` |
| `eu_north` | RTX4090 24GB (`runpod`) | 2 | `$1.1968` |
| `eu_north` | RTX4090 24GB (`runpod`) | 4 | `$2.3768` |
| `united_states` | H100 80GB (`primecompute`) | 8 | `$14.40` |

Observed query result: `H100_80GB` with `--regions united_states --gpu-count 24` returned zero matches at validation time.

## Budget quick math

Cost formula:

- `cost_usd = hours * hourly_price`
- `hours = budget_usd / hourly_price`

For a `$5` budget (using the snapshot above):

- 1x H100 Spot (`$0.8015/h`) -> about `6.24h` max runtime.
- 2x H100 Spot (`$1.603/h`) -> about `3.12h`.
- 8x H100 Spot (`$6.412/h`) -> about `46.8 minutes`.
- 1x RTX4090 (`$0.6068/h`) -> about `8.24h`.

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
