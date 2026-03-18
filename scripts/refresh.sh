#!/usr/bin/env bash
# refresh.sh — Push config updates to a running instance without a rebuild.
# Pushes: session_start.sh, .tmux.conf, autoshutdown timer, .bash_profile guards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve any caller-provided AWS_PROFILE (admin.sh passes its admin profile via --env)
_CALLER_PROFILE="${AWS_PROFILE:-}"

# Load config: user.env takes precedence (user path); fall back to admin.env (admin path)
if [[ -f "${SCRIPT_DIR}/../config/user.env" ]]; then
  source "${SCRIPT_DIR}/../config/user.env"
elif [[ -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  source "${SCRIPT_DIR}/../config/admin.env"
else
  echo "ERROR: No config found. Expected config/user.env or config/admin.env." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

# Caller-provided profile wins (admin.sh refresh must use admin credentials, not user.env's profile)
[[ -n "${_CALLER_PROFILE}" ]] && AWS_PROFILE="${_CALLER_PROFILE}"

: "${AWS_REGION:?}" "${AWS_PROFILE:?}" "${PROJECT_NAME:?}"

# DEV_USERNAME: set by admin.sh (command arg)
DEV_USERNAME="${DEV_USERNAME:-}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh refresh <username>'." >&2
  exit 1
fi

eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}

SESSION_START="${SCRIPT_DIR}/session_start.sh"

# Resolve instance ID by Username tag
echo "--- resolving instance for '${DEV_USERNAME}' ---"
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Username,Values=${DEV_USERNAME}" \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "${AWS_REGION}" \
  --output text 2>/dev/null)

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: No instance found for user '${DEV_USERNAME}' in project '${PROJECT_NAME}'." >&2
  exit 1
fi

SSH_OPTS=(
  "-o" "StrictHostKeyChecking=no"
  "-o" "UserKnownHostsFile=/dev/null"
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  # No agent forwarding — authenticate with key file
  SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.ssh/fre-claude}"
  SSH_OPTS+=("-i" "${SSH_KEY_FILE}")
fi

echo "--- pushing session_start.sh to ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /home/developer/session_start.sh > /dev/null && sudo chmod +x /home/developer/session_start.sh && sudo chown developer:developer /home/developer/session_start.sh" \
  < "${SESSION_START}"

TMUX_CONF="${SCRIPT_DIR}/../config/tmux.conf"
echo "--- pushing .tmux.conf to ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "tee /home/developer/.tmux.conf > /dev/null" \
  < "${TMUX_CONF}"

echo "--- installing autoshutdown on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /usr/local/bin/autoshutdown.sh > /dev/null && sudo chmod +x /usr/local/bin/autoshutdown.sh" \
  << 'AUTOSHUTDOWN'
#!/bin/bash
# Shut down when no tmux sessions exist (user exited deliberately).
# Detached sessions (SSM drop) are kept alive — midnight Lambda handles those.
IDLE_FILE="${HOME}/.autoshutdown-idle-since"
SESSION_COUNT=$(tmux list-sessions 2>/dev/null | wc -l || echo 0)
if [[ "${SESSION_COUNT}" -gt 0 ]]; then
  rm -f "${IDLE_FILE}"; exit 0
fi
[[ ! -f "${IDLE_FILE}" ]] && { date +%s > "${IDLE_FILE}"; exit 0; }
IDLE_MINUTES=$(( ($(date +%s) - $(cat "${IDLE_FILE}")) / 60 ))
if [[ "${IDLE_MINUTES}" -ge 10 ]]; then
  logger "autoshutdown: no tmux sessions for ${IDLE_MINUTES}min — shutting down"
  sudo shutdown -h now
fi
AUTOSHUTDOWN

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /etc/systemd/system/autoshutdown.timer > /dev/null" \
  << 'TIMER'
[Unit]
Description=Auto-shutdown when idle

[Timer]
OnBootSec=15min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /etc/systemd/system/autoshutdown.service > /dev/null" \
  << 'SERVICE'
[Unit]
Description=Auto-shutdown check

[Service]
Type=oneshot
User=developer
ExecStart=/usr/local/bin/autoshutdown.sh
SERVICE

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo systemctl daemon-reload && sudo systemctl enable --now autoshutdown.timer && echo '  autoshutdown timer active'"

# Also ensure .bash_profile has both the stdin-is-terminal guard (-t 0) and
# the TMUX guard (-z "${TMUX:-}") so session_start.sh never fires inside an
# existing tmux window or from non-interactive shells.
echo "--- patching .bash_profile on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" '
  if grep -q "SSH_TTY" ~/.bash_profile && ! grep -q "\-t 0" ~/.bash_profile; then
    sed -i "s/\[\[ -n \"\${SSH_TTY:-}\" \]\]/[[ -n \"\${SSH_TTY:-}\" \&\& -t 0 ]]/" ~/.bash_profile
    echo "  .bash_profile: added -t 0 guard."
  fi
  if grep -q "SSH_TTY" ~/.bash_profile && ! grep -q "TMUX" ~/.bash_profile; then
    sed -i "s/-t 0 \]\]/-t 0 \&\& -z \"\${TMUX:-}\" ]]/" ~/.bash_profile
    echo "  .bash_profile: added TMUX guard."
  else
    echo "  .bash_profile already up to date."
  fi
'

echo ""
echo "=== refresh complete on ${INSTANCE_ID} (${DEV_USERNAME}) ==="
echo "    session_start.sh + .tmux.conf: take effect on next connect"
echo "    autoshutdown timer:            active immediately"
