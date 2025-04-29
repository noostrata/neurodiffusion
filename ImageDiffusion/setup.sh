#!/bin/bash
# Setup script for the SD-Turbo real-time streaming server on VAST.ai

set -e

WORKSPACE="/workspace"

echo "🚀 Setting up SD-Turbo real-time streaming environment..."

# Make sure we're in the workspace directory
cd $WORKSPACE

# Update packages and install basic tools if needed
echo "📦 Updating system packages and installing dependencies..."
apt update -y
# Add any other essential tools like git, htop, tmux if not present by default
apt install -y git python3-pip

# Install required Python packages with compatible versions
echo "🐍 Installing Python dependencies (this may take several minutes)..."
# Use known compatible versions from vastai_setup_log.txt
pip install torch==2.0.1+cu118 torchvision==0.15.2+cu118 --extra-index-url https://download.pytorch.org/whl/cu118
pip install numpy==1.26.4
pip install diffusers==0.24.0 transformers==4.32.0 accelerate==0.23.0 xformers==0.0.22
pip install Flask Flask-Cors

echo "✅ Setup complete!"
echo "You can now copy 'realtime_stream.py' to /workspace on the VAST.ai instance."
echo "Then run 'start_stream_server.sh' locally to start the server remotely."
echo "And run 'tunnel_to_stream.sh' locally to access the stream." 