#!/usr/bin/env bash
# start.sh — Starts a stopped EC2 instance and waits until running.
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

# DEV_USERNAME: set by admin.sh (command arg) or developer.env (MY_USERNAME)
DEV_USERNAME="${DEV_USERNAME:-${MY_USERNAME:-}}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh start <username>' or set MY_USERNAME in config/developer.env." >&2
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

echo "Starting instance ${INSTANCE_ID} (${DEV_USERNAME})..."
aws ec2 start-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --output json > /dev/null

echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}"

echo "Instance ${INSTANCE_ID} is running."
echo ""
echo "To connect: ./dev.sh connect    (or: ./admin.sh connect ${DEV_USERNAME})"
