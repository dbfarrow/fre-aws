#!/usr/bin/env bash
# stop.sh — Stops the running EC2 instance. Compute charges stop; EBS is retained.
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

: "${AWS_REGION:?}" "${PROJECT_NAME:?}"

# DEV_USERNAME: set by admin.sh (command arg) or user.env (MY_USERNAME)
DEV_USERNAME="${DEV_USERNAME:-${MY_USERNAME:-}}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh stop <username>' or set MY_USERNAME in config/user.env." >&2
  exit 1
fi

_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")
CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials${AWS_PROFILE:+ for profile '${AWS_PROFILE}'}." >&2
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

INSTANCE_STATE=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null)

if [[ "${INSTANCE_STATE}" == "stopped" ]]; then
  echo "Instance ${INSTANCE_ID} (${DEV_USERNAME}) is already stopped."
  exit 0
fi

SHUTDOWN_MODE="${SHUTDOWN_MODE:-false}"
STOP_ARGS=()
STOP_VERB="Stopping"

if [[ "${SHUTDOWN_MODE}" != "true" ]]; then
  HIBERNATION_CONFIGURED=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0].HibernationOptions.Configured' \
    --output text 2>/dev/null || echo "False")
  if [[ "${HIBERNATION_CONFIGURED}" == "True" ]]; then
    STOP_ARGS+=("--hibernate")
    STOP_VERB="Hibernating"
  fi
fi

echo "${STOP_VERB} instance ${INSTANCE_ID} (${DEV_USERNAME})..."
aws ec2 stop-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  "${STOP_ARGS[@]+"${STOP_ARGS[@]}"}" \
  --output json > /dev/null

echo "Waiting for instance to reach stopped state..."
aws ec2 wait instance-stopped \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}"

if [[ "${STOP_VERB}" == "Hibernating" ]]; then
  echo "Instance ${INSTANCE_ID} (${DEV_USERNAME}) is hibernated. Resume with: ./admin.sh start ${DEV_USERNAME}"
else
  echo "Instance ${INSTANCE_ID} (${DEV_USERNAME}) is stopped. EBS data is preserved."
fi
