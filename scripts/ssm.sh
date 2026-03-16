#!/usr/bin/env bash
# ssm.sh — Opens a direct SSM Session Manager shell on the EC2 instance.
# Connects as ssm-user (not developer). Use this as a fallback when SSH
# isn't working, or for admin tasks that need root access.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

: "${AWS_REGION:?}" "${AWS_PROFILE:?}" "${PROJECT_NAME:?}"

# DEV_USERNAME: set by admin.sh (command arg)
DEV_USERNAME="${DEV_USERNAME:-}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh ssm <username>'." >&2
  exit 1
fi

eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}

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

INSTANCE_STATE=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null)

if [[ "${INSTANCE_STATE}" != "running" ]]; then
  echo "ERROR: Instance ${INSTANCE_ID} is '${INSTANCE_STATE}', not running." >&2
  echo "       Run './admin.sh start ${DEV_USERNAME}' first." >&2
  exit 1
fi

echo "Opening SSM session on ${INSTANCE_ID} (${DEV_USERNAME}, as ssm-user)..."
echo "Tip: run 'sudo -i -u developer' to switch to the developer user."
echo ""

aws ssm start-session \
  --target "${INSTANCE_ID}" \
  --region "${AWS_REGION}"
