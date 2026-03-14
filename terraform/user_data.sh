#!/usr/bin/env bash
# EC2 user data — runs once on first boot as root.
# Installs Node.js and Claude Code CLI, creates a dev user.
set -euo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1
echo "=== Claude Code environment bootstrap starting ==="

# ---------------------------------------------------------------------------
# System updates
# ---------------------------------------------------------------------------
dnf update -y

# ---------------------------------------------------------------------------
# Node.js 20 LTS (required by Claude Code CLI)
# ---------------------------------------------------------------------------
dnf install -y nodejs npm

# Verify node is available
node --version
npm --version

# ---------------------------------------------------------------------------
# Claude Code CLI
# ---------------------------------------------------------------------------
npm install -g @anthropic-ai/claude-code

# Verify install
claude --version || true

# ---------------------------------------------------------------------------
# Developer user
# ---------------------------------------------------------------------------
if ! id "developer" &>/dev/null; then
  useradd -m -s /bin/bash developer
  echo "developer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/developer
  chmod 440 /etc/sudoers.d/developer
fi

# ---------------------------------------------------------------------------
# Useful dev tools
# ---------------------------------------------------------------------------
dnf install -y git tmux vim htop

echo "=== Bootstrap complete ==="
