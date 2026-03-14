#!/usr/bin/env bash
# connect.sh — Opens an SSH session tunneled through SSM with agent forwarding.
# No inbound port 22 needed. Local GitHub SSH keys work transparently via -A.
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
  echo "       Run './run.sh start' first." >&2
  exit 1
fi

echo "Connecting to ${INSTANCE_ID} via SSH over SSM..."
echo "(Your local SSH agent is forwarded — GitHub push/pull works without storing keys on the instance.)"
echo ""

# Build the SSH options array
SSH_OPTS=(
  "-A"                                # Forward SSH agent (GitHub keys work on remote)
  "-i" "/root/.ssh/fre-claude"        # Explicit key — SSH won't auto-discover non-default names
  "-o" "StrictHostKeyChecking=no"     # Instance ID changes on recreate
  "-o" "UserKnownHostsFile=/dev/null"
  # Tunnel SSH through SSM — no inbound port 22 needed in security group
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

# Forward env vars to the remote session so session_start.sh can use them
[[ -n "${GH_TOKEN:-}"       ]] && SSH_OPTS+=("-o" "SendEnv=GH_TOKEN")
[[ -n "${GIT_USER_NAME:-}"  ]] && SSH_OPTS+=("-o" "SendEnv=GIT_USER_NAME")
[[ -n "${GIT_USER_EMAIL:-}" ]] && SSH_OPTS+=("-o" "SendEnv=GIT_USER_EMAIL")

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}"
