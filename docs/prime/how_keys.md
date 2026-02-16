# Prime Intellect: Key and Access Playbook

_Last validated: 2026-02-16_

## Scope

This doc defines secret hygiene for:

- Prime API key (CLI/API auth)
- SSH private key for pod access
- Cloudflare R2 credentials (artifact/cache storage)
- optional Hugging Face token for model pulls

## Secret boundary (what must never enter git)

Do not commit:

- `~/.prime/config.json`
- private SSH keys (`*.pem`, `id_rsa`, etc.)
- token exports (`HUGGING_FACE_HUB_TOKEN`, `PRIME_API_KEY`)
- Cloudflare/R2 credential exports (`AGENT_S3_ACCESS_KEY_ID`, `AGENT_S3_SECRET_ACCESS_KEY`, `CLOUDFLARE_API_TOKEN`)
- `config/prime.env` values

Tracked repo file:

- `config/prime.env.example` only (template, no secrets)

## Recommended local layout

- Prime CLI config: `~/.prime/config.json`
- SSH private key: local path outside repo (for example `~/.ssh/primeintellect_private_key.pem`)
- Cloudflare R2 env file: `/Users/xenochain/agents/secrets/r2_full_access.env`
- Repo runtime env: `config/prime.env` (gitignored)

Use pod id based resolution by default:

- set `PRIME_POD_ID`
- set `PRIME_SSH_KEY_PATH`
- leave `PRIME_SSH_HOST` and `PRIME_SSH_PORT` unset unless doing explicit overrides

## Secure bootstrap sequence

1. Install CLI:
   - `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - `uv tool install prime`
2. Authenticate:
   - `prime login`
   - `prime config set-api-key`
3. Bind SSH key path:
   - `prime config set-ssh-key-path <PATH_TO_PRIVATE_KEY>`
4. If using team credits:
   - `prime teams list`
   - `prime config set-team-id <TEAM_ID>`
5. Verify active context:
   - `prime whoami`
   - `prime config view`

## File permission hardening

Recommended permission checks:

```bash
chmod 600 ~/.ssh/primeintellect_private_key.pem
chmod 600 config/prime.env
```

Quick scan to ensure no tokens leaked into tracked files:

```bash
rg -n "hf_[A-Za-z0-9]{20,}|PRIME_API_KEY|AGENT_S3_ACCESS_KEY_ID|AGENT_S3_SECRET_ACCESS_KEY|CLOUDFLARE_API_TOKEN|BEGIN (RSA|OPENSSH|PRIVATE) KEY" .
```

## SSH troubleshooting flow

If `Permission denied (publickey)`:

1. Confirm configured key path:
   - `prime config view`
2. Confirm repo env path:
   - `grep -n '^PRIME_SSH_KEY_PATH=' config/prime.env`
3. Confirm pod identity/ports:
   - `prime pods status <POD_ID> -o json`
4. Retry direct CLI connect:
   - `prime pods ssh <POD_ID>`
5. If still failing, recreate pod after key fix:
   - `prime pods terminate <POD_ID> --yes`
   - recreate from fresh availability entry

If SSH times out repeatedly, treat the pod endpoint as stale and recreate.

## Hugging Face token hygiene (optional)

Preferred flow:

- `hf auth login` (stores token in HF cache)

Fallback env var:

- `export HUGGING_FACE_HUB_TOKEN=hf_...`

If you export a token in shell history, rotate it afterward.

## Rotation and incident response

Rotate keys immediately if you suspect exposure:

1. Revoke/rotate Prime API key from account settings.
2. Generate a new SSH key pair and update Prime key path.
3. Rotate HF token if it was present in shell logs/files.
4. Terminate all active pods that were launched with exposed credentials.

## Minimal operational policy

1. Keep secrets only in local config files and shell session scope.
2. Use short-lived pods and terminate after each validation run.
3. Re-run `prime whoami` before expensive jobs to confirm the expected team context.
4. Source R2 credentials only for sessions that require cloud storage operations.
