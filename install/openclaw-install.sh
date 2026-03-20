#!/usr/bin/env bash

# Author: BIllyOutlast
# License: MIT | https://github.com/Heretek-AI/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openclaw/openclaw

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
  debian-archive-keyring
msg_ok "Installed Dependencies"

# Install Caddy for HTTPS reverse proxy
msg_info "Installing Caddy (HTTPS Reverse Proxy)"
$STD apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' >/etc/apt/sources.list.d/caddy-stable.list
$STD apt-get update
$STD apt-get install -y caddy
msg_ok "Installed Caddy"

# Setup Node.js 22 (required by OpenClaw)
NODE_VERSION="22" setup_nodejs

# Install uv (Python package manager)
msg_info "Installing uv (Python Package Manager)"
$STD curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
msg_ok "Installed uv"

# Install Homebrew (Linuxbrew) - optional for OpenClaw skills
# Note: Homebrew is optional and used for some skills like ffmpeg
# If installation fails, OpenClaw will still work, just some skills may need manual setup
msg_info "Installing Homebrew (Linuxbrew) - Optional"
HOMEBREW_SUCCESS=false
# Homebrew refuses to install as root, so we use the alternative untar method
# This installs to /home/linuxbrew/.linuxbrew which is the recommended location
if [[ $EUID -eq 0 ]]; then
  # Create the linuxbrew directory with proper permissions
  mkdir -p /home/linuxbrew/.linuxbrew
  chmod 775 /home/linuxbrew
  chmod 775 /home/linuxbrew/.linuxbrew
  
  # Download and extract Homebrew (alternative installation method)
  cd /tmp
  # Try to download Homebrew tarball with retry
  for i in 1 2 3; do
    if curl -fsSL https://github.com/Homebrew/brew/tarball/master -o /tmp/homebrew.tar.gz; then
      if tar xzf /tmp/homebrew.tar.gz --strip 1 -C /home/linuxbrew/.linuxbrew 2>/dev/null; then
        HOMEBREW_SUCCESS=true
        break
      fi
    fi
    msg_info "Homebrew download attempt $i failed, retrying..."
    sleep 2
  done
  
  if [[ "$HOMEBREW_SUCCESS" == "true" ]]; then
    # Set permissions so brew can be run by anyone
    chown -R root:root /home/linuxbrew/.linuxbrew
    chmod -R g+w /home/linuxbrew/.linuxbrew
    
    # Create symlinks for easy access
    ln -sf /home/linuxbrew/.linuxbrew/bin/brew /usr/local/bin/brew 2>/dev/null || true
    
    # Add to bashrc for persistence
    if ! grep -q 'linuxbrew/.linuxbrew/bin/brew' /root/.bashrc 2>/dev/null; then
      echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >>/root/.bashrc
    fi
    
    # Add to system profile for all users
    if ! grep -q 'linuxbrew/.linuxbrew' /etc/profile 2>/dev/null; then
      echo 'export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"' >>/etc/profile
    fi
    
    # Make brew available in current session
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv 2>/dev/null)" || true
    msg_ok "Installed Homebrew"
  else
    msg_error "Failed to install Homebrew - some skills may need manual setup"
    msg_info "You can install Homebrew manually later with: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  fi
else
  # Not running as root, install normally
  if $STD /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    HOMEBREW_SUCCESS=true
    msg_ok "Installed Homebrew"
  else
    msg_error "Failed to install Homebrew - some skills may need manual setup"
  fi
fi

# Install common brew dependencies for OpenClaw skills (only if Homebrew installed successfully)
if [[ "$HOMEBREW_SUCCESS" == "true" ]]; then
  msg_info "Installing Homebrew Dependencies"
  if command -v brew &>/dev/null || [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    # Use the full path to brew if not in PATH
    BREW_CMD="${BREW_CMD:-/home/linuxbrew/.linuxbrew/bin/brew}"
    if [[ ! -x "$BREW_CMD" ]]; then
      BREW_CMD="brew"
    fi
    # Install ffmpeg for video-frames skill
    $STD $BREW_CMD install ffmpeg 2>/dev/null || true
    # Note: Other brew packages (camsnap, obsidian, summarize, songsee) require specific taps
    # These can be installed manually by the user if needed
  fi
  msg_ok "Installed Homebrew Dependencies"
fi

msg_info "Installing OpenClaw"
$STD npm install -g openclaw@latest
msg_ok "Installed OpenClaw"

msg_info "Creating Directories"
mkdir -p /opt/openclaw
mkdir -p /root/.openclaw
msg_ok "Created Directories"

msg_info "Creating OpenClaw Configuration"
# Get the container's IP address for allowedOrigins
CONTAINER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
# Get hostname for HTTPS origins
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
cat <<EOF >/root/.openclaw/openclaw.json
{
  "gateway": {
    "bind": "loopback",
    "port": 18789,
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789",
        "https://localhost:18790",
        "https://127.0.0.1:18790",
        "https://${CONTAINER_IP}:18790",
        "https://${HOSTNAME_FQDN}:18790"
      ]
    }
  }
}
EOF
msg_ok "Created OpenClaw Configuration"

msg_info "Creating Caddy HTTPS Reverse Proxy"
# Create Caddyfile for HTTPS reverse proxy
# Caddy will automatically generate self-signed certificates for local IPs
cat <<EOF >/etc/caddy/Caddyfile
# OpenClaw HTTPS Reverse Proxy
# Access via https://<container-ip>:18790

:18790 {
    tls internal
    
    reverse_proxy localhost:18789 {
        # WebSocket support
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        
        # WebSocket upgrade headers
        @websockets {
            header Connection *Upgrade*
            header Upgrade websocket
        }
        reverse_proxy @websockets localhost:18789
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

msg_info "Creating OpenClaw Service"
cat <<EOF >/etc/systemd/system/openclaw.service
[Unit]
Description=OpenClaw Gateway - Personal AI Assistant
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/openclaw
Environment=NODE_ENV=production
ExecStart=/usr/bin/openclaw gateway --port 18789 --bind loopback
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now openclaw
msg_ok "Created OpenClaw Service"

msg_info "Starting Caddy HTTPS Proxy"
# Restart Caddy to apply configuration
systemctl restart caddy
msg_ok "Started Caddy HTTPS Proxy"

motd_ssh
customize
cleanup_lxc
