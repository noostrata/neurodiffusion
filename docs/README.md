# Docs Index

This directory is the canonical operational documentation for the repo.

## Core docs

- `docs/prime-intellect.md` — provisioning, CLI, pod lifecycle, pricing snapshots, and billing visibility limitations.
- `docs/prime/how_keys.md` — API keys, SSH keys, and security workflow.
- `docs/cloudflare-r2.md` — canonical R2 storage contract for caches, weights, and run artifacts.
- `docs/accelerate.md` — canonical startup/build acceleration strategy (Prime template + R2 + flash-attn).
- `docs/image-streaming.md` — SD-Turbo image workflow.
- `docs/video-magi1-streaming.md` — MAGI-1 video workflow, chunk-wise prompt hot-swap, and sizing notes.
- `docs/video-magi1-scaling-testing.md` — testing matrix, first-principles cluster sizing, and cost-bounded scaling for prompt-reactive MAGI runs.
- `docs/video-magi1-observations.md` — master empirical reference for validated MAGI behavior, performance observations, and failure/remedy notes.
- `scripts/prime/magi_gpu_policies.json` + `scripts/prime/*.sh|*.py` — Prime GPU-type policy, discovery, selection, lifecycle execution, and teardown automation.
- `docs/security.md` — secret handling and ignored file patterns.
- `docs/references.md` — upstream docs and source links.
- `AGENTS.md` — operator rules and workflow conventions.

## Legacy

- `docs/legacy/` stores historical VAST.ai notes only.
- New onboarding and runbook updates must stay in `docs/` (not legacy).
