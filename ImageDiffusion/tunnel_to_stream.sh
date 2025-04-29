#!/bin/bash
# Creates an SSH tunnel to access the streaming server

SSH_PORT=50267
SSH_HOST="193.69.10.108"
SSH_USER="root"
SSH_KEY="$HOME/.ssh/id_rsa"
PASSPHRASE="1337"

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

echo "Starting SSH tunnel..."
echo "Browse to http://localhost:8888/ to view the stream"
echo "Press Ctrl+C to stop the tunnel"

# Create the tunnel in the background
ssh -F "$SSH_CONFIG" -N -L 8888:127.0.0.1:8000 vastai &
SSH_PID=$!

# Function to kill the SSH process
cleanup() {
    echo "Stopping SSH tunnel (PID: $SSH_PID)..."
    kill $SSH_PID > /dev/null 2>&1
    wait $SSH_PID 2>/dev/null # Wait for it to actually terminate
    rm -f "$SSH_CONFIG" "$ASKPASS_SCRIPT"
    echo "Tunnel stopped."
}

# Trap EXIT and INT signals to run the cleanup function
trap cleanup EXIT INT

# Wait for the SSH process to finish (or be killed by the trap)
wait $SSH_PID

# Cleanup is now handled by the trap, so remove the explicit cleanup call here 