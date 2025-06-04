# Neurodiffusion Streaming Scripts

This repository contains helper scripts for running the realtime streaming setup.

## Environment Variables

The scripts expect connection details to be supplied via environment variables:

- `SSH_HOST` – IP or hostname of the remote machine (required)
- `SSH_PORT` – SSH port for the remote machine (required)
- `SSH_USER` – SSH username (default: `root`)
- `SSH_KEY` – path to the SSH private key (default: `$HOME/.ssh/id_rsa`)
- `PASSPHRASE` – passphrase for `SSH_KEY` (required)
- `LOCAL_PORT` – local forwarding port used by `tunnel_to_stream.sh` (default: `8888`)
- `STREAM_PORT` – remote stream server port for `tunnel_to_stream.sh` (default: `8000`)
- `REMOTE_JUPYTER_PORT` – remote Jupyter port for `jupyter_tunnel.sh` (default: `8080`)
- `JUPYTER_TOKEN` – access token for the Jupyter server (required for `jupyter_tunnel.sh`)

Set these variables in your environment before running the scripts. Example:

```bash
export SSH_HOST=203.0.113.1
export SSH_PORT=2222
export PASSPHRASE=your_passphrase
export JUPYTER_TOKEN=your_token
./start_stream_server.sh
```

## Ignored Files

Local configuration JSON files like `ssh_12345.json` should not be committed. A
`.gitignore` entry excludes any file matching `ssh_*.json`.
