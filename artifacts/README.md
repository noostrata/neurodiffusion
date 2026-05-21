# Local Artifact Archive

This directory is for local run outputs copied back from paid or local video runs.

Contents are intentionally ignored by git. Keep only this README tracked.

Suggested layout:

- `runs/longlive2/<run_id>/` — LongLive2 Vast smoke, restore, benchmark, and report directories.
- `runs/scope-longlive/<run_id>/` — Scope + LongLive Vast smoke, sweep, matrix, and report directories.
- `media/scope-longlive/<group>/` — loose MP4/PNG outputs that were created before a run directory existed.
- `manifests/` — local-only move/copy manifests for provenance.

Keep generated videos, sampled frames, JSON reports, logs, and telemetry here instead of `~/Downloads` when they are project artifacts.
Use `~/Downloads` only for a final user-facing copy when explicitly needed.

Runtime scripts default to this root through `NEURODIFFUSION_ARTIFACTS_ROOT`.
Set that variable only when you intentionally want a different local artifact archive.
