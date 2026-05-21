# Vast.ai

_Last updated: 2026-05-21_

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

LongLive2 two-GPU SP scan:

```bash
python3 scripts/vast/query_video_offers.py \
  --model longlive2 \
  --out-json VideoDiffusion/.tmp/vast_video_offer_scan_longlive2.json \
  --out-csv VideoDiffusion/.tmp/vast_video_offer_scan_longlive2.csv
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
VIDEO_MODEL=<magi|krea|scope|longlive|longlive2> ATTN_BACKEND=<auto|sage|flash|sdpa> bash setup_video_runtime.sh
VIDEO_MODEL=<magi|krea|scope|longlive|longlive2> ATTN_BACKEND=<auto|sage|flash|sdpa> bash run_video_stream.sh
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
9. pulls logs and the MP4 to the configured local artifact directory,
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
  --max-gpu-count 1 \
  --duration-s 30 \
  --resolutions 320x576,336x592,352x576,368x640
```

The sweep runner provisions once, selects one-GPU offers by default, restores the R2 tuple once, starts Scope once, reloads LongLive per resolution, runs WebRTC plus synthetic EEG per resolution, pulls all artifacts locally, writes `sweep_report.{json,md}`, and tears down by default.

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
7. defaults to `--max-gpu-count 1` so one-stream Scope runs do not select multi-GPU listings accidentally;
8. writes `/Users/xenochain/Code/neurodiffusion/artifacts/runs/scope-longlive/<matrix_run_id>/matrix_report.{json,csv,md}` and sanitized `invoice_report.json` by default;
9. checks final active instance count after paid runs without writing raw host/IP data into tracked docs.

Latest matrix telemetry (`scope_longlive_vast_matrix_20260520T200307Z`):

1. H200 passed `320x576` at `25.376 fps`.
2. H200 failed `368x640` at `20.835 fps`.
3. H200 failed `480x832` at `12.171 fps`.
4. RTX 4090 failed `256x448` at `12.912 fps`.
5. Invoice-observed spend was about `$4.10`.
6. Final active instances were `[]`.
7. H200 throughput was consistently about `4.8-4.9 MPix/s`, making `~200k px/frame` the current practical ceiling for `24 fps`.

Latest same-instance sweep (`scope_longlive_vast_smoke_20260520T211512Z`):

1. `320x576` passed at `25.768 fps`.
2. `336x592` passed at `24.757 fps`.
3. `352x576` passed at `24.835 fps`.
4. `368x640` failed at `22.175 fps`.
5. Final active instances were `[]`.
6. Best validated realtime resolution is now `352x576`.
7. This run selected `H200 x2`; future runs should keep `--max-gpu-count 1` unless intentionally allowing multi-GPU offers.

## Scope/LongLive realtime smoke path

For one realtime validation attempt, use the Scope wrapper:

```bash
cd /Users/xenochain/Code/neurodiffusion
bash VideoDiffusion/run_scope_longlive_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --max-dph 8.00 \
  --max-gpu-count 1 \
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
10. pulls MP4, sampled frames, logs, and `run_report.json` to `/Users/xenochain/Code/neurodiffusion/artifacts/runs/scope-longlive/<run_id>/` by default;
11. writes `phase_report.json`, `artifact_qa.json`, and transient QA media locally;
12. destroys a wrapper-created instance by default.

After QA, prune bulky MP4/PNG/JPG media with `python3 scripts/prune_artifacts.py --delete` unless the user explicitly wants to retain a final visual deliverable.

Acceptance is encoded in `run_report.json`:

- frames received;
- receive FPS `>=24`;
- first-frame latency `<=2s`;
- at least one synthetic EEG Scope OSC update;
- non-empty local MP4;
- nonblank artifact QA when local media tools are available.

Use `--keep-instance` only for intentional interactive debugging.
If using the B200-published tuple on cheaper GPUs, the wrapper deliberately passes the runtime mismatch path because Scope tuple reuse is env/cache-oriented rather than MAGI custom-kernel-oriented.

## LongLive2 SP one-stream path

LongLive2 sequence-parallel inference is the experimental path for one stream across two GPUs.
It is not the same as renting a two-GPU host for Scope.

LongLive2 paid bring-up has now produced a cold H200 x2 BF16 SP render and published the BF16 SP tuple to R2.
The tuple is published but not yet validated as a restore fast path.
The LongLive2 paper explicitly says NVFP4 acceleration is Blackwell-only; on A100/H100/H200, the intended compensation path is SP inference.
Therefore the first Hopper paid lane is `bf16_sp`, not `nvfp4_s2`.

First paid target:

1. two GPUs exactly: `--min-gpu-count 2 --max-gpu-count 2`;
2. first lane: BF16 SP on `H100/H200 x2` or another reliable Hopper two-GPU host;
3. launch shape: `torchrun --standalone --nnodes=1 --nproc_per_node=2 inference_sp.py --config_path <generated_config>`;
4. config shape: `sp_size=2`, `dp_size=1`;
5. output: one MP4 written by rank 0, not two independent videos.

Instance lifecycle:

1. query offers with `scripts/vast/query_video_offers.py --model longlive2`;
2. prefer datacenter two-GPU listings with good disk/network and, when visible, better GPU topology;
3. run `VideoDiffusion/run_longlive2_sp_vast_smoke.sh --preflight` before spending;
4. provision only with explicit `--create-instance`;
5. for the next Hopper validation, restore `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1` from R2 with no HF download fallback;
6. use build/download with `--no-restore --download-fallback` only when deliberately creating a new tuple or debugging the fallback path;
7. confirm setup logs show the conservative `transformers` pin plus `x_clip_loss` and `decord` import guards passing;
8. run one short offline SP smoke;
9. pull the MP4, logs, generated config, `ffprobe`, sampled frames/contact sheet, per-GPU telemetry, selected-offer JSON, credit/budget JSON, and phase report;
10. publish a new tuple to R2 only if the smoke proves reusable imports/builds; use `--publish-r2-on-success` when the publish should happen before automatic teardown;
11. validate the published tuple with a fresh restore run before calling it a default fast path;
12. destroy the instance by default and verify `vastai show instances --raw`.

Latest LongLive2 telemetry:

1. Successful cold run: `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T233039Z/`.
2. Output MP4: `832x480`, `125` frames, `24 fps`, `5.208s`, nonblank QA.
3. Published R2 tuple: `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1`.
4. First restore validation: `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T235723Z/`.
5. Restore phase completed in `559s`, then render failed because the restore path did not recreate the upstream Wan symlink.
6. `VideoDiffusion/restore_r2_prebuild_model.sh` now recreates that symlink; rerun restore validation before promoting the tuple.

Acceptance:

1. `torchrun` starts two ranks;
2. logs show SP mode with `sp_size=2`;
3. both GPUs show nontrivial utilization during denoising;
4. the output is one coherent video stream;
5. local artifact pullback succeeds;
6. no paid instance remains running.

See `docs/video-longlive2-sp-streaming.md` for the complete plan.

Wrapper dry-run:

```bash
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh --dry-run
```

No-spend preflight:

```bash
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh --preflight
```

Cold publish wrapper shape, only when creating or replacing the tuple:

```bash
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --min-gpu-count 2 \
  --max-gpu-count 2 \
  --profile bf16_sp \
  --height 480 \
  --width 832 \
  --frames 32 \
  --sp-size 2 \
  --dp-size 1 \
  --seed 0 \
  --max-alive-min 60 \
  --budget-estimate-min 60 \
  --min-credit-usd 8.00 \
  --min-credit-reserve-usd 0.50 \
  --max-estimated-spend-usd 8.00 \
  --no-restore \
  --download-fallback \
  --publish-r2-on-success
```

Next restore-validation wrapper shape, only after enough credit is available:

```bash
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --min-gpu-count 2 \
  --max-gpu-count 2 \
  --profile bf16_sp \
  --height 480 \
  --width 832 \
  --frames 32 \
  --sp-size 2 \
  --dp-size 1 \
  --seed 0 \
  --max-alive-min 20 \
  --budget-estimate-min 20 \
  --min-credit-usd 2.70 \
  --min-credit-reserve-usd 0.20 \
  --max-estimated-spend-usd 3.00
```

Do not add `--download-fallback` to this validation; the point is to prove the R2 tuple plus LongLive2 Wan-link restore hook.

Blackwell NVFP4 shape, only after the BF16 SP path is proven or when explicitly targeting Blackwell:

```bash
bash VideoDiffusion/run_longlive2_sp_vast_smoke.sh \
  --create-instance \
  --gpu-regex 'B200|GB200|RTX.?5090' \
  --runtime-tag longlive2_nvfp4_s2_py312_torch2.10.0_cu128_sm100_prebuild1 \
  --profile nvfp4_s2 \
  --frames 384
```

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
