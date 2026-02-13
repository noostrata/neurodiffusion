# Prime Intellect

All provisioning for this repository uses Prime Intellect pods.

## One-time local setup

1. Install Prime CLI:
   - `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - `uv tool install prime`
2. Authenticate:
   - `prime login`
   - `prime config set-api-key`
   - `prime config set-ssh-key-path <PATH_TO_YOUR_SSH_KEY>`

## Team context

If credits are in a team account, align the CLI context:

- `prime teams list`
- `prime config set-team-id <TEAM_ID>`
- `prime whoami`
- `prime config view`

## Pod lifecycle

- Find capacity:
  - Northern Europe example:
    - `prime availability list --gpu-type H100_80GB --gpu-count 1 --regions eu_north`
  - Other regions:
    - `prime availability list --gpu-type H100_80GB --gpu-count 1 --regions united_states`
  - Availability and pricing are dynamic. Always re-run `prime availability list` right before provisioning.
- For smoke validation and quick experiments, one GPU is sufficient and cheapest.
- Increase GPU count only after smoke succeeds.
- Create:
  - `prime pods create --id <AVAILABILITY_ID> --name neurodiffusion --image ubuntu_22_cuda_12 --gpu-count 1 --disk-size 120 --yes`
- Inspect:
  - `prime pods status <POD_ID>`
  - `prime pods status <POD_ID> -o json`
- Stop once tests are done:
  - `prime pods stop <POD_ID>`
- Terminate if no longer needed:
  - `prime pods terminate <POD_ID>`

## Local run wiring

- Create `config/prime.env` from `config/prime.env.example`.
- Set:
  - `PRIME_POD_ID`
  - `PRIME_SSH_KEY_PATH` (usually the same path from `prime config view`)
- Prefer leaving `PRIME_SSH_PORT` empty in env so resolver uses Prime JSON port values.
- Keep `PRIME_SSH_HOST` unset for portability.

Validation:

- Check SSH connectivity before long jobs:
  - `prime pods ssh <POD_ID>`

Then run scripts listed in `docs/image-streaming.md` or `docs/video-magi1-streaming.md`.

## Region codes

Prime CLI validates `--regions` against a fixed set. Common values:

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

## Cost discipline

- Keep `AVAILABILITY`/`POD` scope small.
- Stop the pod immediately after smoke test passes.
- Prefer one-GPU defaults in both workflows.
