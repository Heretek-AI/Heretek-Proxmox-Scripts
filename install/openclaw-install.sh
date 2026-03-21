#!/usr/bin/env bash

# Author: BIllyOutlast
# License: MIT | https://github.com/Heretek-AI/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openclaw/openclaw
# Documentation: https://docs.openclaw.ai

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  wget \
  ca-certificates \
  build-essential \
  python3 \
  python3-pip \
  python3-venv \
  git \
  procps \
  debian-keyring \
  debian-archive-keyring \
  ffmpeg \
  sudo
msg_ok "Installed Dependencies"

# Install Caddy for HTTPS reverse proxy
msg_info "Installing Caddy (HTTPS Reverse Proxy)"
$STD apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' >/etc/apt/sources.list.d/caddy-stable.list
$STD apt-get update
$STD apt-get install -y caddy
msg_ok "Installed Caddy"

# Setup Node.js 24 (recommended by OpenClaw documentation)
NODE_VERSION="24" setup_nodejs

# Install uv (Python package manager) - OpenClaw uses Python for some tools
PYTHON_VERSION="3.12" setup_uv

# Create unprivileged user for OpenClaw
msg_info "Creating OpenClaw User"
if ! id -u openclaw &>/dev/null; then
  useradd -r -s /bin/bash -d /home/openclaw -m openclaw
  # Add openclaw to sudoers for specific operations if needed
  usermod -aG sudo openclaw 2>/dev/null || true
fi
msg_ok "Created OpenClaw User"

# Configure npm to use user-writable directory for global packages
msg_info "Configuring npm for User Packages"
mkdir -p /home/openclaw/.npm-global
chown -R openclaw:openclaw /home/openclaw/.npm-global
# Set npm prefix for openclaw user to use home directory
run_user_cmd="su - openclaw -c"
$run_user_cmd "npm config set prefix /home/openclaw/.npm-global"
# Add to PATH for openclaw user
echo 'export PATH=/home/openclaw/.npm-global/bin:$PATH' >> /home/openclaw/.bashrc
msg_ok "Configured npm for User Packages"

msg_info "Installing OpenClaw"
# Install OpenClaw globally as the openclaw user
$run_user_cmd "npm install -g openclaw@latest"
msg_ok "Installed OpenClaw"

msg_info "Creating Directories"
mkdir -p /opt/openclaw
mkdir -p /home/openclaw/.openclaw
mkdir -p /home/openclaw/.openclaw/workspace
mkdir -p /home/openclaw/.openclaw/workspace/memory
chown -R openclaw:openclaw /opt/openclaw
chown -R openclaw:openclaw /home/openclaw/.openclaw
# Security: Restrict state directory to owner only (fixes world-readable warning)
chmod 700 /home/openclaw/.openclaw
msg_ok "Created Directories"

msg_info "Creating OpenClaw Configuration"
# Get the container's IP address for allowedOrigins
CONTAINER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
# Get hostname for HTTPS origins
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
# Generate a secure random auth token (32 bytes = 64 hex chars)
AUTH_TOKEN=$(openssl rand -hex 32)
cat <<EOF >/home/openclaw/.openclaw/openclaw.json
{
  "gateway": {
    "bind": "lan",
    "port": 18789,
    "auth": {
      "token": "${AUTH_TOKEN}"
    },
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789",
        "https://localhost:18790",
        "https://127.0.0.1:18790",
        "https://${CONTAINER_IP}:18790",
        "https://${HOSTNAME_FQDN}:18790"
      ]
    },
    "reload": {
      "mode": "hybrid"
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/openclaw/.openclaw/workspace"
    }
  }
}
EOF
chown openclaw:openclaw /home/openclaw/.openclaw/openclaw.json
# Security: Restrict config file to owner only (fixes world-readable critical issue)
chmod 600 /home/openclaw/.openclaw/openclaw.json
msg_ok "Created OpenClaw Configuration"

msg_info "Creating Self-Signed Certificate for HTTPS"
# Generate self-signed certificate with IP in SAN (Caddy's tls internal doesn't work with IPs)
mkdir -p /etc/caddy/certs
CONTAINER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)

# Generate self-signed certificate valid for 365 days
openssl req -x509 -newkey rsa:4096 -keyout /etc/caddy/certs/openclaw.key \
  -out /etc/caddy/certs/openclaw.crt \
  -days 365 -nodes \
  -subj "/CN=openclaw-local" \
  -addext "subjectAltName=IP:127.0.0.1,IP:${CONTAINER_IP},DNS:localhost,DNS:${HOSTNAME_FQDN}" 2>/dev/null

# Set proper permissions
chmod 644 /etc/caddy/certs/openclaw.crt
chmod 600 /etc/caddy/certs/openclaw.key
chown caddy:caddy /etc/caddy/certs/openclaw.crt /etc/caddy/certs/openclaw.key
msg_ok "Created Self-Signed Certificate"

msg_info "Creating Caddy HTTPS Reverse Proxy"
# Create Caddyfile for HTTPS reverse proxy with explicit certificate paths
cat <<EOF >/etc/caddy/Caddyfile
# OpenClaw HTTPS Reverse Proxy
# Access via https://<container-ip>:18790

:18790 {
    tls /etc/caddy/certs/openclaw.crt /etc/caddy/certs/openclaw.key
    
    # Caddy automatically handles WebSocket upgrades
    reverse_proxy localhost:18789 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
    
    # Log requests
    log {
        output file /var/log/caddy/openclaw.log
        format console
    }
}
EOF

# Create log directory
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

# Enable Caddy
systemctl enable -q caddy
msg_ok "Created Caddy HTTPS Reverse Proxy"

msg_info "Enabling Lingering for OpenClaw User"
# Enable lingering so user-level systemd services start on boot
loginctl enable-linger openclaw 2>/dev/null || true
msg_ok "Enabled Lingering"

msg_info "Installing OpenClaw Gateway Service"
# Run OpenClaw onboarding to create user-level systemd service properly
# Using --non-interactive with essential defaults
export PATH="/home/openclaw/.npm-global/bin:$PATH"
export OPENCLAW_CONFIG_PATH="/home/openclaw/.openclaw/openclaw.json"

# Install the gateway service using the recommended method
$run_user_cmd "export PATH=/home/openclaw/.npm-global/bin:\$PATH && openclaw gateway install" 2>/dev/null || true

# If the service wasn't created, create it manually
if [[ ! -f /home/openclaw/.config/systemd/user/openclaw-gateway.service ]]; then
  msg_info "Creating Manual Systemd Service"
  mkdir -p /home/openclaw/.config/systemd/user
  cat <<EOF >/home/openclaw/.config/systemd/user/openclaw-gateway.service
[Unit]
Description=OpenClaw Gateway
Documentation=https://docs.openclaw.ai
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/openclaw/.openclaw
Environment="PATH=/home/openclaw/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
Environment="OPENCLAW_CONFIG_PATH=/home/openclaw/.openclaw/openclaw.json"
ExecStart=/home/openclaw/.npm-global/bin/openclaw gateway
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
  chown -R openclaw:openclaw /home/openclaw/.config
  chmod 600 /home/openclaw/.config/systemd/user/openclaw-gateway.service
fi
msg_ok "Installed OpenClaw Gateway Service"

msg_info "Starting Caddy HTTPS Proxy"
# Restart Caddy to apply configuration
systemctl restart caddy
msg_ok "Started Caddy HTTPS Proxy"

msg_info "Starting OpenClaw Gateway"
# Start the gateway service as the openclaw user
$run_user_cmd "systemctl --user enable openclaw-gateway" 2>/dev/null || true
$run_user_cmd "systemctl --user start openclaw-gateway" 2>/dev/null || true
msg_ok "Started OpenClaw Gateway"

# Wait for gateway to be ready
msg_info "Verifying Installation"
sleep 5

# Check if gateway is running
if $run_user_cmd "systemctl --user is-active openclaw-gateway" 2>/dev/null | grep -q "active"; then
  msg_ok "Gateway Service is Active"
else
  msg_warn "Gateway Service may not be running - check logs with: su - openclaw -c 'journalctl --user -u openclaw-gateway'"
fi

# Display auth token for pairing
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  OpenClaw Auth Token (save this for pairing):"
echo "  ${AUTH_TOKEN}"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Access URLs:"
echo "  HTTP:  http://${CONTAINER_IP}:18789"
echo "  HTTPS: https://${CONTAINER_IP}:18790"
echo ""
echo "═══════���═══════════════════════════════════════════════════════════════════════"
echo "  Next Steps:"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  1. Configure a Model Provider (REQUIRED for OpenClaw to function):"
echo ""
echo "     Option A - Ollama (Local, Free):"
echo "       • Install Ollama: curl -fsSL https://ollama.com/install.sh | sh"
echo "       • Pull a model: ollama pull llama3.2"
echo "       • Pull embedding model: ollama pull nomic-embed-text"
echo "       • Configure OpenClaw:"
echo "         su - openclaw"
echo "         openclaw configure"
echo "         # Select Ollama as provider"
echo ""
echo "     Option B - OpenAI API:"
echo "       su - openclaw"
echo "       openclaw models auth add --provider openai"
echo "       # Enter your API key when prompted"
echo ""
echo "     Option C - Anthropic Claude:"
echo "       su - openclaw"
echo "       openclaw models auth add --provider anthropic"
echo "       # Enter your API key when prompted"
echo ""
echo "  2. Configure Channels (Optional - for messaging):"
echo "     su - openclaw"
echo "     openclaw channels add --channel telegram --token YOUR_BOT_TOKEN"
echo "     openclaw channels add --channel discord --token YOUR_BOT_TOKEN"
echo ""
echo "  3. Verify Installation:"
echo "     su - openclaw"
echo "     openclaw doctor"
echo "     openclaw gateway status"
echo "     openclaw models status"
echo ""
echo "  4. View Logs:"
echo "     su - openclaw"
echo "     openclaw logs --follow"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  Memory Search Configuration"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Memory search requires an embedding provider. Configure one of:"
echo "  - Ollama (local): https://docs.openclaw.ai/reference/memory-config"
echo "  - OpenAI, Gemini, Voyage, or Mistral (cloud)"
echo ""
echo "  To configure Ollama (recommended for offline use):"
echo "    1. Ensure Ollama is running on this host or accessible remotely"
echo "    2. Pull an embedding model: ollama pull nomic-embed-text"
echo "    3. Edit config: nano ~/.openclaw/openclaw.json"
echo ""
echo "  Add to config under 'agents.defaults.memorySearch':"
echo '    { "provider": "ollama", "model": "nomic-embed-text",'
echo '      "remote": { "baseUrl": "http://YOUR_OLLAMA_HOST:11434" } }'
echo ""
echo "  See docs/guides/openclaw-configuration.md for detailed setup."
echo ""

motd_ssh
customize
cleanup_lxc
