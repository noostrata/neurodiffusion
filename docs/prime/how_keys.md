# Prime Intellect: Key and Access Playbook

_Last updated: 2026-02-13_

## Scope

- Prime API key and SSH keys for account CLI usage.
- Safe project-local workflow in `config/prime.env`.
- Optional Hugging Face token handling for model downloads.

## What keys are in scope

- **Prime API key**: used by Prime CLI and API calls.
- **SSH key pair**: local private key + registered public key for pod SSH.
- **Hugging Face token**: optional, for HF download throttling.

## Recommended local layout

- CLI config: `~/.prime/config.json`.
- SSH key: path set in Prime CLI config (`prime config set-ssh-key-path`) and mirrored in
  `config/prime.env` as `PRIME_SSH_KEY_PATH`.
- Pod/runtime config: `config/prime.env` (ignored by git).
- Resolver keys: leave `PRIME_SSH_HOST` / `PRIME_SSH_PORT` unset in repo examples.

## Setup commands

- Install CLI:
  - `curl -LsSf https://astral.sh/uv/install.sh | sh`
  - `uv tool install prime`
- Authenticate + set SSH key path:
  - `prime login`
  - `prime config set-api-key`
  - `prime config set-ssh-key-path <PATH_TO_YOUR_SSH_KEY>`
- Verify context and team usage:
  - `prime teams list`
  - `prime config set-team-id <TEAM_ID>`
  - `prime whoami`
  - `prime config view`

## SSH access

- Primary local method is through pod id + `prime pods status <POD_ID> -o json`.
- `scripts/prime/resolve_ssh.sh` reads:
  - `config/prime.env`
  - `PRIME_POD_ID` fallback or explicit `PRIME_SSH_*` overrides.
- If you get `Permission denied (publickey)`:
  1. Verify CLI key path: `prime config view`.
  2. Verify repo key path: `grep PRIME_SSH_KEY_PATH config/prime.env`.
  3. Ensure scripts use `root` user (default for pod SSH connections).
  4. Recreate the pod after updating SSH key configuration.
  5. If SSH attempts fail with connection timeouts to `<PORT>`, check whether the pod
     still exposes SSH at that port and recreate/replace the pod if needed.

## Optional Hugging Face

- `hf auth login`
- or
- `export HUGGING_FACE_HUB_TOKEN=hf_...`

## Notes

- Never commit secrets.
- Keep key files out of repo.
- Use minimal privilege and rotate after sharing or suspected exposure.
