# Budget Analysis (Vast + Cloudflare R2)

_Last validated: 2026-05-21T00:10:00Z_

This is the canonical budget reference for this repository.
Use it for storage planning, run-time caps, and quick spend estimates before MAGI runs.

## Scope and assumptions

1. Region focus is Northern Europe (`eu_north`) for normal runs.
2. If no suitable EU cluster listing exists (for example `H100_80GB x8`), fallback region samples are shown explicitly.
3. Month model uses `30 days` (`720 hours`).
4. Cloudflare R2 storage math uses Standard class published pricing:
   - `$0.015 / GB-month`
   - free tier: first `10 GB-month` (Standard class)
5. Prime managed disk math below is legacy comparison context; current paid MAGI runs target Vast.
6. R2 Class A/B operation charges are not included in the storage-only table below.

## Live pricing snapshot commands

Re-run these before production provisioning:

```bash
prime availability list --gpu-type RTX4090_24GB --gpu-count 1 --regions eu_north -o json
prime availability list --gpu-type H100_80GB --gpu-count 1 --regions eu_north -o json
prime availability list --gpu-type H100_80GB --gpu-count 8 --regions united_states -o json
prime availability disks --regions eu_north -o json
```

Cloudflare R2 pricing source:

- https://developers.cloudflare.com/r2/pricing/

Prime managed disk command/source:

- `prime availability disks --regions <region> -o json`

Vast commands:

- `vastai show invoices --raw`
- `vastai search offers '<query>' --raw -o dph_total`
- `vastai show instances --raw`

## Snapshot values used in this analysis

### Prime GPU hourly listings (sampled 2026-02-16)

| Region | GPU listing | Provider | Hourly rate (USD) |
| --- | --- | --- | ---: |
| `eu_north` | `RTX4090_24GB x1` | `runpod` | `0.6068` |
| `eu_north` | `H100_80GB x1` (spot) | `datacrunch` | `0.8015` |
| `eu_north` | `H100_80GB x1` (non-spot) | `datacrunch` | `2.29` |
| `united_states` | `H100_80GB x8` | `lambdalabs` | `23.92` |

### Krea realtime reference listings (sampled 2026-02-17)

These were used for Krea realtime steering planning:

| Market scope | GPU listing | Observed lowest listing (USD/h) |
| --- | --- | ---: |
| global sample | `B200_180GB x1` | `4.89` |
| global sample | `H200_141GB x1` | `2.668` |
| global sample | `H100_80GB x1` | `2.29` |
| global sample | `GH200_96GB x1` | `1.99` |
| united_states sample | `L40S_48GB x1` | `0.82` |
| united_states sample | `RTX6000Ada_48GB x1` | `0.75` |
| united_states sample | `A6000_48GB x1` | `0.54` |

Notes:

1. Prime availability/pricing is volatile; re-query before every lifecycle run.
2. For quality-first Krea, budget `B200_180GB` rates.
3. For practical realtime steering value, `H100_80GB x1` is the default recommended starting point.

### Vast MAGI debug snapshot (sampled 2026-05-14)

| Provider | GPU listing | Observed hourly rate (USD/h) | Outcome |
| --- | --- | ---: | --- |
| Vast.ai | `H200 x1` | `1.9709677419354836` | FAIL for current `sm80` MAGI tuple (`no kernel image` during VAE decode) |
| Vast.ai | `A100-SXM4-40GB` from `A100 x8` listing | `5.867592592592593` | Runtime architecture matched; restore reached DiT load, then failed on missing Python headers before smoke completion |

Notes:

1. The current published MAGI tuple `hopper_sm80_py310_torch240_cu124_20260217_prebuild1` should be routed to A100-class hosts only.
2. H100/H200 may be appropriate after publishing a true `sm90` tuple.
3. The incompatible H200 run was destroyed; `vastai show instances --raw` returned `[]`.

### Vast A100 vs Hopper snapshot (sampled 2026-05-15)

Dry-run search only; no instances were created.

Relaxed query:

```bash
vastai search offers \
  'verified=True reliability>0.95 rentable=True num_gpus>=1 gpu_ram>=80 disk_space>100 inet_down>100' \
  --raw -o dph_total
```

| Filter | Lowest matching observed listing | Observed hourly rate (USD/h) | Notes |
| --- | --- | ---: | --- |
| `A100`, `gpu_ram>=40` | `A100 SXM4 x1`, `40 GB` | `0.908` | cheapest observed A100-class smoke option |
| `A100`, `gpu_ram>=80` | `A100 SXM4 x1`, `80 GB` | `1.581` | closer comparison for large-memory MAGI profiles |
| `H100/H200/GH200`, `gpu_ram>=80` | `H200 x1`, `143 GB` | `3.872` | only observed Hopper-class match in this sample |

Price implication for building a true `sm90` runtime tuple:

1. Versus cheap `A100 40GB`, the sampled H200 was about `4.3x` more expensive per hour.
2. Versus `A100 80GB`, the sampled H200 was about `2.4x` more expensive per hour.
3. A one-hour Hopper tuple build/debug pass should be budgeted around `$4` at this snapshot; two hours around `$8`, before storage/R2 operation noise.

### Vast Scope/LongLive realtime scan (sampled 2026-05-15)

Dry-run search only; no instances were created.

Scope/LongLive can start on cheaper 24GB-class GPUs because Scope documents LongLive as a 24GB-minimum pipeline.

Command shape:

```bash
python3 scripts/vast/query_video_offers.py \
  --model scope \
  --query 'verified=True datacenter=True reliability>0.99 rentable=True num_gpus>=1 gpu_ram>=24 disk_space>200 disk_bw>1000 inet_up>500 inet_down>500 direct_port_count>=2' \
  --out-json VideoDiffusion/.tmp/vast_video_offer_scan_scope.json \
  --out-csv VideoDiffusion/.tmp/vast_video_offer_scan_scope.csv
```

| GPU class | Lowest matching observed listing (USD/h) | Notes |
| --- | ---: | --- |
| `RTX 4090 24GB x1` | `0.736` | cheapest observed single-GPU Scope/LongLive target |
| `RTX 5090 32GB x1` | `0.936` | useful if Krea fallback is later desired |
| `L40S ~45GB x1` | `1.205` | more memory headroom, still much cheaper than Hopper |
| `H200 NVL ~140GB x1` | `3.737` | Hopper validation tier, not first Scope target |

Practical implication:

1. Scope/LongLive should be the first realtime EEG validation target.
2. Krea B200-class testing should wait until the Scope control path is proven.
3. MAGI remains an async/high-quality background renderer, not the primary realtime EEG loop.

### Vast Scope/LongLive B200 validation run (2026-05-15)

Paid run; instance destroyed after local pullback.

| Field | Value |
| --- | ---: |
| GPU | `B200 x1` |
| Observed total rate | `$3.9947916666666656/h` |
| Alive window | about `56.8 min` |
| Approx compute spend | about `$3.78` |
| Realtime result | `24.868 fps` over a 90s WebRTC receive run |
| First frame latency | `1.507s` in 90s run, `0.579s` in recorded 30s run |
| Local output | media pruned after QA; telemetry retained in `docs/video-scope-longlive-observations.md` |

Cost interpretation:

1. B200 proved the Scope/LongLive realtime control path under synthetic EEG.
2. The next cost optimization is to retest the same R2 tuple on `RTX 5090`, `L40S`, or H100/H200-class offers.
3. `RTX 4090` should be treated as explicit protocol/quality-check hardware for this profile, not the default realtime cost target.
4. If a cheaper non-4090 tier holds `>=24 fps` at `320x576`, it should replace B200 as the default art-loop GPU.

### Vast Scope/LongLive RTX 4090 smoke (2026-05-20)

Paid run; instance destroyed after local pullback.

| Field | Value |
| --- | ---: |
| GPU | `RTX 4090 x1` |
| Observed total rate after launch | `$0.8685185185185185/h` |
| Realtime result | `11.310 fps` over a 30s WebRTC receive run |
| First frame latency | `2.480s` |
| Local output | media pruned after QA; telemetry retained in `docs/video-scope-longlive-observations.md` |

Cost/performance interpretation:

1. 4090 is much cheaper than B200, but it failed the `>=24 fps` realtime gate at `320x576`.
2. It is still useful for protocol, artifact-pullback, and visual-quality checks.
3. The next cost target is `RTX 5090`, `L40S`, or another higher-throughput single-GPU tier when available.

### Vast Scope/LongLive matrix guard (2026-05-20)

Use the same-instance sweep runner when a GPU tier is already chosen and the goal is resolution edge-finding:

```bash
bash VideoDiffusion/run_scope_longlive_vast_sweep.sh \
  --create-instance \
  --gpu-regex 'H100|H200|GH200' \
  --max-dph 8.00 \
  --max-gpu-count 1 \
  --duration-s 30 \
  --resolutions 320x576,336x592,352x576,368x640
```

Use the matrix runner when the goal is cross-GPU offer selection:

```bash
bash VideoDiffusion/run_scope_longlive_vast_matrix.sh \
  --create-instance \
  --max-budget-usd 20.14 \
  --max-attempts 10 \
  --duration-s 30
```

Budget controls:

1. `--max-budget-usd` is the run-level ceiling.
2. `--budget-estimate-s` defaults to `1800`, so an offer must fit a conservative 30-minute planned charge before launch.
3. `--per-attempt-fixed-cost-usd` defaults to `1.00`, adding a transfer/storage overhead estimate to planned and observed matrix cost.
4. `--max-attempt-wall-clock-s` defaults to `2400`; a timed-out smoke receives `SIGTERM`, then the matrix tries to terminate its parsed owned instance id.
5. Every paid attempt still uses the smoke runner teardown path unless `--keep-instance` is explicitly passed.
6. Final matrix reports estimate spend from observed wall-clock time times the selected offer hourly rate plus the configured fixed overhead.
7. `--min-credit-reserve-usd` can keep a Vast credit reserve before paid creates; use `--require-credit-check` if the run must stop when credit cannot be queried.
8. The default matrix no longer includes `RTX 4090`; use `--tiers rtx4090_lowres` only for explicit protocol/quality checks.
9. Paid matrix reports also write a sanitized `invoice_report.json` that keeps only matching invoice rows for created instance ids when Vast exposes them.
10. `--max-gpu-count` defaults to `1` for Scope/LongLive selectors; use `0` only when intentionally allowing multi-GPU listings.

### Vast Scope/LongLive H200/4090 matrix spend (2026-05-20)

Actual invoice-observed spend for `scope_longlive_vast_matrix_20260520T200307Z` was about `$4.10`.
Vast credit moved from `$15.519453` to `$11.424968`.

### Vast LongLive2 BF16 SP bring-up (2026-05-21)

Paid H100/H200 x2 run ladder; every created instance was destroyed and `vastai show instances --raw` returned `[]` after teardown.

| Run | Outcome | Observed phase spend | Elapsed | Local artifacts |
| --- | --- | ---: | ---: | --- |
| `longlive2_sp_vast_smoke_20260520T225420Z` | failed before render: no `hf` / `huggingface-cli` binary | about `$0.918` | `427s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T225420Z/` |
| `longlive2_sp_vast_smoke_20260520T230713Z` | failed before render: `transformers==5.9.0` missing `x_clip_loss` import | about `$0.667` | `310s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T230713Z/` |
| `longlive2_sp_vast_smoke_20260520T231513Z` | failed before render: missing `decord` | about `$0.693` | `322s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T231513Z/` |
| `longlive2_sp_vast_smoke_20260520T232208Z` | failed before render: missing Wan2.2 base asset/link | about `$0.895` | `416s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T232208Z/` |
| `longlive2_sp_vast_smoke_20260520T233039Z` | succeeded: cold render + R2 publish + local pullback | about `$3.170` | `1474s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T233039Z/` |
| `longlive2_sp_vast_smoke_20260520T235723Z` | restore fetched tuple, then failed before render on missing restored Wan symlink | about `$1.682` | `782s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260520T235723Z/` |
| `longlive2_sp_vast_smoke_20260521T111231Z` | failed before restore: direct SSH refused repo rsync after remote deps | about `$0.109` | `67s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260521T111231Z/` |
| `longlive2_sp_vast_smoke_20260521T111719Z` | succeeded: R2 restore + Wan link + render + local pullback | about `$1.713` | `1050s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260521T111719Z/` |
| `longlive2_sp_vast_smoke_20260521T114258Z` | succeeded mechanically: benchmark showed `sp2` slower than `sp1` | about `$1.437` | `881s` | `/Users/xenochain/Code/neurodiffusion/artifacts/runs/longlive2/longlive2_sp_vast_smoke_20260521T114258Z/` |

Successful cold-render details:

1. GPU: `H200 x2`, selected offer `28957790`, listed at about `$7.743/h`.
2. Output: `832x480`, `125` frames, `24 fps`, `5.208s`, nonblank QA.
3. Phase timings: setup clone `29s`, restore/download/build `235s`, render `125s`, R2 publish `972s`, pullback `28s`, teardown `3s`.
4. Published R2 tuple: `longlive2_bf16_sp_py310_torch2.8.0_cu128_sm90_prebuild1`.
5. R2 objects: env archive `3,977,262,169` bytes; weights archive `44,203,243,520` bytes; flash-attn wheel `256,043,372` bytes.

Restore validation details:

1. The first fresh restore fetched/extracted the tuple in `559s`, so R2 restore already removes the dependency build and HF download steps.
2. The render then failed because tuple restore had not recreated the upstream `LongLive2/wan_models/Wan2.2-TI2V-5B` symlink.
3. The restore script now recreates that symlink.
4. The first retry after top-up did not test restore; it failed earlier at repo rsync after the host had passed SSH auth and remote dependency install.
5. The paid wrapper now retries idempotent repo upload, R2 secret upload, and artifact pullback transfer phases before cutting a run.
6. The successful restore validation restored in `502s`, rendered in the wrapper's `132s` run phase, pulled artifacts in `36s`, and tore down in `5s`.
7. Repo upload took `254s` on the successful restore run because local `.venv` and `artifacts/` were still included; the wrapper now excludes both for lower startup spend.

Benchmark details:

1. Benchmark-only run restored in `473s`, ran benchmark phase in `214s`, pulled artifacts in `73s`, and tore down in `6s`.
2. Repo sync optimization worked: `repo_sync` was `10s`, down from `254s` on the restore run.
3. `sp1`: `84.131520s`, `0.380357 fps`, GPU 0 active and GPU 1 idle.
4. `sp2`: `126.714834s`, `0.252536 fps`, both H100 NVLs active.
5. `speedup_sp2_over_sp1=0.663945`, so the extra GPU increased hourly cost while decreasing measured wall throughput.

Budget implication:

1. The H100 NVL x2 benchmark fit inside the `45 min` cap at about `$1.437`.
2. Current credit after the benchmark was about `$17.385469`; active instances were `[]`.
3. Do not spend more on Hopper BF16 SP live-runner work unless deliberately rerunning for research; the measured speedup fails the live threshold.
4. Blackwell NVFP4 work should not start without explicit budget approval; it has a different tuple family and build path.
5. Local storage is no longer a budget concern for historical media: `artifacts/` is about `5.5M`, with telemetry retained and intentional proof MP4/contact sheets kept.

Blackwell no-spend scan for the next LongLive2 target:

| Scan | Result |
| --- | --- |
| strict one-GPU datacenter `B200/GB200/RTX 5090` | `0` offers |
| relaxed `B200/GB200` | only `B200 x8` at about `$71.80/h`; do not use for this one-GPU test |
| relaxed `RTX 5090 x1` | multiple offers; preflight selected offer `35949631` at `$0.9351851851851851/h` |

Budget implication:

1. The next paid LongLive2 Blackwell test should target `RTX 5090 x1` / SM120 first.
2. Use `--max-estimated-spend-usd 3.00` and a `90 min` cap for the cold build/download/render/publish path; the latest preflight planned `$1.402778`.
3. Use a one-GPU B200/GB200 only if a sane one-GPU offer appears; do not rent B200/GB200 x8 for this experiment.
4. Judge success with wall-clock render FPS from `run_timing.json`, not MP4 playback FPS; the Blackwell wrapper now sets `--min-wall-fps 24` so slow renders fail `run_report.json` acceptance.

Latest no-spend readiness check:

| Field | Value |
| --- | ---: |
| Vast credit | `$17.385469` |
| Active instances | `0` |
| Latest successful benchmark offer | `H100 NVL x2` offer `29153227` |
| Advertised rate | `$5.873611111111112/h` |
| Benchmark spend | about `$1.437403` |
| Benchmark result | `sp2` slower than `sp1`, `0.663945x` |
| Result | stop Hopper BF16 SP as a live path; keep Scope/LongLive as realtime route |

| Instance | GPU | Resolution | Invoice cost | Notes |
| ---: | --- | --- | ---: | --- |
| `37170799` | `H200` | `320x576` | `$1.681` | passed realtime |
| `37171500` | `H200` | `368x640` | `$0.890` | failed FPS |
| `37172066` | `H200` | `480x832` | `$0.624` | failed FPS |
| `37172562` | `RTX 4090` | `256x448` | `$0.907` | failed FPS and first-frame latency |

Cost interpretation:

1. H200 target validation is affordable enough for short sweeps, but cold restore dominates wall-clock time.
2. H200 transfer charges were near-zero in this invoice sample, while the 4090 restore charged about `$0.758` for download.
3. Same-instance multi-resolution sweeps should be cheaper and faster than one fresh instance per resolution because they amortize provision, R2 restore, Scope server startup, and teardown.
4. The H200 results imply about `4.8-4.9 MPix/s`; `24 fps` therefore wants about `<=200k px/frame` before display upscaling.

### Vast Scope/LongLive H200 edge sweep spend (2026-05-20)

Paid run; instance destroyed after local pullback.

Run root:

```text
/Users/xenochain/Code/neurodiffusion/artifacts/runs/scope-longlive/scope_longlive_vast_smoke_20260520T211512Z/
```

| Instance | GPU listing | Advertised rate | Invoice cost | Notes |
| ---: | --- | ---: | ---: | --- |
| `37174594` | `H200 x2` | `$7.74/h` | `$1.788` | same-instance sweep across four resolutions |

Cost interpretation:

1. The same-instance sweep covered four resolutions for less than half the prior four-instance matrix spend.
2. It still selected `H200 x2`, which is unnecessary for a one-stream Scope test; the selector now defaults `--max-gpu-count 1`.
3. Future comparable one-GPU sweeps should be cheaper if a one-GPU H100/H200/GH200 listing is available.
4. Vast credit after teardown was about `$9.63`.

### Vast LongLive2 SP cost controls (2026-05-21)

LongLive2 SP is the experimental one-stream two-GPU Hopper path; LongLive2 Blackwell NVFP4 is the separate one-GPU speed path.
It should be costed differently from Scope because the first useful test may include source builds, extension builds, model downloads, and R2 tuple publish.
Local plumbing is implemented. The paid H100/H200 x2 ladder has now produced one successful cold BF16 SP render, published the tuple to R2, and validated a fresh R2 restore/render on H100 NVL x2. All paid runs tore down cleanly; successful runs pulled local video/log artifacts.

Known anchor:

| Listing | Observed advertised rate | Notes |
| --- | ---: | --- |
| `H200 x2` | `$7.74/h` | selected accidentally during the Scope edge sweep; useful as a conservative two-GPU cost anchor |

Quick cost table for the observed `H200 x2` rate:

| Alive window | Compute estimate |
| ---: | ---: |
| `10 min` | `$1.29` |
| `20 min` | `$2.58` |
| `30 min` | `$3.87` |
| `60 min` | `$7.74` |

LongLive2 first-run budgeting:

1. no-cost dry-runs must produce the exact `torchrun` command and config before launch;
2. `VideoDiffusion/run_longlive2_sp_vast_smoke.sh --preflight` should pass before paid launch;
3. cold BF16 SP build/publish smokes should use explicit modest geometry (`480x832`, `32` frames); use about `45 min` for render-only bring-up or `60 min` when also attempting R2 publish before teardown;
4. the wrapper now writes `selected_offer.json`, `credit_check.json`, `budget_plan.json`, and `phase_report.json` for spend analysis;
5. the default planned spend gate is `45 min` at `<= $8/h`, capped at about `$6.00` before storage/operation noise;
6. the current BF16 SP tuple is already published and restore-validated, and the benchmark-only run showed Hopper BF16 SP should not be promoted to a live path;
7. a published tuple is not a validated restore tuple until a fresh instance restores it and renders again;
8. a failed import/build/restore should still pull logs locally before teardown unless SSH never became reachable;
9. do not keep an instance alive just to preserve a loaded process;
10. promote two-GPU SP only if one-stream speedup justifies the extra hourly rate.

LongLive2 Blackwell RTX 5090 budgeting:

1. command shape: `VideoDiffusion/run_longlive2_sp_vast_smoke.sh --blackwell-tier sm120 --blackwell-cold-build`;
2. selected offers must be `RTX 5090 x1`, not two-GPU listings;
3. default planned cap: `90 min`;
4. default spend ceiling: `$3.00`, which fits the current `$17.385469` credit snapshot;
5. if cold build succeeds and publishes R2, run a separate short restore validation before treating the tuple as reusable.

Two-GPU decision metric:

```text
cost_per_realtime_frame = hourly_rate / measured_fps
speedup = fps_sp2 / fps_sp1
```

Continue the two-card path when `speedup >= 1.3x`.
Prefer it operationally only when `speedup >= 1.6x` and visual quality is acceptable against the one-GPU Scope baseline.

### Prime managed disk rates in `eu_north` (USD / GB-hour)

| Provider sample | Rate |
| --- | ---: |
| `nebius` / `dc_wildebeest` | `0.00010000` |
| `runpod` | `0.00011111` |
| `crusoecloud` | `0.00011546` |
| `datacrunch` | `0.00027778` |

## Storage recurring cost (Prime disk vs R2)

Formulas:

- `prime_disk_monthly = gb * disk_rate_per_gb_hour * 720`
- `r2_monthly = max(gb - 10, 0) * 0.015`

| Storage option | 100 GB/mo | 200 GB/mo | 500 GB/mo | 1 TB/mo |
| --- | ---: | ---: | ---: | ---: |
| Cloudflare R2 Standard (after 10GB free) | `$1.35` | `$2.85` | `$7.35` | `$15.21` |
| Prime disk (`$0.00010000`) | `$7.20` | `$14.40` | `$36.00` | `$73.73` |
| Prime disk (`$0.00011111`) | `$8.00` | `$16.00` | `$40.00` | `$81.92` |
| Prime disk (`$0.00011546`) | `$8.31` | `$16.63` | `$41.57` | `$85.13` |
| Prime disk (`$0.00027778`) | `$20.00` | `$40.00` | `$100.00` | `$204.80` |

Interpretation:

1. For always-on durable storage, R2 is materially cheaper than Prime managed disk in this sample.
2. Keep managed disk only for short-lived hot cache when it clearly saves more GPU runtime than it costs.

## Compute cost quick table

`cost = hourly_rate * (minutes / 60)`

| Profile | 10 min | 20 min | 30 min |
| --- | ---: | ---: | ---: |
| `1x RTX4090 (eu_north)` | `$0.101` | `$0.202` | `$0.303` |
| `1x H100 spot (eu_north)` | `$0.134` | `$0.267` | `$0.401` |
| `1x H100 non-spot (eu_north)` | `$0.382` | `$0.763` | `$1.145` |
| `8x H100 (united_states sample)` | `$3.987` | `$7.973` | `$11.960` |
| `1x Vast H200 sampled 2026-05-14` | `$0.328` | `$0.657` | `$0.985` |
| `Vast A100 x8 listing sampled 2026-05-14` | `$0.978` | `$1.956` | `$2.934` |
| `1x Vast B200 Scope run sampled 2026-05-15` | `$0.666` | `$1.332` | `$1.997` |
| `1x Vast RTX 4090 Scope run sampled 2026-05-20` | `$0.145` | `$0.290` | `$0.434` |

## Recent empirical publish run (MAGI tuple)

Observed on 2026-02-17/18 (UTC):

1. Task: full MAGI runtime publish to R2 (`flash-attn` source build + weight download + tuple publish).
2. Offer used: `A100_80GB x1` spot at `0.4515 USD/h` (`eu_north` sample).
3. Elapsed wall-clock: about `4h 11m` for the successful pass.
4. Estimated spend: about `$1.89` for that pass (`0.4515 * 4.183h`).

Use this as a one-time build/publish planning anchor; recurring event-time runs should be much lower when restoring from tuple/template.

## Recent empirical scripted stream run (4.5B, tuned low-cost)

Observed on 2026-02-18 (UTC), Prime `A100_80GB x1` spot at `0.4515 USD/h`:

1. Profile: `384x384`, `8` steps, scripted schedule (`18` cues).
2. Dynamic prompt updates worked (`18/18` cues applied), but lag was high on one GPU.
3. Summary runtime was about `600s` for the sampled run.
4. Estimated spend for that run: about `$0.075` (`0.4515 * 600 / 3600`).

Practical implication:

- one-GPU tuned runs are cost-efficient for functionality checks,
- not sufficient for near-real-time responsiveness targets.

## Recent empirical one-shot 30s render run (4.5B non-quant)

Observed on 2026-02-18 (UTC), Prime `A100_80GB x1` at `0.4515 USD/h`:

1. Profile: `4.5B_distill`, `FP8=0`, `384x384`, `8` steps, `720` frames.
2. Output validated: `/Users/xenochain/Downloads/magi_try.mp4` (`30.0s`, `720` frames, `24 fps`).
3. Approximate pod alive window for restore + setup + render + pullback was about `18 minutes`.
4. Estimated spend: about `$0.14` (`0.4515 * 18 / 60`).

Practical implication:

- this is a good low-cost "pretty output" fallback profile,
- it is not an interactive near-real-time steering profile.

## `$15` run envelope (scripted MAGI tests)

Raw max runtime:

- `max_hours = budget_usd / hourly_rate`

Watchdog runtime used by `VideoDiffusion/test_scripted_30s.sh`:

- `max_runtime_sec = floor((BUDGET_USD * 0.90 / HOURLY_RATE_USD) * 3600)`

For `BUDGET_USD=15`:

| Profile | Max runtime (hours) | Watchdog cap (sec) |
| --- | ---: | ---: |
| `1x RTX4090 (eu_north)` | `24.72` | `80092` |
| `1x H100 spot (eu_north)` | `18.71` | `60636` |
| `1x H100 non-spot (eu_north)` | `6.55` | `21222` |
| `8x H100 (united_states sample)` | `0.63` | `2031` |

## Monthly example budgets

| Scenario | Assumption | Storage/mo | Compute/mo | Total/mo |
| --- | --- | ---: | ---: | ---: |
| Lite rehearsal | 100GB + `12` runs/mo at `10 min`, `1x RTX4090` | `$1.35` | `$1.21` | `$2.56` |
| Regular performances | 200GB + `20` runs/mo at `20 min`, `1x H100 spot` | `$2.85` | `$5.34` | `$8.19` |
| High-throughput nights | 500GB + `30` runs/mo at `20 min`, `8x H100` | `$7.35` | `$239.20` | `$246.55` |

## Recommendation for this repo

Use this default architecture:

1. Cloudflare R2 as canonical always-on storage.
2. Vast instance lifecycle for current paid MAGI runs.
3. R2 tuple restore as the startup accelerator, but only on GPU families matching the tuple architecture.
4. Prime managed disk only as legacy comparison context.

This is the lowest recurring storage-cost path while keeping fast event-time startup.

## Credit visibility note

Prime CLI (`v0.5.36`) did not expose numeric credits in `whoami` or `teams list` during legacy runs.
For current Vast runs, use `vastai show invoices --raw` and `vastai show instances --raw`.

Legacy Prime dashboard:

- https://app.primeintellect.ai/dashboard/billing

## Refresh cadence

Before each performance window:

1. Re-run Vast offer scan and active-instance checks.
2. Re-check R2 pricing page.
3. Update this file timestamp + tables if any rate changed.
