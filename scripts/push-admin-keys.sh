#!/usr/bin/env bash
# push-admin-keys.sh — Append the admin's SSH public key to one or all user instances.
# Uses SSM send-command — no SSH required, works on running instances without rebuild.
# Idempotent: skips if the key is already present in authorized_keys.
#
# Requires ADMIN_SSH_PUB_KEY env var (set by run.sh from the host's .pub file).
# Requires DEV_USERNAME env var for a single user; omit to push to all users.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  echo "ERROR: config/admin.env not found." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/admin.env"
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true
# shellcheck source=scripts/users-s3.sh
source "${SCRIPT_DIR}/users-s3.sh"

: "${PROJECT_NAME:?}" "${AWS_REGION:?}" "${AWS_PROFILE:?}"

# ---------------------------------------------------------------------------
# Admin SSH public key
# ---------------------------------------------------------------------------
ADMIN_SSH_PUB_KEY="${ADMIN_SSH_PUB_KEY:-}"
if [[ -z "${ADMIN_SSH_PUB_KEY}" ]]; then
  echo "ERROR: ADMIN_SSH_PUB_KEY not set." >&2
  echo "       run.sh should pass this from the host's .pub file." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Export AWS credentials
# ---------------------------------------------------------------------------
eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       Run './admin.sh sso-login' first." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Determine target user(s)
# ---------------------------------------------------------------------------
if [[ -n "${DEV_USERNAME:-}" ]]; then
  TARGETS=("${DEV_USERNAME}")
else
  echo "No username specified — pushing to all users."
  USERS_JSON=$(mktemp)
  trap 'rm -f "${USERS_JSON}"' EXIT
  users_s3_download "${USERS_JSON}"
  mapfile -t TARGETS < <(jq -r 'keys[]' "${USERS_JSON}")
fi

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "No users found." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Push admin key to each instance via SSM
# ---------------------------------------------------------------------------
_push_key() {
  local username="$1"
  echo ""
  echo "--- ${username} ---"

  local instance_id
  instance_id=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Username,Values=${username}" \
      "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
    --output text 2>/dev/null || echo "")

  if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
    echo "  No running instance — skipping. Start it first with './admin.sh start ${username}'."
    return
  fi

  # Append key then deduplicate in-place — idempotent, no quoting issues
  local ssm_params
  ssm_params=$(jq -n --arg key "${ADMIN_SSH_PUB_KEY}" '{
    "commands": [
      "mkdir -p /home/developer/.ssh",
      "chmod 700 /home/developer/.ssh",
      "echo \($key) >> /home/developer/.ssh/authorized_keys",
      "sort -u -o /home/developer/.ssh/authorized_keys /home/developer/.ssh/authorized_keys",
      "chmod 600 /home/developer/.ssh/authorized_keys",
      "chown -R developer:developer /home/developer/.ssh"
    ]
  }')

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceIds,Values=${instance_id}" \
    --parameters "${ssm_params}" \
    --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
    --comment "fre-aws: add admin SSH key for ${username}" \
    --query 'Command.CommandId' --output text 2>/dev/null || echo "")

  if [[ -z "${cmd_id}" || "${cmd_id}" == "None" ]]; then
    echo "  WARNING: Could not send SSM command to ${instance_id}." >&2
    return
  fi

  echo "  Sent command ${cmd_id} to ${instance_id}. Waiting..."
  local status="Pending"
  for _ in $(seq 1 15); do
    sleep 2
    status=$(aws ssm get-command-invocation \
      --command-id "${cmd_id}" \
      --instance-id "${instance_id}" \
      --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
      --query 'Status' --output text 2>/dev/null || echo "Unknown")
    [[ "${status}" =~ ^(Success|Failed|Cancelled|TimedOut) ]] && break
  done

  if [[ "${status}" == "Success" ]]; then
    echo "  Admin key installed on ${instance_id}."
  else
    echo "  WARNING: SSM command status: ${status}." >&2
  fi
}

for username in "${TARGETS[@]}"; do
  _push_key "${username}"
done

echo ""
echo "=== push-admin-keys complete ==="
