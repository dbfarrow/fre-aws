#!/usr/bin/env bash
# connect.sh — Opens an SSH session tunneled through SSM with agent forwarding.
# No inbound port 22 needed. Local GitHub SSH keys work transparently via -A.
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

# Caller-provided profile wins (admin.sh connect must use admin credentials, not user.env's profile)
[[ -n "${_CALLER_PROFILE}" ]] && AWS_PROFILE="${_CALLER_PROFILE}"

: "${AWS_REGION:?}" "${AWS_PROFILE:?}" "${PROJECT_NAME:?}"

# DEV_USERNAME: set by admin.sh (command arg) or user.env (MY_USERNAME)
DEV_USERNAME="${DEV_USERNAME:-${MY_USERNAME:-}}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh connect <username>' or set MY_USERNAME in config/user.env." >&2
  exit 1
fi

CREDS=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './user.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${CREDS}" | sed 's/^/export /')"

# Resolve instance ID by Username tag
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
  echo "       Has './admin.sh up' been run?" >&2
  exit 1
fi

# Verify the instance is running
INSTANCE_STATE=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null) || {
  echo "ERROR: Could not describe instance ${INSTANCE_ID}. Check your AWS credentials." >&2
  exit 1
}

if [[ "${INSTANCE_STATE}" != "running" ]]; then
  echo "ERROR: Instance ${INSTANCE_ID} is '${INSTANCE_STATE}', not running." >&2
  echo "       Run './user.sh start'  (or: ./admin.sh start ${DEV_USERNAME}) first." >&2
  exit 1
fi

echo "Connecting to ${INSTANCE_ID} (${DEV_USERNAME}) via SSH over SSM..."
echo "(Your SSH key will be forwarded — GitHub push/pull works without storing keys on the instance.)"
echo ""

# Start a fresh ssh-agent inside the container and load the fre-claude key.
# This gives proper agent forwarding to the EC2 instance via -A without
# relying on Docker Desktop's unreliable host agent socket bridging.
eval "$(ssh-agent -s)" > /dev/null
ssh-add /root/.ssh/fre-claude

# Build the SSH options array
SSH_OPTS=(
  "-A"                                # Forward the container's agent to EC2
  "-i" "/root/.ssh/fre-claude"        # Explicit key — SSH won't auto-discover non-default names
  "-o" "StrictHostKeyChecking=no"     # Instance ID changes on recreate
  "-o" "UserKnownHostsFile=/dev/null"
  # Tunnel SSH through SSM — no inbound port 22 needed in security group
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

# Forward git identity to the remote session so session_start.sh can refresh it
[[ -n "${GIT_USER_NAME:-}"  ]] && SSH_OPTS+=("-o" "SendEnv=GIT_USER_NAME")
[[ -n "${GIT_USER_EMAIL:-}" ]] && SSH_OPTS+=("-o" "SendEnv=GIT_USER_EMAIL")

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}"
