#!/usr/bin/env bash
# stop.sh — Stops the running EC2 instance. Compute charges stop; EBS is retained.
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
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh stop <username>' or set MY_USERNAME in config/developer.env." >&2
  exit 1
fi

CREDS=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './dev.sh sso-login' first." >&2
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

INSTANCE_STATE=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null)

if [[ "${INSTANCE_STATE}" == "stopped" ]]; then
  echo "Instance ${INSTANCE_ID} (${DEV_USERNAME}) is already stopped."
  exit 0
fi

echo "Stopping instance ${INSTANCE_ID} (${DEV_USERNAME})..."
aws ec2 stop-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --output json > /dev/null

echo "Waiting for instance to reach stopped state..."
aws ec2 wait instance-stopped \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}"

echo "Instance ${INSTANCE_ID} (${DEV_USERNAME}) is stopped. EBS data is preserved."
