#!/usr/bin/env bash
# refresh.sh — Push an updated session_start.sh to the running instance.
# Faster than down/up: updates SSM and overwrites the file in place via SSH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/defaults.env"
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

: "${PROJECT_NAME:?}" "${AWS_REGION:?}" "${AWS_PROFILE:?}"

eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './run.sh sso-login' first." >&2
  exit 1
}

TF_DIR="${SCRIPT_DIR}/../terraform"
SESSION_START="${SCRIPT_DIR}/session_start.sh"

# ---------------------------------------------------------------------------
# Update S3 so new instances get the latest script on first boot
# ---------------------------------------------------------------------------
echo "--- uploading to S3 ---"
aws s3 cp "${SESSION_START}" \
  "s3://${PROJECT_NAME}-tfstate/scripts/session_start.sh" \
  --region "${AWS_REGION}"
echo ""

# ---------------------------------------------------------------------------
# Push directly to the running instance via SSH over SSM tunnel
# ---------------------------------------------------------------------------
echo "--- pushing to running instance ---"
INSTANCE_ID=$(terraform -chdir="${TF_DIR}" output -raw instance_id 2>/dev/null) || {
  echo "ERROR: Could not read instance_id from Terraform state. Has up.sh been run?" >&2
  exit 1
}

SSH_OPTS=(
  "-i" "/root/.ssh/fre-claude"
  "-o" "StrictHostKeyChecking=no"
  "-o" "UserKnownHostsFile=/dev/null"
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "cat > /home/developer/session_start.sh && chmod +x /home/developer/session_start.sh" \
  < "${SESSION_START}"

echo ""
echo "=== session_start.sh updated on ${INSTANCE_ID} ==="
echo "    Changes take effect on the next ./run.sh connect"
