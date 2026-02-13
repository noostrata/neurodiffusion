# ImageDiffusion (SD-Turbo)

This is the canonical runbook for image streaming on Prime Intellect.

## Scope

- Start and manage `ImageDiffusion/realtime_stream.py` on a Prime pod.
- Local port-forward to `http://localhost:8888/`.
- Runtime knobs include prompt, inference steps, and guidance scale.

## Run flow

1. Update `config/prime.env` from `config/prime.env.example`.
2. Set at minimum:
   - `PRIME_POD_ID`
   - `PRIME_SSH_KEY_PATH`
3. Run one-time remote setup:
   - `bash ImageDiffusion/remote_setup.sh`
4. Start stream service:
   - `bash ImageDiffusion/start_stream_server.sh`
5. Open tunnel:
   - `bash ImageDiffusion/tunnel_to_stream.sh`
6. Open browser:
  - `http://localhost:8888/`
7. Stop/terminate pod after test pass:
   - `prime pods stop <POD_ID>`

Troubleshooting quick checks:

- key auth issues: see `docs/prime/how_keys.md`
- if SSH scripts fail to resolve, confirm `PRIME_POD_ID` and `prime pods status <ID> -o json`.
- if port forwarding fails and SSH connects but stream is not reachable, verify the pod still exposes
  SSH and 8000/tunnel ports and recreate the pod if it shows repeated connection timeouts.

## Files

- `ImageDiffusion/setup.sh` — installs OS + Python dependencies.
- `ImageDiffusion/remote_setup.sh` — copies setup files and runs them remotely.
- `ImageDiffusion/start_stream_server.sh` — uploads server and starts it on the pod.
- `ImageDiffusion/tunnel_to_stream.sh` — opens SSH tunnel.
- `ImageDiffusion/realtime_stream.py` — streaming server entrypoint.
- `scripts/prime/resolve_ssh.sh` — canonical SSH resolver.

## Troubleshooting

- Service won't start:
  - Ensure Python + torch imports in `/root` logs.
- Tunnel fails:
  - Local port conflict, wrong pod id, or missing key in `config/prime.env`.
- Check logs:
  - remote: `tail -f ~/neurodiffusion/server.log`
  - pod health: `nvidia-smi`

## Note

The old `ImageDiffusion/ssh_*.json` pattern and VAST.ai workflow are now archived under `docs/legacy/`.
