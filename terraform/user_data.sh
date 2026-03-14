#!/usr/bin/env bash
# EC2 user data — runs once on first boot as root.
# Configuration is read from SSM Parameter Store using the instance's IAM role.
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1
echo "=== Claude Code environment bootstrap starting ==="

# ---------------------------------------------------------------------------
# Read provisioning config from SSM Parameter Store.
# IMDSv2 gives us the region and project name; the IAM role authorises the
# ssm:GetParameter calls.
# ---------------------------------------------------------------------------
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/region")
PROJECT_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/tags/instance/ProjectName")

echo "Region: $REGION  Project: $PROJECT_NAME"

read_param() {
  aws ssm get-parameter --name "$1" --region "$REGION" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo ""
}

SSH_PUBLIC_KEY=$(read_param "/${PROJECT_NAME}/developer/ssh-public-key")
GIT_USER_NAME=$(read_param  "/${PROJECT_NAME}/developer/git-user-name")
GIT_USER_EMAIL=$(read_param "/${PROJECT_NAME}/developer/git-user-email")

# ---------------------------------------------------------------------------
# System updates and tools
# ---------------------------------------------------------------------------
dnf update -y
dnf install -y git tmux vim htop openssh-server

# ---------------------------------------------------------------------------
# Node.js (required by Claude Code CLI)
# ---------------------------------------------------------------------------
dnf install -y nodejs npm
node --version
npm --version

# ---------------------------------------------------------------------------
# Claude Code CLI
# ---------------------------------------------------------------------------
npm install -g @anthropic-ai/claude-code
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
# SSH authorized key
# ---------------------------------------------------------------------------
if [[ -n "$SSH_PUBLIC_KEY" ]]; then
  mkdir -p /home/developer/.ssh
  chmod 700 /home/developer/.ssh
  echo "$SSH_PUBLIC_KEY" > /home/developer/.ssh/authorized_keys
  chmod 600 /home/developer/.ssh/authorized_keys
  chown -R developer:developer /home/developer/.ssh
  echo "SSH public key installed for developer user."
else
  echo "WARNING: No SSH public key found in SSM. Set SSH_PUBLIC_KEY_FILE in config/defaults.env and re-run 'up'."
fi

# ---------------------------------------------------------------------------
# Git identity (pre-configure; refreshed at each login via SSH env vars)
# ---------------------------------------------------------------------------
[[ -n "$GIT_USER_NAME"  ]] && su - developer -c "git config --global user.name  '$GIT_USER_NAME'"
[[ -n "$GIT_USER_EMAIL" ]] && su - developer -c "git config --global user.email '$GIT_USER_EMAIL'"
su - developer -c "git config --global core.editor vim"
su - developer -c "git config --global init.defaultBranch main"

# ---------------------------------------------------------------------------
# SSH server — accept git identity from the SSH client
# ---------------------------------------------------------------------------
cat >> /etc/ssh/sshd_config << 'SSHD_CONF'

# fre-aws: allow developer login with public key only
AllowUsers developer
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no

# Forward these env vars from the connecting SSH client
AcceptEnv LANG LC_* GIT_USER_NAME GIT_USER_EMAIL
SSHD_CONF

systemctl enable sshd
systemctl start sshd
echo "SSH server configured."

# ---------------------------------------------------------------------------
# Repo workspace
# ---------------------------------------------------------------------------
mkdir -p /home/developer/repos
chown developer:developer /home/developer/repos

# ---------------------------------------------------------------------------
# Session launcher — fetch from S3 and install
# Edits to scripts/session_start.sh are pushed live via ./run.sh refresh
# ---------------------------------------------------------------------------
aws s3 cp "s3://${PROJECT_NAME}-tfstate/scripts/session_start.sh" \
  /home/developer/session_start.sh \
  --region "${REGION}"

chmod +x /home/developer/session_start.sh
chown developer:developer /home/developer/session_start.sh

# ---------------------------------------------------------------------------
# Invoke session launcher on interactive SSH login
# ---------------------------------------------------------------------------
cat >> /home/developer/.bash_profile << 'PROFILE'

# Launch Claude Code session selector on interactive SSH login
if [[ -n "${SSH_TTY:-}" ]]; then
  exec /home/developer/session_start.sh
fi
PROFILE

chown developer:developer /home/developer/.bash_profile
echo "=== Bootstrap complete ==="
