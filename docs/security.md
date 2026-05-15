# Security / Secrets

## Do not commit

- `config/prime.env`
- `config/vast.env`
- `config/instances/*`
- `ssh_*.json` and personal SSH material
- `*.log`
- model checkpoints and generated outputs (`*.mp4`, `*.png`, `*.jpg`)
- pod hostnames/IP/ports captured from specific runs

## Required handling

- Store provider keys in CLI or env-only config:
  - `~/.prime/config.json`
  - `prime config set-api-key`
  - `vastai set api-key <KEY>`
- Keep private keys at `~/.ssh/*` with restricted permissions (`chmod 600`).
- If a secret was ever committed, rotate immediately and scrub history if the repo is shared.

## Optional local token

If you run `hf` commands interactively, prefer shell env and avoid writing token files in the repo:

- `export HUGGING_FACE_HUB_TOKEN=...`
