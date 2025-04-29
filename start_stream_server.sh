#!/bin/bash
# Usage: ./start_stream_server.sh

##########################
# SSH connection details #
##########################
SSH_PORT=50267
SSH_HOST="193.69.10.108"
SSH_USER="root"
SSH_KEY="$HOME/.ssh/id_rsa"
PASSPHRASE="1337"

############################################
# Setup temporary SSH config & askpass file #
############################################
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

#############################
# Start ssh-agent & add key #
#############################
if ! pgrep -u "$USER" ssh-agent >/dev/null; then
  eval $(ssh-agent -s)
fi
ssh-add "$SSH_KEY" </dev/null 2>/dev/null

#################################
# Copy script & start in background #
#################################
scp -F "$SSH_CONFIG" realtime_stream.py vastai:/workspace/

# Ensure any old server process is stopped
ssh -F "$SSH_CONFIG" vastai "pkill -f realtime_stream.py || true"
# Start the server using nohup, redirecting output to a log file
ssh -F "$SSH_CONFIG" vastai "cd /workspace && nohup python3 realtime_stream.py > /workspace/server.log 2>&1 &"

sleep 2 # Give server a moment to start

#################################
# Done                          #
#################################
echo "Server started in background on remote. Check /workspace/server.log for errors."
echo "Run ./tunnel_to_stream.sh locally to connect."

# Cleanup temp files
rm -f "$SSH_CONFIG" "$ASKPASS_SCRIPT"

# Kill agent only if we started it in this script (optional)
# ssh-agent -k >/dev/null 2>&1 