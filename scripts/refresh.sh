#!/usr/bin/env bash
# refresh.sh — Push an updated session_start.sh to a running instance.
# Faster than down/up: overwrites the file in place via SSH over SSM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config: developer.env takes precedence (developer path); fall back to defaults.env (admin path)
if [[ -f "${SCRIPT_DIR}/../config/developer.env" ]]; then
  source "${SCRIPT_DIR}/../config/developer.env"
elif [[ -f "${SCRIPT_DIR}/../config/defaults.env" ]]; then
  source "${SCRIPT_DIR}/../config/defaults.env"
else
  echo "ERROR: No config found. Expected config/developer.env or config/defaults.env." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

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
  "-i" "/root/.ssh/fre-claude"
  "-o" "StrictHostKeyChecking=no"
  "-o" "UserKnownHostsFile=/dev/null"
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

echo "--- pushing session_start.sh to ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /home/developer/session_start.sh > /dev/null && sudo chmod +x /home/developer/session_start.sh && sudo chown developer:developer /home/developer/session_start.sh" \
  < "${SESSION_START}"

# Also ensure .bash_profile has the stdin-is-terminal guard (-t 0).
# Older instances only check SSH_TTY, which is inherited by child processes and
# causes session_start.sh to be triggered by git hooks and other login shells.
echo "--- patching .bash_profile on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" '
  if grep -q "SSH_TTY" ~/.bash_profile && ! grep -q "\-t 0" ~/.bash_profile; then
    sed -i "s/\[\[ -n \"\${SSH_TTY:-}\" \]\]/[[ -n \"\${SSH_TTY:-}\" \&\& -t 0 ]]/" ~/.bash_profile
    echo "  .bash_profile updated."
  else
    echo "  .bash_profile already up to date."
  fi
'

echo ""
echo "=== refresh complete on ${INSTANCE_ID} (${DEV_USERNAME}) ==="
echo "    Changes take effect on the next connect"
