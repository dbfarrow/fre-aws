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

_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")
_CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials${AWS_PROFILE:+ for profile '${AWS_PROFILE}'}." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${_CREDS}" | sed 's/^/export /')"
unset _CREDS _PROFILE_ARGS

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
  "-o" "LogLevel=ERROR"
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
  TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
  REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
  logger "autoshutdown: no tmux sessions for ${IDLE_MINUTES}min — stopping via EC2 API"
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
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

# Ensure .bash_profile uses the correct session launcher guard:
#   [[ -t 0 && -z "${TMUX:-}" ]]  (SSH and SSM browser terminal both have a TTY)
# Remove the SSH_TTY restriction if present — SSM browser sessions don't set SSH_TTY.
echo "--- patching .bash_profile on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" '
  if grep -q "SSH_TTY" ~/.bash_profile; then
    sed -i "s/\[\[ -n \"\${SSH_TTY:-}\" && -t 0 && -z \"\${TMUX:-}\" \]\]/[[ -t 0 \&\& -z \"\${TMUX:-}\" ]]/" ~/.bash_profile
    sed -i "s/# Launch Claude Code session selector on interactive SSH login/# Launch Claude Code session selector on interactive login (SSH or SSM browser terminal)/" ~/.bash_profile
    echo "  .bash_profile: removed SSH_TTY restriction (now fires for SSH and SSM sessions)"
  else
    echo "  .bash_profile already up to date."
  fi
'

echo "--- ensuring rsync is installed on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo dnf install -y rsync -q && echo '  rsync ready'"

echo "--- installing web-preview service on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /etc/systemd/system/web-preview.service > /dev/null" \
  << 'WEB_PREVIEW_SERVICE'
[Unit]
Description=Static web server for Claude Code output preview
After=network.target

[Service]
Type=simple
User=developer
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 127.0.0.1 --directory /home/developer/www
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
WEB_PREVIEW_SERVICE

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo systemctl daemon-reload && sudo systemctl enable web-preview.service && sudo systemctl restart web-preview.service && echo '  web-preview service active on port 8080'"

echo "--- pushing ~/.claude/CLAUDE.md to ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "mkdir -p ~/.claude && tee ~/.claude/CLAUDE.md > /dev/null" \
  << 'CLAUDE_MD'
## File Sharing with the User

A static web server is always running on this instance. The user can access it at **http://localhost:8080** in their local browser while connected.

Directory conventions (using `my-app` as an example project):
- `~/repos/my-app/` — the **working directory** (source code)
- `~/www/my-app/`   — the **web root** (also called the serve directory); files here are served at `http://localhost:8080/my-app/`
- `~/uploads/my-app/` — where user-uploaded files land; also accessible at `http://localhost:8080/my-app/uploads/` via a symlink in the web root

### Sharing visual output or web content

Write files to the **web root** (`~/www/<project>/`) where `<project>` is the basename of the working directory. For example, if the working directory is `~/repos/my-app/`, the web root is `~/www/my-app/`.

Files written to the web root are immediately visible at `http://localhost:8080/<project>/` in the user's browser. Tell the user to open that URL to preview your output.

### When the user uploads files

The user may upload screenshots, images, or reference files using `./user.sh upload`. Uploaded files appear in `~/uploads/<project>/` (same project-name convention as the web root). When the user says "I uploaded a screenshot" or "I sent you a file", check that directory.
CLAUDE_MD

echo ""
echo "=== refresh complete on ${INSTANCE_ID} (${DEV_USERNAME}) ==="
echo "    session_start.sh + .tmux.conf: take effect on next connect"
echo "    autoshutdown timer:            active immediately"
echo "    web-preview service:           active immediately (http://localhost:8080)"
echo "    ~/.claude/CLAUDE.md:           updated"
