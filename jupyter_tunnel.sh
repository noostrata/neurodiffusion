#!/bin/bash
# Creates an SSH tunnel to access the Jupyter notebook server

SSH_PORT="${SSH_PORT:?Set SSH_PORT}"
SSH_HOST="${SSH_HOST:?Set SSH_HOST}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
PASSPHRASE="${PASSPHRASE:?Set PASSPHRASE}"
REMOTE_JUPYTER_PORT="${REMOTE_JUPYTER_PORT:-8080}"
LOCAL_PORT="${LOCAL_PORT:-9999}"
JUPYTER_TOKEN="${JUPYTER_TOKEN:?Set JUPYTER_TOKEN}"

# Setup temporary SSH config & askpass
SSH_CONFIG=$(mktemp)
cat > "$SSH_CONFIG" << EOL
Host vastai
    HostName $SSH_HOST
    Port $SSH_PORT
    User $SSH_USER
    IdentityFile $SSH_KEY
    StrictHostKeyChecking no
    PasswordAuthentication no
EOL

ASKPASS_SCRIPT=$(mktemp)
cat > "$ASKPASS_SCRIPT" << EOL
#!/bin/bash
echo "$PASSPHRASE"
EOL
chmod +x "$ASKPASS_SCRIPT"

export SSH_ASKPASS="$ASKPASS_SCRIPT"
export DISPLAY=:0
export SSH_ASKPASS_REQUIRE=force

# Start ssh-agent & add key
if ! pgrep -u "$USER" ssh-agent >/dev/null; then
  eval $(ssh-agent -s)
fi
ssh-add "$SSH_KEY" </dev/null 2>/dev/null

echo "Starting SSH tunnel to Jupyter..."
echo "Open this URL in your browser:"
echo "http://localhost:${LOCAL_PORT}/lab?token=${JUPYTER_TOKEN}"
echo "Press Ctrl+C to stop the tunnel"

# Create the tunnel (local:JUPYTER_PORT -> remote:JUPYTER_PORT)
ssh -F "$SSH_CONFIG" -N -L ${LOCAL_PORT}:127.0.0.1:${REMOTE_JUPYTER_PORT} vastai

# Cleanup
rm -f "$SSH_CONFIG" "$ASKPASS_SCRIPT" 