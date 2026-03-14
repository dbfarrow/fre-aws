#!/usr/bin/env bash
# ssm.sh — Opens a direct SSM Session Manager shell on the EC2 instance.
# Connects as ssm-user (not developer). Use this as a fallback when SSH
# isn't working, or for admin tasks that need root access.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/defaults.env"
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

: "${AWS_REGION:?}" "${AWS_PROFILE:?}"

eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './run.sh sso-login' first." >&2
  exit 1
}

TF_DIR="${SCRIPT_DIR}/../terraform"

INSTANCE_ID=$(terraform -chdir="${TF_DIR}" output -raw instance_id 2>/dev/null) || {
  echo "ERROR: Could not read instance_id from Terraform state. Has up.sh been run?" >&2
  exit 1
}

INSTANCE_STATE=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null) || {
  echo "ERROR: Could not describe instance ${INSTANCE_ID}." >&2
  exit 1
}

if [[ "${INSTANCE_STATE}" != "running" ]]; then
  echo "ERROR: Instance ${INSTANCE_ID} is '${INSTANCE_STATE}', not running." >&2
  echo "       Run './run.sh start' first." >&2
  exit 1
fi

echo "Opening SSM session on ${INSTANCE_ID} (as ssm-user)..."
echo "Tip: run 'sudo -i -u developer' to switch to the developer user."
echo ""

aws ssm start-session \
  --target "${INSTANCE_ID}" \
  --region "${AWS_REGION}"
