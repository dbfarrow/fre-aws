echo "Region: ${REGION}  Project: ${PROJECT_NAME}  User: ${DEV_USERNAME}"

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
if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
  mkdir -p /home/developer/.ssh
  chmod 700 /home/developer/.ssh
  echo "${SSH_PUBLIC_KEY}" > /home/developer/.ssh/authorized_keys
  chmod 600 /home/developer/.ssh/authorized_keys
  chown -R developer:developer /home/developer/.ssh
  echo "SSH public key installed for developer user."
else
  echo "WARNING: No SSH public key provided — SSH agent forwarding will not work."
fi

# ---------------------------------------------------------------------------
# Git identity (pre-configure; refreshed at each login via SSH env vars)
# ---------------------------------------------------------------------------
[[ -n "${GIT_USER_NAME}"  ]] && su - developer -c "git config --global user.name  '${GIT_USER_NAME}'"
[[ -n "${GIT_USER_EMAIL}" ]] && su - developer -c "git config --global user.email '${GIT_USER_EMAIL}'"
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
