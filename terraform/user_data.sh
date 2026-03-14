#!/usr/bin/env bash
# EC2 user data — runs once on first boot as root.
#
# Variables injected by Terraform templatefile():
SSH_PUBLIC_KEY="${ssh_public_key}"
GIT_USER_NAME="${git_user_name}"
GIT_USER_EMAIL="${git_user_email}"
PROJECT_NAME="${project_name}"

set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1
echo "=== Claude Code environment bootstrap starting ==="

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
# GitHub CLI (used by session launcher to list and clone repos)
# ---------------------------------------------------------------------------
dnf install -y 'dnf-command(config-manager)'
dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
dnf install -y gh
gh --version

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
  echo "WARNING: No SSH public key provided. Set SSH_PUBLIC_KEY_FILE in config/defaults.env."
fi

# ---------------------------------------------------------------------------
# Git identity (pre-configure; also refreshed at login via SSH env)
# ---------------------------------------------------------------------------
[[ -n "$GIT_USER_NAME"  ]] && su - developer -c "git config --global user.name  '$GIT_USER_NAME'"
[[ -n "$GIT_USER_EMAIL" ]] && su - developer -c "git config --global user.email '$GIT_USER_EMAIL'"
su - developer -c "git config --global core.editor vim"
su - developer -c "git config --global init.defaultBranch main"

# ---------------------------------------------------------------------------
# SSH server — accept git identity and GitHub token from the SSH client
# ---------------------------------------------------------------------------
cat >> /etc/ssh/sshd_config << 'SSHD_CONF'

# fre-aws: allow developer login with SSH keys only
AllowUsers developer
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no

# Forward these env vars from the connecting SSH client
AcceptEnv LANG LC_* GH_TOKEN GIT_USER_NAME GIT_USER_EMAIL
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
# Session launcher — written to disk, invoked at every SSH login
# ---------------------------------------------------------------------------
cat > /home/developer/session_start.sh << 'END_SESSION'
#!/bin/bash
# session_start.sh — Interactive Claude Code session launcher.
# Runs automatically on SSH login. Presents a repo menu then starts Claude.

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
# Fetch repository list
# ---------------------------------------------------------------------------
REPO_LIST=()
if command -v gh &>/dev/null && [[ -n "${GH_TOKEN:-}" ]]; then
  echo "Fetching your repositories..."
  while IFS= read -r repo; do
    [[ -n "${repo}" ]] && REPO_LIST+=("${repo}")
  done < <(GH_TOKEN="${GH_TOKEN}" gh repo list --limit 100 \
             --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Display menu
# ---------------------------------------------------------------------------
OPTIONS=()
IDX=1
for repo in "${REPO_LIST[@]}"; do
  LOCAL_DIR="${REPOS_DIR}/$(basename "${repo}")"
  if [[ -d "${LOCAL_DIR}/.git" ]]; then
    printf "  %2d) %s  (cloned)\n" "${IDX}" "${repo}"
  else
    printf "  %2d) %s\n" "${IDX}" "${repo}"
  fi
  OPTIONS+=("${repo}")
  (( IDX++ ))
done

if [[ ${#OPTIONS[@]} -eq 0 && -z "${GH_TOKEN:-}" ]]; then
  echo "  (Set GITHUB_TOKEN in config/defaults.env to enable repo listing)"
  echo ""
fi

printf "  %2d) Open a shell\n" "${IDX}"
SHELL_OPT=${IDX}
echo ""
read -r -p "Choose [${SHELL_OPT}]: " CHOICE
CHOICE="${CHOICE:-${SHELL_OPT}}"

# ---------------------------------------------------------------------------
# Shell option
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "${SHELL_OPT}" ]]; then
  echo ""
  echo "Repos are in ~/repos/. Type 'claude' to start Claude Code."
  cd "${HOME}"
  exec bash
fi

# Validate
if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#OPTIONS[@]} )); then
  echo "Invalid choice. Dropping into shell."
  cd "${HOME}"
  exec bash
fi

SELECTED="${OPTIONS[$((CHOICE-1))]}"
REPO_NAME=$(basename "${SELECTED}")
LOCAL_DIR="${REPOS_DIR}/${REPO_NAME}"

echo ""

# ---------------------------------------------------------------------------
# Clone or update
# ---------------------------------------------------------------------------
if [[ -d "${LOCAL_DIR}/.git" ]]; then
  echo "Checking ${REPO_NAME} for updates..."
  cd "${LOCAL_DIR}"
  git fetch --quiet origin 2>/dev/null || true

  LOCAL_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
  REMOTE_SHA=$(git rev-parse "@{u}" 2>/dev/null || echo "")

  if [[ -n "${REMOTE_SHA}" && "${LOCAL_SHA}" != "${REMOTE_SHA}" ]]; then
    BEHIND=$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo "0")
    echo "  Local copy is ${BEHIND} commit(s) behind origin."
    read -r -p "  Pull latest? [Y/n]: " PULL
    if [[ ! "${PULL:-}" =~ ^[Nn]$ ]]; then
      git pull
      echo "  Pulled."
    fi
  else
    echo "  Up to date."
  fi
else
  echo "Cloning ${SELECTED}..."
  mkdir -p "${REPOS_DIR}"
  if [[ -n "${GH_TOKEN:-}" ]]; then
    GH_TOKEN="${GH_TOKEN}" gh repo clone "${SELECTED}" "${LOCAL_DIR}"
  else
    git clone "git@github.com:${SELECTED}.git" "${LOCAL_DIR}"
  fi
  cd "${LOCAL_DIR}"
  echo "  Done."
fi

# ---------------------------------------------------------------------------
# Launch Claude Code
# ---------------------------------------------------------------------------
echo ""
echo "Starting Claude Code in ${LOCAL_DIR}..."
echo ""
cd "${LOCAL_DIR}"
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
