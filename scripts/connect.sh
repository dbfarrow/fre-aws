#!/usr/bin/env bash
# connect.sh — Opens an SSM Session Manager shell on the EC2 instance.
# No SSH keys or open ports required.
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

# Verify the instance is running before attempting to connect
INSTANCE_STATE=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null) || {
  echo "ERROR: Could not describe instance ${INSTANCE_ID}. Check your AWS credentials." >&2
  exit 1
}

if [[ "${INSTANCE_STATE}" != "running" ]]; then
  echo "ERROR: Instance ${INSTANCE_ID} is '${INSTANCE_STATE}', not running." >&2
  echo "       Run start.sh first." >&2
  exit 1
fi

echo "Connecting to ${INSTANCE_ID} via SSM Session Manager..."
echo "(No SSH key required. Press Ctrl+D or type 'exit' to disconnect.)"
echo ""

aws ssm start-session \
  --target "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
