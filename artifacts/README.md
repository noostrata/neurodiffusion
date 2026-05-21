# Local Artifact Archive

This directory is for local run outputs copied back from paid or local video runs.

Contents are intentionally ignored by git. Keep only this README tracked.

Suggested layout:

- `runs/longlive2/<run_id>/` — LongLive2 Vast smoke, restore, benchmark, and report directories.
- `runs/scope-longlive/<run_id>/` — Scope + LongLive Vast smoke, sweep, matrix, and report directories.
- `manifests/` — local-only move/copy manifests for provenance.

Keep JSON reports, logs, telemetry, budget records, selected-offer records, QA summaries, and prune manifests here.
Do not keep historical MP4/PNG/JPG media by default after QA; it is bulky and usually less useful than the run reports.
The default exception is tiny LongLive2 proof clips under `runs/longlive2/*/offline/videos/*.mp4`.
Use `~/Downloads` only for a final user-facing copy when explicitly needed.

Runtime scripts default to this root through `NEURODIFFUSION_ARTIFACTS_ROOT`.
Set that variable only when you intentionally want a different local artifact archive.

To prune disposable media while preserving telemetry and a checksum manifest:

```bash
python3 scripts/prune_artifacts.py --delete
```
