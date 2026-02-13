# ImageDiffusion (SD-Turbo)

Canonical docs: `docs/image-streaming.md`

## Run order

```bash
cp config/prime.env.example config/prime.env
# fill PRIME_POD_ID and PRIME_SSH_KEY_PATH
bash ImageDiffusion/remote_setup.sh
bash ImageDiffusion/start_stream_server.sh
bash ImageDiffusion/tunnel_to_stream.sh
```

Then open `http://localhost:8888/`.
