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
# Session launcher — invoked at every SSH login via .bash_profile
# ---------------------------------------------------------------------------
cat > /home/developer/session_start.sh << 'END_SESSION'
#!/bin/bash
# session_start.sh — Interactive Claude Code session launcher.
# Runs automatically on SSH login. Offers locally-cloned repos, a blank
# Claude session, or a plain shell. GitHub auth and repo cloning are
# handled by Claude Code itself.

# Refresh git identity if passed through SSH env
[[ -n "${GIT_USER_NAME:-}"  ]] && git config --global user.name  "${GIT_USER_NAME}"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config --global user.email "${GIT_USER_EMAIL}"

REPOS_DIR="${HOME}/repos"
mkdir -p "${REPOS_DIR}"

echo ""
echo "╔═══════════════════════════════════════╗"
echo "║     Claude Code Development Env       ║"
echo "╚═══════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Build menu from locally-cloned repos
# ---------------------------------------------------------------------------
OPTIONS=()
IDX=1

while IFS= read -r -d '' dir; do
  REPO_NAME=$(basename "${dir}")
  printf "  %2d) %s\n" "${IDX}" "${REPO_NAME}"
  OPTIONS+=("${dir}")
  (( IDX++ ))
done < <(find "${REPOS_DIR}" -mindepth 1 -maxdepth 1 -type d -name "*.git" -prune -o \
           -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

printf "  %2d) New session (no project)\n" "${IDX}"; NEW_OPT=${IDX}; (( IDX++ ))
printf "  %2d) Open a shell\n"             "${IDX}"; SHELL_OPT=${IDX}
echo ""
read -r -p "Choose [${NEW_OPT}]: " CHOICE
CHOICE="${CHOICE:-${NEW_OPT}}"

# ---------------------------------------------------------------------------
# Shell option
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "${SHELL_OPT}" ]]; then
  echo ""
  echo "Repos are in ~/repos/. Type 'claude' to start Claude Code."
  cd "${HOME}"
  exec bash
fi

# ---------------------------------------------------------------------------
# New session — launch Claude from home, no project pre-selected
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "${NEW_OPT}" ]]; then
  echo ""
  echo "Starting Claude Code..."
  echo ""
  cd "${HOME}"
  exec claude
fi

# Validate repo choice
if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#OPTIONS[@]} )); then
  echo "Invalid choice. Dropping into shell."
  cd "${HOME}"
  exec bash
fi

# ---------------------------------------------------------------------------
# Launch Claude in the selected repo
# ---------------------------------------------------------------------------
SELECTED="${OPTIONS[$((CHOICE-1))]}"
echo ""
echo "Starting Claude Code in $(basename "${SELECTED}")..."
echo ""
cd "${SELECTED}"
exec claude
END_SESSION

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
