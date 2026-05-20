# Vast.ai

_Last updated: 2026-05-20_

Vast.ai is the current active GPU provider path for this repository.
Prime Intellect files remain in the repo for historical compatibility, but new provider work should target Vast.

## One-time local setup

1. Install and authenticate the Vast CLI:

   ```bash
   pipx install vastai
   vastai set api-key <KEY>
   vastai show user --raw
   ```

2. Create a dedicated no-passphrase RSA automation key before instance creation:

   ```bash
   ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/vast_neurodiffusion_rsa -C 'vast-neurodiffusion-rsa'
   vastai create ssh-key "$(tr -d '\n' < ~/.ssh/vast_neurodiffusion_rsa.pub)"
   ```

3. Create local ignored config:

   ```bash
   cp config/vast.env.example config/vast.env
   chmod 600 config/vast.env
   ```

4. Source Cloudflare R2 credentials only when needed:

   ```bash
   source /Users/xenochain/agents/secrets/r2_full_access.env
   ```

## Offer discovery

Default video offer scan:

```bash
python3 scripts/vast/query_video_offers.py \
  --model magi \
  --out-json VideoDiffusion/.tmp/vast_video_offer_scan_magi.json \
  --out-csv VideoDiffusion/.tmp/vast_video_offer_scan_magi.csv
```

Krea realtime-oriented scan:

```bash
python3 scripts/vast/query_video_offers.py \
  --model krea \
  --out-json VideoDiffusion/.tmp/vast_video_offer_scan_krea.json \
  --out-csv VideoDiffusion/.tmp/vast_video_offer_scan_krea.csv
```

Scope/LongLive realtime-oriented scan:

```bash
python3 scripts/vast/query_video_offers.py \
  --model scope \
  --out-json VideoDiffusion/.tmp/vast_video_offer_scan_scope.json \
  --out-csv VideoDiffusion/.tmp/vast_video_offer_scan_scope.csv
```

Deterministic selection:

```bash
python3 scripts/vast/select_video_offer.py \
  --scan-json VideoDiffusion/.tmp/vast_video_offer_scan_magi.json \
  --selection-goal realtime \
  --runtime-tag hopper_sm80_py310_torch240_cu124_20260217_prebuild1 \
  --print-env
```

When `--runtime-tag` contains an `smXX` architecture hint, the selector filters to the matching GPU family unless `--allow-runtime-gpu-mismatch` is passed.
This is a hard MAGI reliability rule: the currently published `hopper_sm80_py310_torch240_cu124_20260217_prebuild1` tuple is A100-class only.
Do not place that tuple on H100/H200; the 2026-05-14 H200 smoke reached VAE decode and failed with `CUDA error: no kernel image is available for execution on the device`.

The default search requires verified datacenter hosts, high reliability, enough disk, enough network, and direct ports.
Override with `--query '<vast search expression>'` when a run needs a narrower GPU target.
The Scope default query also requires `cuda_max_good>=12.8` because the current Scope tuple is CUDA `12.8`.

For the current `sm80` tuple, the safest query is A100-only:

```bash
python3 scripts/vast/query_video_offers.py \
  --model magi \
  --gpu-name-regex 'A100' \
  --out-json VideoDiffusion/.tmp/vast_video_offer_scan_magi_a100.json \
  --out-csv VideoDiffusion/.tmp/vast_video_offer_scan_magi_a100.csv

python3 scripts/vast/select_video_offer.py \
  --scan-json VideoDiffusion/.tmp/vast_video_offer_scan_magi_a100.json \
  --selection-goal cost \
  --runtime-tag hopper_sm80_py310_torch240_cu124_20260217_prebuild1 \
  --print-env
```

## Instance creation

Create a Docker SSH instance from the selected offer:

```bash
VAST_OFFER_ID=<offer_id> \
VAST_LABEL=neurodiffusion_<run_tag> \
bash scripts/vast/provision_video_instance.sh
```

Defaults come from `config/vast.env`:

- image: `pytorch/pytorch:2.7.1-cuda12.8-cudnn9-devel`
- disk: `200 GB`
- direct SSH enabled
- port mapping hint: `-p 8000:8000`
- onstart command: `touch ~/.no_auto_tmux; env >> /etc/environment`

Wait for `actual_status=running`, then resolve SSH:

```bash
eval "$(bash scripts/vast/resolve_ssh.sh)"
ssh -i "$VAST_SSH_KEY_PATH" -p "$VAST_SSH_PORT" "$VAST_SSH_USER@$VAST_SSH_HOST"
```

If proxy and direct SSH both return `Connection refused` after a short stabilization window, cut the host.
If SSH reaches the host but returns `Permission denied (publickey)`, treat it as an auth-path issue first.
If Vast reports image load complete but leaves the contract stopped, `scripts/vast/provision_video_instance.sh` now sends one `vastai start instance <id>` request during provisioning.
If a selected offer disappears with `no_such_ask`, the provisioner now fails before parsing numeric error codes as instance ids; rerun offer query/selection instead of waiting.

## Runtime bootstrap

On the instance, keep runtime behavior model-selectable:

```bash
cd /workspace/neurodiffusion/VideoDiffusion
VIDEO_MODEL=<magi|krea|scope|longlive> ATTN_BACKEND=<auto|sage|flash|sdpa> bash setup_video_runtime.sh
VIDEO_MODEL=<magi|krea|scope|longlive> ATTN_BACKEND=<auto|sage|flash|sdpa> bash run_video_stream.sh
```

For Scope/LongLive, follow setup with:

```bash
bash download_scope_models.sh
bash load_scope_longlive.sh
```

The EEG controller should use `--sink scope` to send OSC updates to the Scope HTTP/OSC port.

For Hugging Face fetch failures on Vast hosts, try:

```bash
export HF_ENDPOINT=https://hf-mirror.com
```

## MAGI fast smoke path

For the current R2 MAGI tuple, prefer the wrapper below after provisioning an architecture-compatible instance:

```bash
VAST_INSTANCE_ID=<instance_id> \
MAGI_VAST_DESTROY_ON_EXIT=1 \
bash VideoDiffusion/run_magi_vast_smoke.sh
```

The wrapper:

1. resolves SSH through `scripts/vast/resolve_ssh.sh`,
2. waits for SSH auth readiness after Vast reports `running`,
3. rejects runtime-tag/GPU mismatches before spending time on restore,
4. syncs the repo without `.git`, `.venv`, `MAGI-1`, `.tmp`, or generated media,
5. installs minimal smoke deps when missing (`build-essential`, Python headers/venv/pip, `ffmpeg`),
6. copies R2 credentials to the pod only for restore and removes them on exit,
7. restores the tuple and repairs non-relocatable venv shebangs,
8. runs `test_single_chunk.sh` detached with polling,
9. pulls logs and the MP4 to `~/Downloads/...`,
10. destroys the instance when `MAGI_VAST_DESTROY_ON_EXIT=1`.

Default smoke profile:

- non-quant `4.5B_distill`
- `384x384`
- `24` frames
- `8` steps
- `VIDEO_MAGE_T5_DEVICE=cuda`
- `OFFLOAD_T5_CACHE=true`

Use this wrapper for quick bring-up before attempting realtime streaming or EEG-driven prompt schedules.

## Scope/LongLive same-instance sweep path

Use this after selecting a GPU tier when the goal is to find the realtime resolution ceiling without paying repeated cold-start overhead:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scope_longlive_vast_sweep.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --max-dph 8.00 \
  --duration-s 30 \
  --resolutions 320x576,336x592,352x576,368x640
```

The sweep runner provisions once, restores the R2 tuple once, starts Scope once, reloads LongLive per resolution, runs WebRTC plus synthetic EEG per resolution, pulls all artifacts locally, writes `sweep_report.{json,md}`, and tears down by default.

## Scope/LongLive realtime matrix path

Use this when the goal is to keep running across GPU tiers and resolutions:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scope_longlive_vast_matrix.sh \
  --create-instance \
  --max-budget-usd 20.14 \
  --max-attempts 10 \
  --duration-s 30
```

The matrix runner:

1. requires `--create-instance` before creating paid compute;
2. re-scans Vast before each paid attempt;
3. tries cheap-mid GPUs, Hopper-class GPUs, and B200 within budget/time bounds;
4. delegates each paid attempt to the Scope smoke runner, preserving local artifact pullback and teardown;
5. leaves `rtx4090_lowres` available only when explicitly requested with `--tiers rtx4090_lowres`;
6. can preserve a credit reserve with `--min-credit-reserve-usd`;
7. writes `/Users/xenochain/Downloads/<matrix_run_id>/matrix_report.{json,csv,md}` and sanitized `invoice_report.json`;
8. checks final active instance count after paid runs without writing raw host/IP data into tracked docs.

Latest matrix telemetry (`scope_longlive_vast_matrix_20260520T200307Z`):

1. H200 passed `320x576` at `25.376 fps`.
2. H200 failed `368x640` at `20.835 fps`.
3. H200 failed `480x832` at `12.171 fps`.
4. RTX 4090 failed `256x448` at `12.912 fps`.
5. Invoice-observed spend was about `$4.10`.
6. Final active instances were `[]`.
7. H200 throughput was consistently about `4.8-4.9 MPix/s`, making `~200k px/frame` the current practical ceiling for `24 fps`.

## Scope/LongLive realtime smoke path

For one realtime validation attempt, use the Scope wrapper:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scope_longlive_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --max-dph 8.00 \
  --duration-s 30
```

The wrapper:

1. queries and selects a Scope-capable offer;
2. provisions a direct-SSH Vast instance only when `--create-instance` is passed;
3. syncs the current repo state to `/workspace/neurodiffusion`;
4. installs minimal host tools, `uv`, and media utilities when missing;
5. clones/patches Scope with `SCOPE_SKIP_BUILD=1`;
6. restores the R2 Scope tuple into the Scope uv env and `VideoDiffusion/.cache/daydream-scope`;
7. starts Scope with `SCOPE_AUTO_LOAD=0`;
8. loads LongLive with `SCOPE_VACE_ENABLED=false`;
9. records WebRTC output while synthetic EEG drives the Scope OSC sink;
10. pulls MP4, sampled frames, logs, and `run_report.json` to `/Users/xenochain/Downloads/<run_id>/`;
11. writes `phase_report.json`, `artifact_qa.json`, and `contact_sheet.jpg` locally;
12. destroys a wrapper-created instance by default.

Acceptance is encoded in `run_report.json`:

- frames received;
- receive FPS `>=24`;
- first-frame latency `<=2s`;
- at least one synthetic EEG Scope OSC update;
- non-empty local MP4;
- nonblank artifact QA when local media tools are available.

Use `--keep-instance` only for intentional interactive debugging.
If using the B200-published tuple on cheaper GPUs, the wrapper deliberately passes the runtime mismatch path because Scope tuple reuse is env/cache-oriented rather than MAGI custom-kernel-oriented.

## Persistence

Cloudflare R2 remains the canonical persistent store.
Use Vast local disk only for working cache, temporary checkpoints, logs, and generated media.

Before teardown, verify:

- output video/report artifacts exist locally,
- R2 sync or publish manifest exists when persistence was requested,
- primary result files are present,
- teardown proof is captured.

## Teardown

Never leave a paid Vast instance running unless explicitly requested.

```bash
VAST_INSTANCE_ID=<instance_id> bash scripts/vast/terminate_instance.sh
vastai show instances --raw
```

Operationally complete means `vastai show instances --raw` returns `[]` or every intended live instance is explicitly accounted for.

## Migration checklist

1. Read `README.md`, `AGENTS.md`, `docs/security.md`, `docs/cloudflare-r2.md`, and this file.
2. Verify the dedicated Vast RSA automation key exists and is registered.
3. Query current Vast offers and save raw selected offer metadata under `VideoDiffusion/.tmp/`.
4. Create a tagged instance.
5. Update `config/vast.env` with live `VAST_INSTANCE_ID`, selected GPU, location, and hourly rate notes if useful.
6. Bootstrap repo and runtime on the instance.
7. Start stream and prove `/` or `/stats` for MAGI, or the Krea server health path when available.
8. Run a tiny smoke before a long run.
9. Stream or publish outputs to R2.
10. Destroy the instance and record `vastai show instances --raw` proof.
